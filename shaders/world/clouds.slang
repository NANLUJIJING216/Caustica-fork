// Volumetric cloud layer: density field, adaptive ray march, multiple-scattering approximation and a
// two-lobe Henyey-Greenstein phase function.
//
// The layer is a slab in world BLOCKS, the same space as ray origins, spanning
// [baseAltitude, baseAltitude + thickness]. Density is procedural rather than sampled from a 3D texture:
// the renderer owns no 3D image path, and a texture would cost a new descriptor binding on the one
// layout every world stage shares.
//
// Every entry point takes its configuration explicitly. The world miss shader shadows world_core's
// `worldPush` global with its own local, so nothing here may read that global.
//
// Consumed by world.rmiss (all radiance rays, so clouds appear in the primary view, reflections and
// refractions) and by trace.slang's shadow visibility (so the layer casts on the ground below it).

module clouds;

import world_common;
import world_core;
import sky;

// Noise frequencies, in inverse blocks, kept separate per axis.
//
// The horizontal scale sets how large one cloud body is, so it is deliberately coarse: a few hundred
// blocks of noise would tile the sky with many small puffs rather than a few large ones.
//
// The vertical scale is set so the layer's full thickness spans HALF a period (256 blocks over a 520-block
// period). That is the constraint that matters: any vertical structure approaching one period repeats
// inside the layer, and the march samples those repeats too coarsely to integrate them away, so they show
// up as horizontal banding. Height variation therefore comes from cloudHeightGradient's shape-driven top
// rather than from this frequency.
static const float CLOUD_BASE_FREQ_H = 1.0 / 750.0;
static const float CLOUD_BASE_FREQ_V = 1.0 / 520.0;
// The erosion field's vertical scale is bound by the same half-period rule as the base. Its octaves
// advance horizontally only, but that governs how many scales are summed â not the period of the single
// vertical scale, which at 150 blocks repeated 1.7 times inside the layer and banded on its own.
static const float CLOUD_DETAIL_FREQ_H = 1.0 / 150.0;
static const float CLOUD_DETAIL_FREQ_V = 1.0 / 520.0;

// Large-scale weather, coarse enough that the sky holds a few cloud systems rather than an even speckle.
static const float CLOUD_WEATHER_FREQUENCY = 1.0 / 2600.0;

// The altitude band over which the layer fades in at its base and out at its top, as fractions of the
// thickness. A wide fade at the top is what gives the layer a soft anvil rather than a cut-off slab.
static const float CLOUD_BASE_FADE = 0.10;
static const float CLOUD_TOP_FADE = 0.42;

// Extinction per block at unit density. Calibrated against the density field's measured vertical optical
// depth: at the default coverage a cloudy column integrates to roughly 6.3 density-blocks, so this value
// puts its transmittance near 0.32 â solid enough to read as cloud and to cast, still translucent enough
// to keep the sky behind it. A much lower coefficient leaves the layer looking like thin haze.
static const float CLOUD_EXTINCTION = 0.18;

// Cloud droplets scatter almost without absorbing, so single-scattering albedo is near one and the layer
// stays bright rather than grey.
static const float3 CLOUD_SCATTER_ALBEDO = float3(0.96, 0.96, 0.97);

// Henyey-Greenstein anisotropy. Forward dominates (strong silver lining into the sun); the weak backward
// lobe keeps the anti-solar side of a cloud from going flat black.
static const float CLOUD_PHASE_FORWARD_G = 0.80;
static const float CLOUD_PHASE_BACKWARD_G = -0.25;
static const float CLOUD_PHASE_BLEND = 0.35;

// Sky light filling cloud interiors, as a fraction of the dome's own radiance. Real cloud bases are lit
// from every direction by the sky above them; with a smaller fraction a thick layer reads as a hard black
// mass rather than a soft grey one.
// Shared with rainfog.slang, which scales its own sky term by the same fraction so fog and the deck it
// hangs under cannot disagree about how much of the dome reaches them.
public static const float CLOUD_AMBIENT_SCALE = 0.85;

// Reserved far value for the miss-side depth lane so a hit can be told from "no cloud" exactly.
public static const float CLOUD_NO_HIT_DEPTH = -1.0;

