// Rain fog: the volumetric medium a storm puts in the air under its cloud deck - and, in the End, the
// violet haze that fills the whole dimension.
//
// clouds.slang owns a slab of cloud sitting on the cloud base. This is the complementary volume: the air
// BELOW that base, from the deck down past the player, filled with the rain, spray and mist a storm
// carries. It is a separate medium because it is a separate thing -- clouds are an object you look at, fog
// is the air you look through -- and because the two want opposite implementations. A cloud needs erosion,
// a light march and a LOD schedule; fog is a smooth, optically thin medium whose whole job is distance and
// height, and it costs a fraction of what the deck does.
//
// Ported from the 0.1.0 build with only its lighting adapted to this renderer: the band geometry, the
// march, the noise and every tuning constant below are unchanged, while the sun and sky terms now come
// from worldPush.lightDir / lightRadiance and the shared atmosphere() in sky.slang instead of the old
// sky-view LUT, and the dimension verdict comes from WorldPush.flags bit 2 instead of a sky state struct.
//
// Rain strength arrives as WorldPush.cloudC.w, which CloudLayer publishes as `rain` and Java fills from
// the level's rain level times the weather-response setting. In the End that lane carries the dimension's
// own haze strength instead (thickest while the dragon lives; see RtComposite.cloudPush), which is why
// rainFogStrength branches on WORLD_FLAG_END_SKY rather than reading the weather lane.
//
// The medium is gated on the CPU's sky-exposure verdict, which is what keeps it out of sealed interiors
// and caves while leaving it under a canopy.
//
// Extinction is quoted in blocks. The renderer's deliberate 100-blocks-per-kilometre scale makes the
// real-world numbers unhelpfully large: 15 per kilometre, the textbook dense-fog coefficient, is 0.15 per
// block here, i.e. seven blocks of visibility. The constant below is tuned for play instead -- a few
// hundred blocks at full storm -- and stays a single number to change.

import world_common;
import sky;
import clouds;

// Extinction per block at the bottom of the band, at full storm. Koschmieder's 3/sigma visibility rule
// puts the fully-developed value at roughly 300 blocks.
public static const float FOG_EXTINCTION = 0.002;

// Vertical extent of the density gradient below the cloud base, in blocks. Deep enough that the falloff
// below is fully developed by the time it reaches a player standing on the ground, which is what makes it
// read as ground fog rather than as a uniform grey sheet.
public static const float FOG_DEPTH = 320.0;

// The band's floor, in world blocks: how far down the medium reaches for the ray test. It is NOT the
// gradient's end -- the gradient above saturates at FOG_DEPTH below the deck, so anything below that has
// the same density and this value only decides where a level ray starts accumulating.
//
// It has to sit below every walkable altitude, and that is the whole point of separating it from
// FOG_DEPTH. Anchoring the floor to the deck instead means a high cloud base lifts the entire band off
// the ground: at a base of 512 the band would start at 192, a player at sea level would be 129 blocks
// UNDER it, and a level look would never enter the medium -- the fog would survive only as a veil visible
// when looking up. -64 is the overworld's build floor; the density at any altitude a player can stand on
// is governed by the gradient, not by this.
public static const float FOG_FLOOR = -64.0;

// Density ramps DOWN from the bottom of the band to the cloud base, so the air is thickest near the
// ground and there is no step where the fog meets the deck.

// Low-frequency 3D noise that makes the band non-uniform: banks, drifting sheets, thinning patches. One
// feature is 96 blocks across and the lattice tiles after 6144 blocks, which is comfortably beyond the
// distance the fog is visible over.
public static const float FOG_NOISE_SCALE = 1.0 / 96.0;
public static const float FOG_NOISE_CELLS = 64.0;
public static const float FOG_NOISE_AMOUNT = 0.55;
// The smallest feature the field carries, in blocks - one lattice cell. rainFogDensity fades the noise out
// once the march's stride can no longer resolve it; see the note there.
public static const float FOG_NOISE_FEATURE = 1.0 / FOG_NOISE_SCALE;

