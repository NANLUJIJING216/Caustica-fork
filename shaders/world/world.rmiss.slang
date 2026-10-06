// Ray miss = sky. Per-frame sky data comes from the WorldPush BDA buffer addressed by the 8-byte push
// constant. The shader writes full sky radiance (Rayleigh/Mie/ozone atmosphere + transmittance-tinted
// sun/moon discs + soft horizon + starfield) into payload.albedo; raygen consumes that value for both
// accumulated radiance and bounce-0 denoiser guides.
//
// Celestial discs (sun/moon) are gated by a packed payload flag, which raygen sets per-ray from the path
// state: true on the primary ray and after every specular/dielectric bounce (so the sun/moon show up in
// water/glass/metal reflections + refractions), false after a diffuse vertex did sun/moon NEE (so the
// disc isn't double-counted against the direct light → fireflies). The atmosphere gradient + stars are
// added on every miss (any bounce): stars aren't a NEE light, so they never double-count.
import world_common;
import sky;
import clouds;
import rainfog;

[[vk::push_constant]] WorldPushConstants pc;

// Vanilla celestials atlas (sun + moon-phase sprites), bound by RtComposite. Sampled with an explicit
// LOD (no derivatives in a miss shader). The sun/moon discs are drawn from its real texels.
[[vk::binding(9, 0)]] Sampler2D celestialsAtlas;

float pow2(float x) { return x * x; }

// Near-white top-of-atmosphere disc radiances: the visible warm/red tint comes from multiplying by
// transmittanceToSpace(dir) at draw time — at noon the sun reads warm-white, at the horizon it reddens
// on exactly the sky's own sunset curve.
static const float3 SUN_DISC_RADIANCE  = float3(24.0, 23.0, 21.5);
static const float3 MOON_DISC_RADIANCE = float3(1.7, 1.85, 2.2) / 4.0; // lit-side moon (HDR, bright at night exposure)
// Vibrance applied to the atmosphere in-scatter only (not discs/stars/night ambient): luminance-
// preserving, so GI energy is unchanged.
static const float SKY_SATURATION = 1.2;
// Weather dims diffuse atmospheric skylight; cloud geometry shades the sun separately.
static const float WEATHER_RAIN_ATTENUATION = 0.72;
static const float WEATHER_THUNDER_ATTENUATION = 0.18;
static const float WEATHER_MIN_TRANSMITTANCE = 0.10;
// VISIBLE disc half-angles, matched to vanilla: the sun/moon quads are drawn at half-width 30/20 at
// distance 100 → half-angle = atan(0.30) / atan(0.20). Decoupled from the NEE light radius (≈0.6°).
static const float SUN_DISC_HALF_ANGLE  = 0.29146; // atan(30/100), vanilla sun size
static const float MOON_DISC_HALF_ANGLE = 0.19740; // atan(20/100), vanilla moon size




// Build the celestial body's square tangent frame: `right` along the arc-travel direction, `up`
// perpendicular within the sky. Shared by the visible disc and the NEE square sampling in raygen.
void celestialFrame(float3 dir, float3 celestialAxis, out float3 right, out float3 up) {
    right = normalize(cross(dir, celestialAxis));
    up = cross(right, dir);
}

// Gnomonic projection of `dir` into the body's tangent square, in units of the half-angle. local ∈
// [-1,1]² is inside the square. Returns 0 behind the body. The square (not a cone) matches MC's quad.
float squareBody(float3 dir, float3 bodyDir, float halfAngle, float3 celestialAxis, out float2 local) {
    float c = dot(dir, bodyDir);
    if (c <= 1.0e-3) { local = float2(2.0, 2.0); return 0.0; }
    float3 d = dir / c;                  // d·bodyDir == 1 (point on the tangent plane)
    float3 r, u;
    celestialFrame(bodyDir, celestialAxis, r, u);
    float t = tan(halfAngle);
    local = float2(dot(d, r), dot(d, u)) / t;
    float m = max(abs(local.x), abs(local.y));
    return 1.0 - smoothstep(0.90, 1.0, m); // soft square edge
}