// Distant cloud is thinned rather than cut off.
//
// The distances are much shorter than they look: the layer sits ~220 blocks above eye level, so a view
// 10 degrees above the horizon meets it only ~1250 blocks away and 5 degrees meets it at ~2500. Fading
// from 2200 left that entire range at full density, which is the "slightly distant cloud is too dense"
// case. Full density now ends at 700 blocks and the far value is reached by ~6500.
static const float CLOUD_FADE_START = 500.0;
static const float CLOUD_FADE_RANGE = 4500.0;
static const float CLOUD_FAR_DENSITY = 0.12;

// Aerial perspective: how quickly distant cloud is washed toward the sky behind it, per block. This is
// the other half of the distant-density problem â a long grazing path through the layer is physically
// correct but reads as a solid wall, because a real atmosphere would have scattered that contrast away.
// Applied by the miss shader, which is where the sky behind the layer is still available.
public static const float CLOUD_AERIAL_PER_BLOCK = 1.5e-4;

// ---- Configuration, resolved once per ray from WorldPush.

public struct CloudLayer {
    public float baseAltitude;
    public float thickness;
    public float coverage;      // 0..1 sky fraction the layer fills
    public float densityScale;
    public float erosion;       // 0..1 how far erosion carves into the body
    public float2 windOffset;   // blocks of horizontal drift applied to the noise domain
    public float lightning;     // 0..1 thunderstorm emission inside the layer
    public float jitter;        // 0..1 first-sample offset along the ray, in steps
    public float rain;          // 0..1 the level's current rain level
    public float2 windPerFrame; // blocks the noise domain advanced this frame, for DLSS-RR motion
    public float3 worldAnchor;  // rebase origin: ray space + this = world space
    public bool skyExposed;     // CPU verdict: the camera is under open sky (see WorldPush.cloudAnchor.w)
    public int viewSteps;
    public int lightSteps;
    public int multiScatterOctaves;
    public int detailOctaves;
};

public CloudLayer cloudLayer(WorldPush push) {
    CloudLayer layer;
    layer.baseAltitude = push.cloudA.z;
    layer.thickness = push.cloudA.w;
    layer.coverage = clamp(push.cloudA.x, 0.0, 1.0);
    layer.densityScale = max(push.cloudA.y, 0.0);
    layer.erosion = clamp(push.cloudB.x, 0.0, 1.0);
    layer.windOffset = push.cloudB.yz;
    layer.lightning = clamp(push.cloudB.w, 0.0, 1.0);
    layer.jitter = clamp(push.cloudC.x, 0.0, 1.0);
    layer.rain = clamp(push.cloudC.w, 0.0, 1.0);
    layer.windPerFrame = push.cloudC.yz;
    layer.worldAnchor = push.cloudAnchor.xyz;
    // Published as a 0/1 lane. Which side of the sky the camera is on is a CPU question â Minecraft knows
    // whether the eye has open sky above it, and no amount of per-ray work in the shader answers it for a
    // sealed room whose rays can still be long or still escape through a window.
    layer.skyExposed = push.cloudAnchor.w > 0.5;
    layer.viewSteps = int(push.cloudD.x);
    layer.lightSteps = int(push.cloudD.y);
    layer.multiScatterOctaves = int(push.cloudD.z);
    layer.detailOctaves = int(push.cloudD.w);
    return layer;
}

/** A layer with zero thickness is off; cloudLayer() publishes exactly that for the "off" preset. */
public bool cloudLayerActive(CloudLayer layer) {
    return layer.thickness > 0.0 && layer.viewSteps > 0 && layer.densityScale > 0.0;
}

// ---- Noise. Value noise rather than a true gradient Perlin: it costs eight hashes per octave instead of
// twelve plus a gradient table, and at the octave counts the layer can afford the difference is invisible
// once the base is combined with Worley and the coverage remap.