// March budget and reach. Fog is smooth and its optical depth is dominated by the first few hundred
// blocks, so a fixed, small step count is enough; the reach cap is where the medium has already gone
// opaque at full storm and sampling further could not change the pixel.
public static const int   FOG_STEPS = 6;
public static const float FOG_STEP_NEAR = 16.0;
public static const float FOG_MAX_DISTANCE = 1600.0;

// Droplet phase. Rain fog scatters strongly forward, which is what draws the shafts and the halo around a
// break in the deck.
public static const float FOG_G = 0.62;
// Fraction of the received light the droplets redirect. Slightly under one: fog is not a pure scatterer.
public static const float FOG_ALBEDO = 0.92;

// Fog's own multiple-scattering fill, as a fraction of the sky term. A single-scatter march sees only the
// light that arrives directly, which leaves fog that is lit from one side and black from the other; the
// extra isotropic term stands in for the light that has bounced inside the medium.
public static const float FOG_MULTISCAT = 0.45;

// How far a storm dims the two lights the fog scatters. The deck above a storm passes a fraction of the
// sun and the sky term is a clear-sky answer, so both are pulled down with severity; without this a
// downpour renders as a bright fair-weather haze. The cloud layer keeps its own shading independent of
// these, and they are what makes the fog read as weather rather than as tinted air.
public static const float FOG_STORM_SUN_SCALE = 0.35;
public static const float FOG_STORM_AMBIENT_SCALE = 0.28;

// Floor on the march's jitter. The cloud march can afford to keep a fixed lattice because its budget is
// spent unevenly and its own detail is what the denoiser must preserve; the fog's strides are uniform over
// a smooth medium, so a fixed lattice shows as concentric shells around the viewer -- the one artifact a
// jitter exists to remove. It is therefore always jittered at least this much, whatever the clouds.jitter
// setting says, and the setting can still raise it.
public static const float FOG_JITTER_FLOOR = 0.6;

// Density multiplier for the End's haze at the same strength.
//
// The coefficients above are calibrated for rain falling out of a deck: the medium sits in a band a few
// hundred blocks tall with clear air above and below it. The End's haze fills the whole dimension instead,
// and at the rain fog's own coefficient it barely registers -- which is why it read as a tint rather than as
// weather. This is the one knob that separates the two.
public static const float END_HAZE_DENSITY = 4.0;

// ---- Dawn and dusk.
//
// The medium is not only a storm effect: the same air carries the mist that settles while the sun is on
// the horizon. That is a time of day rather than a weather state, so it has to appear with nothing
// raining, and it has to fade in and out instead of switching on, or the sky pops.
//
// The driver is the sun's own altitude. FOG_DUSK_SUN_HEIGHT is the half-width of a LINEAR window around
// the horizon: full weight with the sun sitting on it, zero once the sun is this far above or below, and a
// straight line in between. Both ends of the day share one window because the sun crosses the horizon
// twice and nothing about the medium differs between the crossings.
//
// A linear ramp rather than a smoothstep is deliberate. The window spans about +/-17 degrees, over which
// the sun's altitude changes linearly in wall-clock time to better than 1.5%, so the weight stays linear
// in time as well -- which is the property that makes the transition read as a gradual thickening rather
// than as a pop.
public static const float FOG_DUSK_SUN_HEIGHT = 0.30;
// Peak strength of the mist, as a fraction of a full storm. Morning mist is thick, but it is not a
// downpour; this is the single knob for how far the dusk fog is allowed to go.
public static const float FOG_DUSK_SCALE = 0.6;
// The deck the mist hangs under when the cloud layer is switched off. The push publishes a zero base
// altitude in that case, which would put the whole band underground and leave an overcast dusk with no fog
// at all. Mist does not need a cloud to exist, so it falls back to a plain altitude.
public static const float FOG_DEFAULT_DECK = 256.0;

// ---- Noise.
//
// Value noise on a hash lattice, wrapped on the two horizontal axes so the field tiles exactly. The fog is
// visible over a few kilometres, so a period of FOG_NOISE_CELLS cells x FOG_NOISE_SCALE keeps the wrap far
// past the point where the medium has gone opaque.