// Dave Hoskins' hash13 (https://www.shadertoy.com/view/4djSRW): well-distributed and pattern-free.
float hash13(float3 p3) {
    p3 = frac(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return frac((p3.x + p3.y) * p3.z);
}

// Rotate v about a unit axis by angle (Rodrigues). Used to wheel the starfield about the celestial pole.
float3 rotateAxis(float3 v, float3 axis, float ang) {
    float c = cos(ang), s = sin(ang);
    return v * c + cross(axis, v) * s + axis * dot(axis, v) * (1.0 - c);
}

// Procedural starfield, a faithful port of vanilla's buildStars(): ~1500 discrete stars at random
// sphere directions, each a small SQUARE billboard of random size + random rotation. A cube-map grid is
// the spatial accelerator — at most one star per cell, placed at a hashed position INSET from the cell
// edges (so its square never crosses into a neighbour), drawn as a hash-rotated square of hashed size.
// The lookup direction is rotated about the celestial pole by -STAR_ANGLE so the field wheels with
// world time like the real sky.
static const float STAR_CELLS     = 21.0;  // cube-face grid resolution; with the threshold gives ~1500 stars
static const float STAR_THRESHOLD = 0.86;  // cell occupancy cutoff (higher = fewer stars)
static const float STAR_HALF      = 0.045; // star half-size as a fraction of a cell (≈ vanilla 0.11° at center)
float3 stars(float3 dir, float starBrightness, float VdotS, float4 celestial) {
    if (starBrightness <= 0.0 || dir.y <= 0.0) return float3(0.0, 0.0, 0.0);
    // Negative angle: rotating the LOOKUP direction is the inverse of rotating star geometry, so
    // -starAngle makes the field wheel the SAME way as the sun/moon (whose world dirs are
    // forward-rotated on the CPU).
    float3 sdir = rotateAxis(dir, normalize(celestial.xyz), -celestial.w);
    // Cube-map face + 2D gnomonic uv → uniform square cells, no pole/equator distortion.
    float3 a = abs(sdir);
    float2 uv;
    float face;
    if (a.x >= a.y && a.x >= a.z)      { uv = sdir.yz / a.x; face = sdir.x > 0.0 ? 0.0 : 1.0; }
    else if (a.y >= a.z)               { uv = sdir.xz / a.y; face = sdir.y > 0.0 ? 2.0 : 3.0; }
    else                               { uv = sdir.xy / a.z; face = sdir.z > 0.0 ? 4.0 : 5.0; }
    float2 g = uv * STAR_CELLS;
    float3 id = float3(floor(g), face);
    if (hash13(id) < STAR_THRESHOLD) return float3(0.0, 0.0, 0.0); // no star in this cell
    // Per-star randoms: size, centre (inset so the rotated square stays inside the cell), rotation.
    float sz = STAR_HALF * (0.6 + 0.8 * hash13(id + 53.0));
    float inset = sz * 1.5; // keeps the rotated square clear of the cell edge
    float2 center = inset + (1.0 - 2.0 * inset) * float2(hash13(id + 11.0), hash13(id + 23.0));
    float2 q = frac(g) - center;
    float ang = hash13(id + 91.0) * 6.2831853;        // random per-star rotation (vanilla zRot)
    float cs = cos(ang), sn = sin(ang);
    q = float2(cs * q.x - sn * q.y, sn * q.x + cs * q.y); // GLSL mat2(cs,-sn,sn,cs) * q, written out
    float box = max(abs(q.x), abs(q.y));               // Chebyshev distance → square
    float star = 1.0 - smoothstep(sz * 0.6, sz, box);  // soft-edged square (helps DLSS stability)
    if (star <= 0.0) return float3(0.0, 0.0, 0.0);
    float bright = 0.55 + 0.45 * hash13(id + 71.0);    // mild per-star brightness variation
    star *= bright * min(dir.y * 3.0, 1.0) * max(0.0, 1.0 - pow(abs(VdotS) * 1.002, 100.0));
    // Per-star colour temperature: hash picks a spot on a warm-orange ↔ blue-white ramp (real star
    // populations). Average luminance close to the old uniform constant so night exposure doesn't shift.
    float3 starCol = lerp(float3(0.78, 0.60, 0.42), float3(0.50, 0.62, 0.95), hash13(id + 137.0));
    return 0.2 * star * starCol * starBrightness;
}

float cloudDirectTransmittance(float rain, float thunder) {
    return clamp(1.0 - rain * WEATHER_RAIN_ATTENUATION - thunder * WEATHER_THUNDER_ATTENUATION,
                 WEATHER_MIN_TRANSMITTANCE, 1.0);
}

float weatherSkyFactor(float4 weather) {
    float direct = cloudDirectTransmittance(weather.x, weather.y);
    // weather.z is ClientLevel's hide-aware lightning countdown normalized to 0..1. It may lift only
    // the atmosphere and cloud underside; stars, discs and CPU NEE retain the non-flash direct factor.
    float lightning = weather.y * smoothstep(0.78, 1.0, weather.z);
    return clamp(direct + lightning * (1.0 - direct) * 0.80,
                 WEATHER_MIN_TRANSMITTANCE, 1.0);
}

[shader("miss")]
void main(inout Payload payload) {
    WorldPush worldPush = ConstPtr<WorldPush>(pc.worldPushAddr)[0];
    float3 dir = normalize(WorldRayDirection());
    float day = worldPush.sunDir.w;
    float3 sd = worldPush.sunDir.xyz;
    float SdotU = sd.y;
    float VdotS = dot(dir, sd);
    float sunUp = clamp((SdotU + 0.0625) / 0.125, 0.0, 1.0); // 0 well below horizon .. 1 above
    float starBrightness = worldPush.lightRadiance.w;
    float weatherSky = weatherSkyFactor(worldPush.weather);
    float weatherDirect = 1.0;
    bool showCelestial = (payload.flags & PAYLOAD_SHOW_CELESTIAL) != 0u;
    // The End: no atmosphere to scatter, no day cycle, no weather. Every branch below that would shade the
    // sky with air is gated on this one verdict rather than on its own dimension test (see the flag's note
    // in world_common.slang).
    bool endSky = (worldPush.flags & WORLD_FLAG_END_SKY) != 0u;

    // Physically-based in-scattering: blue zenith, bright/desaturated horizon, warm Mie halo + red
    // sunset all fall out of the Rayleigh/Mie/ozone march. At night the sun is below the horizon so the
    // light march is blocked → near-zero; a faint night ambient + the rotating starfield sit underneath.
    //
    // Soft horizon: below-horizon rays used to march into the planet-surface clip, drawing a hard fixed
    // line across the sky. Instead, march the ray flattened onto the horizon (same azimuth, y=0) so the
    // gradient continues seamlessly downward, with an exponential falloff so it settles into darkness
    // instead of a uniform bright band.
    float3 mdir = dir;
    float downFade = 1.0;
    if (dir.y < 0.0) {
        float2 flat2 = float2(dir.x, dir.z);
        float fl = length(flat2);
        mdir = fl > 1.0e-4 ? float3(flat2.x / fl, 0.0, flat2.y / fl) : float3(1.0, 0.0, 0.0);
        downFade = exp(dir.y * 3.0);
    }
    // ---- Sky.
    //
    // The End has no atmosphere, so it has no in-scatter, no airglow floor and no day cycle: its sky is the
    // dimension's own faint violet wash with the starfield over it. The down-fade and the weather dimming
    // are atmosphere effects and are skipped with it.
    float3 col = endSky ? END_SKY_GLOW : atmosphere(mdir, sd);
    if (!endSky) {
        // Luminance-preserving vibrance on the in-scatter only (see SKY_SATURATION).
        float lum = dot(col, float3(0.2126, 0.7152, 0.0722));
        col = max(lerp(float3(lum, lum, lum), col, SKY_SATURATION), float3(0.0, 0.0, 0.0));
        float up = clamp(dir.y, 0.0, 1.0);
        float3 nightAmbient = lerp(NIGHT_HORIZON, NIGHT_ZENITH, up);
        col += nightAmbient * (1.0 - day);
        col *= downFade;
        col *= weatherSky;
    }
    col += stars(dir, starBrightness, VdotS, worldPush.celestial) * weatherDirect;

    // Sun & moon discs — sampled from the vanilla celestials atlas, gated to rays that haven't already
    // accounted for the light via diffuse NEE. squareBody gives the body-local [-1,1] coord; the
    // sprite's own texel coverage (alpha) shapes the disc.
    float3 celestialRadiance = float3(0.0, 0.0, 0.0);
    if (showCelestial) {
        float2 local;
        // No sun in the End: the frame's directional light there is the moon, and drawing a body that
        // delivers no light would be a lie the path integral cannot cancel.
        if (!endSky) {
            squareBody(dir, sd, SUN_DISC_HALF_ANGLE, worldPush.celestial.xyz, local);
            if (all(abs(local) < float2(1.0, 1.0))) {
                float2 uv = lerp(worldPush.sunUv.xy, worldPush.sunUv.zw, local * 0.5 + 0.5);
                float3 t = celestialsAtlas.SampleLevel(uv, 0.0).rgb;
                // The vanilla sun sprite bakes a soft glow gradient into its texels; scaling that raw to HDR
                // makes a huge ring. Raise the texture luminance to a high power — only the bright core
                // survives, the halo collapses to ~0.
                float core = pow(clamp(dot(t, t) * 0.45, 0.0, 1.0), 6.0);
                // transmittanceToSpace reddens+dims the disc through the sunset on the sky's own curve.
                celestialRadiance += SUN_DISC_RADIANCE * transmittanceToSpace(dir) * core * sunUp * weatherDirect;
            }
        }
        // Same horizon gate as the sun: with the soft-horizon change, below-horizon rays no longer clip
        // at the planet, so without this the moon disc would stay visible after it set. The End has neither
        // air nor a horizon curve, so its moon is drawn ungated.
        float moonUp = clamp((worldPush.moonDir.y + 0.0625) / 0.125, 0.0, 1.0);
        squareBody(dir, worldPush.moonDir.xyz, MOON_DISC_HALF_ANGLE, worldPush.celestial.xyz, local);
        if (all(abs(local) < float2(1.0, 1.0)) && (endSky || moonUp > 0.0)) {
            float2 uv = lerp(worldPush.moonUv.xy, worldPush.moonUv.zw, local * 0.5 + 0.5);
            float3 t = celestialsAtlas.SampleLevel(uv, 0.0).rgb;
            // Moon: a smoothstep contrast ramp suppresses the faint halo while keeping the lit phase
            // shape from the texture. The transmittance tint gives a warm amber moon at moonrise/set.
            float m = smoothstep(0.0, 1.0, min(length(t), 1.0)) * 1.3;
            // The End's moon is its only light there: dull red (END_MOON_COLOR) and boosted, and drawn
            // without the atmospheric tint or the horizon gate — neither of which exists in that dimension.
            // Tinting the disc and the light NEE samples by the same colour is what keeps the ground and
            // the haze red too, instead of a red disc over grey light.
            float3 moonDisc = endSky
                    ? MOON_DISC_RADIANCE * END_MOON_BOOST * END_MOON_COLOR * t * m
                    : MOON_DISC_RADIANCE * transmittanceToSpace(dir) * t * m * pow2(1.0 - day) * moonUp;
            celestialRadiance += moonDisc * weatherDirect;
        }
    }

    // ---- Volumetric clouds (clouds.slang).
    //
    // Marched here, on every radiance ray that reaches the sky, so the primary view and every
    // reflection/refraction bounce integrate the same layer with no second implementation and no
    // separate pass to keep in sync. The layer is lit by the same dominant celestial light terrain NEE
    // uses (worldPush.lightDir / lightRadiance) and by the sky this miss already sampled, so cloud light
    // and terrain light cannot diverge.
    //
    // The layer is deliberately left noisy and handed to DLSS Ray Reconstruction, which resolves it
    // against the ray-traced geometry; pre-smoothing it here would cost detail the denoiser could have
    // recovered.
    // The layer's representative depth for DLSS-RR, published through the miss-side rayCone lane below (a
    // miss has no ray cone of its own to report). Negative means this ray saw no cloud.
    float cloudDepth = CLOUD_NO_HIT_DEPTH;
    CloudLayer cloudDeck = cloudLayer(worldPush);
    if (cloudLayerActive(cloudDeck)) {
        float jitter = cloudJitter(cloudDeck, float2(DispatchRaysIndex().xy), worldPush.frameIndex);
        // What lights the layer from every side is the sky above it, not the sky the camera happens to
        // be looking along. Sampling the view direction instead makes a cloud's underside exactly as
        // dark as the horizon behind it, which is where black cloud bottoms come from.
        float3 cloudAmbient = atmosphere(float3(0.0, 1.0, 0.0), sd) * weatherSky;
        float3 skyOnly = col + celestialRadiance;
        CloudResult cloud = marchClouds(WorldRayOrigin(), dir, 1.0e6, cloudDeck,
                worldPush.lightDir.xyz, max(worldPush.lightRadiance.xyz, float3(0.0, 0.0, 0.0)),
                cloudAmbient, jitter);
        cloudDepth = cloud.depth;
        // Energy: what the layer scatters toward the viewer, plus what it transmits of the sky behind it.
        col = col * cloud.transmittance + cloud.scattering;
        // Thunderstorm emission from inside the layer. The CPU only publishes a non-zero scale while the
        // level's thunder is up, so this needs no weather state of its own here.
        col += cloudDeck.lightning * cloud.scattering;
        // The HDR discs need a longer optical path through dense cloud than the diffuse sky: they are
        // attenuated by the layer once more than the sky they sit in.
        celestialRadiance *= cloud.transmittance;
        // Aerial perspective: cloud seen through kilometres of atmosphere loses its contrast to the sky
        // behind it. The layer's own representative depth drives it, so the effect grows exactly with the
        // long grazing path that otherwise stacks distant cloud into a solid band.
        if (cloud.depth > 0.0) {
            float aerial = 1.0 - exp(-cloud.depth * CLOUD_AERIAL_PER_BLOCK);
            col = lerp(col, skyOnly, aerial);
        }
    }
    col += celestialRadiance;

    // ---- The End's haze (rainfog.slang).
    //
    // ONLY the End composites this medium. The overworld and the Nether use this renderer's own air fog and
    // light shafts (air_volume.slang) exclusively — the rain fog that 0.1.0 put in the air below the deck
    // has been removed there, so the two media can never stack. The End keeps it because that dimension has
    // no atmosphere for air_volume to fog, and because its medium is not precipitation: the strength rides
    // the cloud layer's rain lane, which the CPU fills with the dimension's own haze value.
    //
    // It composites over the finished sky — clouds, discs and stars included — for the same reason the cloud
    // layer does: from inside the medium, everything behind it is veiled by it.
    //
    // The depth DLSS-RR reprojects this pixel by: the cloud layer's centroid if the ray crossed one, else
    // the haze's. A miss has no surface, and an infinite depth is only correct for the sky itself.
    float guideDepth = cloudDepth;
    if (endSky && rainFogStrength(worldPush, cloudDeck) > 0.0) {
        RainFog fog = makeRainFog(worldPush, cloudDeck, DispatchRaysIndex().xy);
        CloudResult fogSample = marchRainFog(WorldRayOrigin(), dir, 10000.0, fog);
        col = fogSample.scattering + col * fogSample.transmittance;
        // Both are participating media, so where both are present the nearer one dominates the pixel's
        // parallax and is the depth the denoiser can actually use.
        if (fogSample.depth > 0.0) {
            guideDepth = guideDepth > 0.0 ? min(guideDepth, fogSample.depth) : fogSample.depth;
        }
    }

    // albedo is a half3 lane, so the sky's HDR radiance is clamped to half's finite range rather than
    // allowed to round up to +inf and propagate as NaN through the path throughput. This is a guard, not
    // a correction: the brightest term here is SUN_DISC_RADIANCE at 24.0, far under the 65504 ceiling.
    payload.albedo = half3(clamp(col, float3(0.0, 0.0, 0.0), float3(HALF_MAX, HALF_MAX, HALF_MAX)));
    payload.hitT = -1.0;
    payload.normal = half3(0.0h, 0.0h, 0.0h);
    payload.motionPrev = half3(0.0h, 0.0h, 0.0h);
    payload.f0 = half3(0.0h, 0.0h, 0.0h);
    payload.flags = 0u;
    payload.roughMetal = packHalf2(float2(1.0, 0.0));
    payload.emissionSss = packHalf2(float2(0.0, 0.0));
    payload.iorTransmission = packHalf2(float2(1.0, 0.0));
    // The cloud layer's depth rides the rayCone lane: a miss has no ray cone to report (rchit is the only
    // writer of the packed cone, and it only runs on a hit), and raygen needs a finite depth for the layer
    // or DLSS-RR reprojects it as infinitely distant sky — which is what leaves the march's step lattice
    // unconverged in the distance, reading as horizontal banding and ghosting as the wind moves it.
    payload.rayCone = asuint(guideDepth);
}