float cloudHash13(float3 p) {
    p = frac(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return frac((p.x + p.y) * p.z);
}

/** Trilinearly interpolated value noise on the unit lattice, in [0,1]. */
float cloudValueNoise(float3 p) {
    float3 i = floor(p);
    float3 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);

    float n000 = cloudHash13(i + float3(0.0, 0.0, 0.0));
    float n100 = cloudHash13(i + float3(1.0, 0.0, 0.0));
    float n010 = cloudHash13(i + float3(0.0, 1.0, 0.0));
    float n110 = cloudHash13(i + float3(1.0, 1.0, 0.0));
    float n001 = cloudHash13(i + float3(0.0, 0.0, 1.0));
    float n101 = cloudHash13(i + float3(1.0, 0.0, 1.0));
    float n011 = cloudHash13(i + float3(0.0, 1.0, 1.0));
    float n111 = cloudHash13(i + float3(1.0, 1.0, 1.0));

    float x00 = lerp(n000, n100, f.x);
    float x10 = lerp(n010, n110, f.x);
    float x01 = lerp(n001, n101, f.x);
    float x11 = lerp(n011, n111, f.x);
    return lerp(lerp(x00, x10, f.y), lerp(x01, x11, f.y), f.z);
}

/** Fractal value noise, normalised to [0,1]. */
float cloudFbmValue(float3 p, int octaves) {
    float sum = 0.0;
    float amplitude = 0.5;
    float norm = 0.0;
    for (int i = 0; i < octaves; i++) {
        sum += amplitude * cloudValueNoise(p);
        norm += amplitude;
        // Octaves advance HORIZONTALLY only, and deliberately so. The layer is a few hundred blocks
        // thick, so a vertical octave repeats several times inside it and the march samples far too
        // coarsely to integrate those repeats away â they alias into horizontal banding. Holding the
        // vertical frequency fixed buys edge detail, which is what reads, without the banding.
        p.xz *= 2.03;
        amplitude *= 0.5;
    }
    return norm > 0.0 ? sum / norm : 0.0;
}

/**
 * Fractal billow noise: each octave is folded about its midpoint, which turns value noise's gentle bumps
 * into the rounded, separated lobes that read as cumulus. This stands in for the Worley term a
 * Perlin-Worley base would use â a 3x3x3 cellular search costs 27 hashes per octave against this field's
 * 8, and the layer is evaluated tens of times per ray, so the cellular version is unaffordable without a
 * baked 3D texture.
 */
float cloudBillowNoise(float3 p, int octaves) {
    float sum = 0.0;
    float amplitude = 0.5;
    float norm = 0.0;
    for (int i = 0; i < octaves; i++) {
        float n = abs(cloudValueNoise(p) * 2.0 - 1.0);
        sum += amplitude * n;
        norm += amplitude;
        p.xz *= 2.03;
        amplitude *= 0.5;
    }
    return norm > 0.0 ? sum / norm : 0.0;
}

/** Base shape: billow lobes stretched by a broader fbm so the body has both structure and mass. */
float cloudBaseShape(float3 p, int octaves) {
    int count = max(octaves, 1);
    float billow = cloudBillowNoise(p, count);
    float body = cloudFbmValue(p * 0.45, max(count - 1, 1));
    // Billow fbm clusters tightly around its mean, so the raw field clears a high coverage threshold
    // almost nowhere â which is what an empty sky looks like. Lifting and expanding it here is what
    // lets the coverage threshold below behave like a percentile. This replaces the value range a
    // Perlin-Worley base gets for free from its own skewed distribution.
    return saturate(saturate(billow * 0.7 + body * 0.3) * 1.25 + 0.10);
}

/**
 * High-frequency field that carves the wispy edges.
 *
 * Contrast-expanded about its midpoint: raw fbm clusters tightly around its mean, so the erosion it
 * drives would be nearly uniform and the silhouette would stay smooth however many octaves are added.
 * Widening the distribution is what turns the erosion into distinct carved edges.
 */
float cloudDetailShape(float3 p, int octaves) {
    float n = cloudFbmValue(p, octaves);
    return saturate((n - 0.5) * 1.9 + 0.5);
}

/** GLSL-style remap; Slang's core module does not provide one. */
public float cloudRemap(float value, float inMin, float inMax, float outMin, float outMax) {
    float t = saturate((value - inMin) / max(inMax - inMin, 1.0e-6));
    return outMin + t * (outMax - outMin);
}

// ---- Weather.