float fogHash(float3 p) {
    p = frac(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return frac((p.x + p.y) * p.z);
}

/** Hash of a lattice cell, with the two horizontal axes wrapped to `period`. */
float fogHashPeriodic(float3 cell, float period) {
    float3 w = cell;
    w.x = cell.x - floor(cell.x / period) * period;
    w.z = cell.z - floor(cell.z / period) * period;
    return fogHash(w);
}

float fogNoise3(float3 p, float period) {
    float3 i = floor(p);
    float3 f = p - i;
    f = f * f * (3.0 - 2.0 * f);
    float n000 = fogHashPeriodic(i + float3(0.0, 0.0, 0.0), period);
    float n100 = fogHashPeriodic(i + float3(1.0, 0.0, 0.0), period);
    float n010 = fogHashPeriodic(i + float3(0.0, 1.0, 0.0), period);
    float n110 = fogHashPeriodic(i + float3(1.0, 1.0, 0.0), period);
    float n001 = fogHashPeriodic(i + float3(0.0, 0.0, 1.0), period);
    float n101 = fogHashPeriodic(i + float3(1.0, 0.0, 1.0), period);
    float n011 = fogHashPeriodic(i + float3(0.0, 1.0, 1.0), period);
    float n111 = fogHashPeriodic(i + float3(1.0, 1.0, 1.0), period);
    float x00 = lerp(n000, n100, f.x);
    float x10 = lerp(n010, n110, f.x);
    float x01 = lerp(n001, n101, f.x);
    float x11 = lerp(n011, n111, f.x);
    return lerp(lerp(x00, x10, f.y), lerp(x01, x11, f.y), f.z);
}

public float fogFbm3(float3 p, int octaves, float period) {
    float sum = 0.0;
    float amplitude = 0.5;
    float total = 0.0;
    float3 q = p;
    float periodHere = period;
    for (int i = 0; i < octaves; i++) {
        sum += amplitude * fogNoise3(q, periodHere);
        total += amplitude;
        q *= 2.0;
        periodHere *= 2.0;
        amplitude *= 0.5;
    }
    return sum / max(total, 1.0e-6);
}

/**
 * Offset of the march's first sample, in blocks, confined to [0,1) of a stride.
 *
 * <p>The golden ratio's fractional part 1/phi is the stride: its continued fraction is all ones, which is
 * what makes the recurrence cover [0,1) as evenly as an additive sequence can. The offset is measured in
 * STRIDES rather than blocks so it re-places the sample lattice without changing the distance the march
 * covers -- the last segment is clamped to the band's exit either way, so the estimator stays unbiased.
 * It is a function of the pixel and the frame alone, so every segment of one ray's path uses the same
 * offset and a jittered fog cannot acquire an internal seam it did not have.
 */
float fogMarchJitter(uint2 pix, uint frameIndex, float step, float jitter) {
    if (jitter <= 0.0) {
        return 0.0;
    }
    const float GOLDEN_RECURRENCE = 0.6180339887;
    // A non-unit stride on y so the pixel lattice does not collapse onto one arithmetic progression.
    float n = float(pix.x) + float(pix.y) * 7.0 + float(frameIndex);
    return frac(n * GOLDEN_RECURRENCE) * step * jitter;
}

/**
 * Weight of the dawn/dusk mist at this frame's sun altitude: 1 with the sun on the horizon, falling
 * linearly to 0 at FOG_DUSK_SUN_HEIGHT above or below it. Never negative, so the window is a triangle
 * rather than a decaying tail through the night.
 *
 * <p>The sun direction is the true one (WorldPush.sunDir), not the frame's active NEE light: at night the
 * NEE light is the moon, and dusk is a property of the sun.
 */
public float duskFogWeight(WorldPush push) {
    return saturate(1.0 - abs(push.sunDir.y) / FOG_DUSK_SUN_HEIGHT);
}

/**
 * The frame's total fog strength: the one number that decides whether the medium exists at all, and how
 * thick it is relative to a full storm.
 *
 * <p>Rain and the dawn/dusk mist combine with max rather than a sum. They are the same medium seen twice,
 * and a thunderstorm at sunset should not stack into twice the extinction of either one alone.
 *
 * <p>Both are gated on the CPU's sky-exposure verdict, which is what keeps the medium out of sealed
 * interiors and below ground. A cave has no dawn.
 *
 * <p>The End has no atmosphere, so it has no dawn or dusk to fade through either. Its haze is driven purely
 * by the rain lane, which the CPU fills with the End's own fog strength there -- thickest while the dragon
 * lives, thinner once it has been beaten.
 */
public float rainFogStrength(WorldPush push, CloudLayer c) {
    // A submerged eye is inside a different medium, not under weather. The water's own absorption and
    // scattering are the medium stack's job; letting the rain fog render in there as well put a second,
    // unrelated veil over every underwater view.
    if (!c.skyExposed || (push.flags & 1u) != 0u) {
        return 0.0;
    }
    if ((push.flags & WORLD_FLAG_END_SKY) != 0u) {
        return saturate(c.rain);
    }
    return max(saturate(c.rain), duskFogWeight(push) * FOG_DUSK_SCALE);
}
/**
 * The frame's fog, resolved once per segment.
 *
 * <p>Everything expensive is folded in here rather than per sample: the light's direction and radiance, and
 * the sky term. The march below then only reads this struct.
 *
 * <p>The band is anchored to the cloud base from the push rather than to an absolute altitude, because the
 * push carries rebased coordinates and no ground plane. Both ends move with the deck, so a storm that
 * lowers the base lowers the fog with it, which is what a rain shaft under a descending nimbostratus deck
 * actually does. cloudA.z is a world altitude rather than a rebased one (see clouds.slang), which is why
 * the band's ends compare against the world-space sample positions in the march.
 */
public struct RainFog {
    public float extinction;   // per block at the bottom of the band
    public float top;          // world y of the band's top (the cloud base)
    public float bottom;       // world y below which the ray test stops accumulating; see FOG_FLOOR
    public float depth;        // height over which the density gradient falls to zero
    public float3 worldAnchor; // ray space + this = world space, the same anchor the cloud noise uses
    public float noiseAmount;
    public float3 sunDir;
    public float3 sunRadiance; // already storm-scaled
    public float3 skyRadiance;
    public float jitter;
    public CloudLayer clouds;  // the deck that shadows the fog; the god rays come from it
    public uint2 pixel;
    public uint frameIndex;
};

public RainFog makeRainFog(WorldPush push, CloudLayer c, uint2 pixel) {
    RainFog f;
    bool endSky = (push.flags & WORLD_FLAG_END_SKY) != 0u;
    // Two weights, deliberately. The medium's density follows the combined rain/mist strength, while the
    // storm's dimming of its two lights follows rain alone: applying the storm dimming to a clear dusk
    // would darken exactly the warm sky the mist is meant to be lit by.
    float rain = saturate(c.rain);
    float strength = rainFogStrength(push, c);
    // The End fills the whole dimension with its haze, so it carries its own density multiplier; see
    // END_HAZE_DENSITY.
    f.extinction = strength * FOG_EXTINCTION * (endSky ? END_HAZE_DENSITY : 1.0);
    // The band hangs under the deck, but mist does not need a cloud to exist, so a switched-off layer
    // falls back to a plain altitude instead of collapsing the band underground. That fallback is also what
    // carries the End, where the deck is deliberately published empty.
    f.top = cloudLayerActive(c) ? c.baseAltitude : FOG_DEFAULT_DECK;
    f.depth = FOG_DEPTH;
    f.bottom = min(f.top - f.depth, FOG_FLOOR);
    f.worldAnchor = c.worldAnchor;
    f.noiseAmount = FOG_NOISE_AMOUNT;
    f.jitter = max(c.jitter, FOG_JITTER_FLOOR);
    f.clouds = c;
    f.pixel = pixel;
    f.frameIndex = push.frameIndex;

    // The End's haze is not a storm, so it must not dim the light falling through it the way rain does.
    // That shading exists because a thunderhead blocks the sun; the End has no weather at all.
    float storm = endSky ? 0.0 : rain;

    // The frame's active directional light, in the same units terrain NEE uses, so fog light and surface
    // light cannot diverge.
    f.sunDir = push.lightDir.xyz;
    f.sunRadiance = max(push.lightRadiance.xyz, float3(0.0, 0.0, 0.0))
            * lerp(1.0, FOG_STORM_SUN_SCALE, storm);

    // Sky term: the same zenith the cloud layer's ambient uses, with the same two corrections -- desaturate
    // it toward its own luminance as the medium thickens (the atmosphere is a clear-sky answer), then apply
    // the storm's dimming, which a clear dusk does not get.
    //
    // The End samples its own glow instead: the atmosphere would tint the dimension with air it does not
    // have.
    float3 zenith = endSky
            ? END_SKY_GLOW
            : atmosphere(float3(0.0, 1.0, 0.0), push.sunDir.xyz)
                    + NIGHT_ZENITH * (1.0 - push.sunDir.w);
    // The End keeps its violet. Desaturation models a storm's grey overcast draining the sky of colour, and
    // the End's glow is not an overcast -- draining it would leave grey haze under a violet sky.
    zenith = endSky
            ? zenith
            : lerp(zenith, float3(dot(zenith, float3(0.2126, 0.7152, 0.0722))), strength);
    f.skyRadiance = zenith * CLOUD_AMBIENT_SCALE * lerp(1.0, FOG_STORM_AMBIENT_SCALE, storm);
    return f;
}

/** Extinction at a world position, per block. Zero at and above the deck, thickest at the bottom of the band. */
public float rainFogDensity(float3 worldPos, RainFog f, float stride) {
    if (f.extinction <= 0.0 || worldPos.y >= f.top) {
        return 0.0;
    }
    // Height falloff: the air is thickest at the bottom of the band and reaches zero at the deck, so there
    // is no step where the fog meets the cloud base.
    float h = saturate((f.top - worldPos.y) / max(f.depth, 1.0));
    float falloff = h * h * (3.0 - 2.0 * h);
    // The noise field's smallest feature is FOG_NOISE_FEATURE blocks across. Once the march's stride grows
    // past that, the field is being sampled below its own Nyquist limit and its samples stop being
    // structure: they lock onto the lattice and read as the diagonal banding that a long grazing path
    // shows. Weighting the noise by how much of it the CURRENT stride can resolve fades the detail out
    // smoothly instead of aliasing it.
    //
    // The weighting is mean-preserving -- the noise term averages to 1.0 for any weight, because
    // (1 - a) + a * E[2 * noise] = (1 - a) + a = 1 -- so only the visible detail changes with distance.
    // The density itself, which is integrated rather than sampled, is untouched at every range.
    float resolved = saturate(FOG_NOISE_FEATURE / max(stride, 1.0));
    float noiseAmount = f.noiseAmount * resolved;
    float noise = fogFbm3(worldPos * FOG_NOISE_SCALE, 2, FOG_NOISE_CELLS);
    return f.extinction * falloff
            * (1.0 - noiseAmount + noiseAmount * noise * 2.0);
}

/** Distance range over which the ray is inside the fog band. False when it never enters. */
public bool rainFogBandRange(float3 ro, float3 rd, RainFog f, out float t0, out float t1) {
    t0 = 0.0;
    t1 = 0.0;
    if (f.top <= f.bottom) {
        return false;
    }
    // A ray exactly parallel to the band never changes altitude: it either stays inside for its whole
    // length or misses, and clamping the slope keeps the two divides finite without a second code path.
    float slope = rd.y;
    if (abs(slope) < 1.0e-6) {
        slope = slope < 0.0 ? -1.0e-6 : 1.0e-6;
    }
    // The band's ends are world altitudes and the ray origin is rebased, so the origin is lifted back into
    // world space before the crossings are solved. The distances themselves are unaffected by that
    // translation, which is why the march can stay in ray space.
    float originY = ro.y + f.worldAnchor.y;
    float a = (f.bottom - originY) / slope;
    float b = (f.top - originY) / slope;
    float enter = min(a, b);
    float exit = max(a, b);
    t0 = max(enter, 0.0);
    t1 = exit;
    return exit > t0;
}

/**
 * Marches the fog over a segment and returns the radiance it scatters toward the viewer plus what survives
 * it.
 *
 * <p>Each step integrates the segment analytically, and the light a sample receives is the sun reduced by
 * whatever cloud stands between it and the top of the deck -- the same transmittance query the terrain's
 * shadow rays use. That reduction is what draws god rays: a sample under a break in the deck sees the
 * whole sun and one under a tower sees almost none, so the beams fall out of the deck's own silhouette
 * rather than from a separate effect.
 *
 * <p>Every part is gated on the medium having started, so a clear frame costs one comparison per segment
 * and never enters the loop.
 */
public CloudResult marchRainFog(float3 ro, float3 rd, float tMax, RainFog f) {
    CloudResult result;
    result.scattering = float3(0.0, 0.0, 0.0);
    result.transmittance = 1.0;
    result.depth = CLOUD_NO_HIT_DEPTH;
    if (f.extinction <= 0.0) {
        return result;
    }
    float t0;
    float t1;
    if (!rainFogBandRange(ro, rd, f, t0, t1)) {
        return result;
    }
    t1 = min(min(t1, tMax), FOG_MAX_DISTANCE);
    if (t1 <= t0) {
        return result;
    }

    float path = t1 - t0;
    // No minimum path length here, and that is deliberate. Skipping short segments looks free -- the fog
    // over a couple of dozen blocks is a fraction of a percent -- but the condition is on DISTANCE, and a
    // step in a distance-dependent medium is a sphere: the fog would switch on at a fixed radius around
    // the camera and that shell would travel with the player, dragging a visible edge across the ground.
    // The real fix for the two-block case is that the jitter offset is measured in STRIDES, the stride has
    // a FLOOR, and the offset is therefore clamped to the path below so it cannot land past the end.
    float step = max(path / float(FOG_STEPS), FOG_STEP_NEAR);
    float t = t0 + fogMarchJitter(f.pixel, f.frameIndex, min(step, path), f.jitter);
    float phase = cloudHenyeyGreenstein(dot(rd, f.sunDir), FOG_G);
    // The deck's shadow is resolved with a single midpoint sample rather than the layer's full light-march
    // budget. A god ray is the shadow of a cloud MASS hundreds of blocks up, so the column between the
    // sample and the deck already carries the large-scale gaps the shafts come from; the extra steps only
    // sharpen detail finer than the fog's own noise, and this query runs on every path segment rather than
    // once per pixel. Without a deck the sun term is unattenuated and the query is skipped entirely.
    CloudLayer shadowLayer = f.clouds;
    shadowLayer.lightSteps = 1;
    bool shadowed = cloudLayerActive(shadowLayer);

    float transmittance = 1.0;
    // Optical-depth-weighted centroid of the medium along this ray: the depth DLSS-RR reprojects by. A miss
    // reports no surface, and without this the fog is integrated against the sky's far plane — a depth that
    // only rotates with the camera and never translates — so a medium whose parallax does translate could
    // not converge and its march lattice stayed on screen as banding. Three adds per step, no extra rays.
    float depthWeightSum = 0.0;
    float depthWeightedSum = 0.0;
    for (int i = 0; i < FOG_STEPS; i++) {
        if (t >= t1) {
            break;
        }
        float segment = min(step, t1 - t);
        float3 p = ro + rd * (t + segment * 0.5);
        t += segment;
        // The density field and the deck that shadows it both live in world space, so the sample is
        // rebased once here rather than carrying the anchor through every helper.
        float3 worldPos = p + f.worldAnchor;
        float density = rainFogDensity(worldPos, f, segment);
        if (density <= 1.0e-6) {
            continue;
        }
        float stepTransmittance = exp(-density * segment);
        float3 sun = f.sunRadiance;
        if (shadowed) {
            sun *= cloudShadowTransmittance(worldPos, f.sunDir, 1.0e6, shadowLayer);
        }
        float3 source = (sun * phase + f.skyRadiance * FOG_MULTISCAT) * FOG_ALBEDO;
        float integrated = 1.0 - stepTransmittance;
        result.scattering += transmittance * source * integrated;
        depthWeightedSum += (t - segment * 0.5) * integrated;
        depthWeightSum += integrated;
        transmittance *= stepTransmittance;
        if (transmittance < 0.003) {
            // Opaque: everything the guide still averages sits at this distance.
            depthWeightedSum += t * transmittance;
            depthWeightSum += transmittance;
            break;
        }
    }
    result.transmittance = transmittance;
    if (depthWeightSum > 1.0e-5) {
        result.depth = depthWeightedSum / depthWeightSum;
    }
    return result;
}