/**
 * Large-scale coverage multiplier. A slow two-octave field breaks the layer into cloud systems instead of
 * an even sheet, and the narrow remap window makes each region decisively clear or cloudy â a wide window
 * leaves the sky speckled with mid-sized puffs everywhere, which reads as haze rather than weather.
 */
float cloudCoverageAt(float2 xz) {
    float2 p = xz * CLOUD_WEATHER_FREQUENCY;
    float n = cloudValueNoise(float3(p, 7.3)) * 0.65
            + cloudValueNoise(float3(p * 2.7, 19.1)) * 0.35;
    return saturate(cloudRemap(n, 0.34, 0.72, 0.0, 1.0));
}

// ---- Density.

/**
 * Vertical profile: a flat base rising over CLOUD_BASE_FADE, and an anvil whose own height follows the
 * column's horizontal shape.
 *
 * Making the top height a function of `shape` rather than a fixed fraction of the thickness is what gives
 * the layer a billowed, uneven top, and it is deliberately driven by HORIZONTAL variation. The layer is
 * only a few hundred blocks thick, so any vertical structure at a comparable frequency repeats inside it
 * and the march samples those repeats far too coarsely to integrate them away; that is exactly what the
 * horizontal banding is. Raising the vertical frequency to add height trades flatness for banding, so the
 * height has to come from here instead.
 */
float cloudHeightGradient(float heightFraction, float shape) {
    float base = saturate(heightFraction / CLOUD_BASE_FADE);
    float topHeight = lerp(0.62, 1.0, saturate(shape));
    float top = saturate((topHeight - heightFraction) / CLOUD_TOP_FADE);
    // Squaring the base term keeps the underside flat instead of domed.
    return base * base * top;
}

/**
 * Density in [0, densityScale] at a world position, 0 outside the slab. This is the single density model
 * shared by the view march, the light march and the shadow transmittance, so a cloud's lit side and its
 * shadow cannot disagree.
 */
public float cloudDensityAt(float3 worldPos, CloudLayer layer) {
    float altitude = worldPos.y - layer.baseAltitude;
    if (altitude < 0.0 || altitude >= layer.thickness) {
        return 0.0;
    }
    float heightFraction = altitude / layer.thickness;

    float3 p = worldPos;
    p.xz += layer.windOffset;

    // Shape is evaluated before the height profile because the profile's top height depends on it. The
    // vertical frequency is a fraction of the layer's thickness (see CLOUD_BASE_FREQ_V), so this field
    // varies slowly along Y and what comes back is effectively the column's horizontal shape.
    float3 basePos = p * float3(CLOUD_BASE_FREQ_H, CLOUD_BASE_FREQ_V, CLOUD_BASE_FREQ_H);
    float shape = cloudBaseShape(basePos, layer.detailOctaves);

    // Erosion is evaluated here too, ahead of the profile, so the cloud's TOP can be driven by it. The
    // base shape's own scale is far too broad to give the top any visible relief; the finer field is
    // what turns a smooth ridge into separate billows. Both drivers are horizontal, which is what keeps
    // the relief out of the vertical frequency that would band.
    float3 detailPos = p * float3(CLOUD_DETAIL_FREQ_H, CLOUD_DETAIL_FREQ_V, CLOUD_DETAIL_FREQ_H);
    float detail = cloudDetailShape(detailPos, layer.detailOctaves);
    float topDriver = saturate(shape * 0.55 + detail * 0.45);

    float heightGradient = cloudHeightGradient(heightFraction, topDriver);
    if (heightGradient <= 0.0) {
        return 0.0;
    }

    // The weather field modulates the configured coverage rather than multiplying it down. Its own mean
    // is about 0.42, so a plain product would silently cap every coverage setting at about 0.68 of the
    // value the user asked for; averaging it toward one keeps `coverage` meaning the sky fraction it is
    // named for while the field still breaks the layer into systems instead of an even sheet.
    float coverage = clamp(layer.coverage * (0.75 + 0.50 * cloudCoverageAt(p.xz)), 0.0, 1.0);

    // The threshold is mapped explicitly instead of as a literal "1 - coverage". The pre-threshold term
    // (shape * heightGradient) has a measured mean of 0.41, so a literal threshold of 1 - 0.40 would sit
    // above almost every sample and leave the sky empty. The endpoints below are fitted to that field's
    // quantiles, which makes the resulting sky fraction track the setting almost linearly: 0.10 -> 12%,
    // 0.40 -> 40%, 0.90 -> 91%.
    float threshold = lerp(0.75, 0.0, coverage);
    float density = cloudRemap(shape * heightGradient, threshold, 1.0, 0.0, 1.0);
    if (density <= 0.0) {
        return 0.0;
    }

    // Erosion retreats near the base, which is the physically thin, freshly condensed part of a cloud.
    float erosion = layer.erosion * (1.0 - detail);
    erosion *= lerp(1.0, 0.4, saturate(1.0 - heightFraction * 2.5));
    density = cloudRemap(density, erosion, 1.0, 0.0, 1.0);

    return saturate(density) * layer.densityScale;
}

// ---- Phase function.

/** Henyey-Greenstein. g > 0 forward-scatters, g < 0 back-scatters. */
public float cloudHenyeyGreenstein(float cosTheta, float g) {
    float g2 = g * g;
    float denom = 1.0 + g2 - 2.0 * g * cosTheta;
    return (1.0 - g2) / (4.0 * PI * pow(max(denom, 1.0e-4), 1.5));
}

/**
 * Two-lobe phase: a strong forward lobe for the silver lining and a weak backward lobe so the shadowed
 * side keeps some shape. Blending the lobes rather than summing them keeps the function's integral near
 * one, which is what the single-scattering estimator assumes.
 */
public float cloudPhase(float cosTheta) {
    return lerp(cloudHenyeyGreenstein(cosTheta, CLOUD_PHASE_FORWARD_G),
                cloudHenyeyGreenstein(cosTheta, CLOUD_PHASE_BACKWARD_G),
                CLOUD_PHASE_BLEND);
}

// ---- Scattering.

/**
 * Multiple-scattering approximation after Wrenninge et al.: a geometric series of ever-cheaper octaves,
 * each attenuating by the previous octave's optical depth and scattering a fraction of what it carries.
 * This is what gives thick cloud its bright, luminous interior instead of the dark core a single-scatter
 * Beer term produces.
 */
public float3 cloudMultipleScattering(float opticalDepth, float3 extinction, int octaves) {
    if (octaves <= 1) {
        return exp(-opticalDepth * extinction);
    }
    float3 accumulated = float3(0.0);
    float contribution = 1.0;
    float attenuation = 1.0;
    for (int i = 0; i < octaves; i++) {
        float3 beer = exp(-opticalDepth * extinction * attenuation);
        accumulated += contribution * beer;
        contribution *= 0.5;
        attenuation *= 0.5;
    }
    // Normalised so the octave sum is a transmittance-like weight, not an unbounded gain.
    return accumulated / (1.0 + 0.5 + 0.25);
}

/**
 * Light arriving at a point inside the layer from the sun: transmittance along a short march toward the
 * light, the phase function, and the powder term that darkens the thin edges facing the light (a
 * single-scatter artefact real clouds do not show).
 */
public float3 cloudLightEnergy(float3 position, float3 lightDir, float3 viewDir,
                               float3 lightIlluminance, CloudLayer layer, float stepSize) {
    float opticalDepth = 0.0;
    float3 samplePos = position;
    float lightStep = max(layer.thickness / float(max(layer.lightSteps, 1)), stepSize);
    for (int i = 0; i < layer.lightSteps; i++) {
        samplePos += lightDir * lightStep;
        opticalDepth += cloudDensityAt(samplePos, layer) * lightStep;
    }
    opticalDepth *= CLOUD_EXTINCTION;

    float3 transmittance = cloudMultipleScattering(opticalDepth, CLOUD_SCATTER_ALBEDO,
            layer.multiScatterOctaves);

    // Phase is the angle between the two directions the light takes through this sample: it arrives
    // along lightDir and leaves toward the viewer. Both point away from the sample, so their dot product
    // is 1 exactly when the viewer looks along the light â the silver-lining case. This is a per-sample
    // quantity and cannot be replaced by any fixed direction.
    float cosTheta = dot(lightDir, viewDir);
    float phase = cloudPhase(cosTheta);

    // Powder: the self-shadowing that keeps a cloud's lit face a soft solid rather than a flat wash. It
    // is applied where the view runs AGAINST the light, never with it â applying it forward would
    // subtract exactly the light the phase function is concentrating there and erase the silver lining.
    float powder = 1.0 - exp(-opticalDepth * 2.0);
    powder = lerp(1.0, powder, 0.5 * saturate(-cosTheta));

    return transmittance * lightIlluminance * phase * powder;
}

// ---- March.

public struct CloudResult {
    public float3 scattering;    // in-scattered radiance toward the viewer (ACEScg)
    public float transmittance;  // 1 = no cloud along the ray
    public float depth;          // representative distance in blocks, or CLOUD_NO_HIT_DEPTH
};

/**
 * Ray/slab intersection: the near and far distances where the ray crosses the layer's altitude band.
 * Returns false when the ray never enters it.
 */
public bool cloudSlabSpan(float3 origin, float3 dir, CloudLayer layer,
                          out float nearDistance, out float farDistance) {
    nearDistance = 0.0;
    farDistance = 0.0;
    float bottom = layer.baseAltitude;
    float top = layer.baseAltitude + layer.thickness;

    // Horizontal rays never change altitude, so they only count when already inside the band.
    if (abs(dir.y) < 1.0e-6) {
        if (origin.y < bottom || origin.y > top) {
            return false;
        }
        nearDistance = 0.0;
        farDistance = 1.0e9;
        return true;
    }

    float t0 = (bottom - origin.y) / dir.y;
    float t1 = (top - origin.y) / dir.y;
    nearDistance = min(t0, t1);
    farDistance = max(t0, t1);
    nearDistance = max(nearDistance, 0.0);
    return farDistance > nearDistance;
}

/**
 * March the cloud layer. `jitter` in [0,1) offsets the first sample so successive frames integrate
 * different points; the resulting noise is what DLSS Ray Reconstruction is given to resolve, which is
 * why the layer deliberately does not smooth itself.
 *
 * The step size grows with distance, so near cloud is resolved and far cloud is merely integrated. The
 * march stops early once transmittance is negligible.
 */
public CloudResult marchClouds(float3 rayOrigin, float3 dir, float maxDistance, CloudLayer layer,
                               float3 lightDir, float3 lightIlluminance, float3 ambientRadiance,
                               float jitter) {
    CloudResult result;
    result.scattering = float3(0.0);
    result.transmittance = 1.0;
    result.depth = CLOUD_NO_HIT_DEPTH;

    // Ray space is rebased against the terrain, so it shifts whenever the player's block crosses the
    // rebase threshold. The slab test is a pure altitude query and does not care, but the density field
    // must be sampled in world space: evaluated in ray space the entire layer translates with the player,
    // which reads as the clouds following the camera. One add here fixes the whole march, including the
    // light and shadow marches that sample cloudDensityAt with these same world positions.
    float3 origin = rayOrigin + layer.worldAnchor;

    float nearDistance;
    float farDistance;
    if (!cloudSlabSpan(origin, dir, layer, nearDistance, farDistance)) {
        return result;
    }
    farDistance = min(farDistance, maxDistance);
    if (farDistance <= nearDistance) {
        return result;
    }

    int steps = max(layer.viewSteps, 1);
    float span = farDistance - nearDistance;

    // Weighted by distance so the integral lands on the same expectation as a uniform march however the
    // adaptive step sizes distribute the samples.
    float depthWeightSum = 0.0;
    float depthWeightedSum = 0.0;

    float t = nearDistance + jitter * (span / float(steps));
    // Optical depth from the layer's entry to the sample being shaded. Ambient light is attenuated by
    // what sits above the sample rather than by one step, since it arrives from the whole sky.
    float depthAbove = 0.0;
    for (int i = 0; i < steps; i++) {
        // Adaptive step: smaller near the camera where the ray's footprint is small, longer far away. The
        // growth is kept mild â at a low view angle the in-layer path reaches several thousand blocks, and
        // a steeper ramp would push the far steps past the density field's own feature size and band.
        float stepSize = (span / float(steps)) * (1.0 + 0.5 * (t - nearDistance) / max(span, 1.0));
        float3 position = origin + dir * t;
        float density = cloudDensityAt(position, layer);

        if (density > 0.0) {
            // Distant cloud thins out. One pixel at long range stacks thousands of blocks of layer, and
            // holding full density there turns the horizon into an opaque band instead of cloud.
            density *= lerp(1.0, CLOUD_FAR_DENSITY,
                    saturate((t - CLOUD_FADE_START) / CLOUD_FADE_RANGE));
        }
        if (density > 0.0) {
            float extinction = density * CLOUD_EXTINCTION;
            float sampleTransmittance = exp(-extinction * stepSize);
            depthAbove += extinction * stepSize;
            float3 lightEnergy = cloudLightEnergy(position, lightDir, dir, lightIlluminance, layer, stepSize);

            // Attenuation is deliberately weak: multiple scattering keeps a thick cloud's interior lit,
            // which is why the shadowed side of a real cloud is grey rather than black. Attenuating
            // ambient at the same rate as direct light is what makes cloud undersides look like holes.
            float3 ambient = ambientRadiance * CLOUD_AMBIENT_SCALE * exp(-depthAbove * 0.30);

            // Analytic integration of the constant-density segment, matching the sky's own treatment.
            float3 segmentScatter = (lightEnergy + ambient) * CLOUD_SCATTER_ALBEDO;
            float integrated = 1.0 - sampleTransmittance;
            result.scattering += result.transmittance * segmentScatter * integrated;

            float weight = integrated;
            depthWeightedSum += t * weight;
            depthWeightSum += weight;

            result.transmittance *= sampleTransmittance;
            if (result.transmittance < 0.01) {
                // Opaque: accumulate the remaining depth weight at this distance and stop.
                depthWeightedSum += t * result.transmittance;
                depthWeightSum += result.transmittance;
                result.transmittance = 0.0;
                break;
            }
        }
        t += stepSize;
        if (t >= farDistance) {
            break;
        }
    }

    // Representative depth for DLSS-RR: the optical-depth-weighted centroid of the layer, which
    // reprojects far more stably than the first opaque sample.
    if (depthWeightSum > 1.0e-5) {
        result.depth = depthWeightedSum / depthWeightSum;
    }
    return result;
}

// ---- Shadow visibility.

/**
 * Transmittance of the layer along a shadow ray. The step count is deliberately lower than the view
 * march: this runs per shadow ray, and cloud shadows on the ground are soft and low-frequency, so the
 * result is filtered by its own integration rather than by extra samples.
 */
public float3 cloudShadowTransmittance(float3 origin, float3 dir, float maxDistance, CloudLayer layer) {
    float3 transmittance = float3(1.0);
    if (!cloudLayerActive(layer)) {
        return transmittance;
    }
    float nearDistance;
    float farDistance;
    if (!cloudSlabSpan(origin, dir, layer, nearDistance, farDistance)) {
        return transmittance;
    }
    farDistance = min(farDistance, maxDistance);
    if (farDistance <= nearDistance) {
        return transmittance;
    }

    int steps = max(layer.lightSteps, 1);
    float stepSize = (farDistance - nearDistance) / float(steps);
    float opticalDepth = 0.0;
    for (int i = 0; i < steps; i++) {
        float t = nearDistance + (float(i) + 0.5) * stepSize;
        opticalDepth += cloudDensityAt(origin + dir * t, layer) * stepSize;
        if (opticalDepth * CLOUD_EXTINCTION > 12.0) {
            break;  // fully opaque; further samples cannot change the result
        }
    }
    return exp(-opticalDepth * CLOUD_EXTINCTION);
}


/**
 * First-sample offset for the view march, in steps.
 *
 * Every stage that marches the same ray must derive the same offset from the same inputs, so the hash
 * lives here instead of being duplicated per stage: the pixel decorrelates neighbouring rays and the
 * frame index decorrelates successive frames, which is what turns the step lattice into the white noise
 * the denoiser is given to resolve. layer.jitter scales the whole thing, and 0 (the default) keeps the
 * deterministic sample lattice.
 */
public float cloudJitter(CloudLayer layer, float2 pixel, uint frameIndex) {
    return layer.jitter * cloudHash13(float3(pixel, float(frameIndex & 63u)));
}