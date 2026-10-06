// Physically-based atmosphere (Nishita / O'Neil single scattering + ozone absorption).
//
// Extracted verbatim from world.rmiss.slang. It lives in its own module because the volumetric cloud
// layer has to be lit by the SAME sky the miss shader draws: a cloud shaded against a second, drifting
// copy of the atmosphere seams at its silhouette against the sky behind it. The maths, the constants and
// the step counts are unchanged from the file this came from - this is a move, not a rewrite.
//
// A view ray is marched through the atmospheric shell; at each step the transmittance toward the sun is
// integrated (a second, shorter march), giving Rayleigh (blue-sky / red-sunset) + Mie (sun halo)
// in-scattered radiance. World up = +Y; the camera sits a couple km above a spherical planet. Output is
// HDR in the same units as tracePath.
module sky;

import world_common;

static const float SKY_PI = 3.14159265359;
static const float  PLANET_R   = 6371000.0;
static const float  ATMOS_R    = 6471000.0;        // 100 km shell
static const float3 RAY_BETA   = float3(5.5e-6, 13.0e-6, 22.4e-6); // Rayleigh scattering at sea level
static const float  MIE_BETA   = 21.0e-6;          // Mie scattering at sea level
static const float  RAY_SCALE_H = 8000.0;          // Rayleigh density scale height
static const float  MIE_SCALE_H = 1200.0;          // Mie density scale height
static const float  MIE_G      = 0.758;            // Mie anisotropy (forward-scattering)
// Ozone: absorption only (no scattering), tent-shaped density peaking at 25 km. Its green-heavy
// absorption keeps the zenith deep blue at noon and turns twilight purple-orange.
static const float3 OZONE_BETA = float3(0.650e-6, 1.881e-6, 0.085e-6);
static const float  OZONE_CENTER_H = 25000.0;
static const float  OZONE_WIDTH_H  = 15000.0;
static const float  SUN_INTENSITY = 22.0;
static const int    ATMOS_PRIMARY_STEPS = 16;
static const int    ATMOS_LIGHT_STEPS   = 8;

public float ozoneDensity(float h) { return max(0.0, 1.0 - abs(h - OZONE_CENTER_H) / OZONE_WIDTH_H); }

// Smaller root of ray vs sphere of radius r centred at origin (no-hit handled by x > y).
public float2 raySphere(float3 o, float3 d, float r) {
    float b = dot(o, d);
    float c = dot(o, o) - r * r;
    float disc = b * b - c;
    if (disc < 0.0) return float2(1.0e9, -1.0e9);
    disc = sqrt(disc);
    return float2(-b - disc, -b + disc);
}

public float3 atmosphere(float3 dir, float3 sunDir) {
    float3 orig = float3(0.0, PLANET_R + 2000.0, 0.0);
    float2 t = raySphere(orig, dir, ATMOS_R);
    if (t.x > t.y) return float3(0.0, 0.0, 0.0);      // ray misses the atmosphere entirely
    float tStart = max(t.x, 0.0);
    float tEnd = t.y;
    float2 tGround = raySphere(orig, dir, PLANET_R);
    if (tGround.x > 0.0) tEnd = min(tEnd, tGround.x); // clip the march at the planet surface
    float segLen = (tEnd - tStart) / float(ATMOS_PRIMARY_STEPS);

    float mu = dot(dir, sunDir);
    float phaseR = 3.0 / (16.0 * SKY_PI) * (1.0 + mu * mu);
    float g = MIE_G;
    float phaseM = 3.0 / (8.0 * SKY_PI) * ((1.0 - g * g) * (1.0 + mu * mu))
                 / ((2.0 + g * g) * pow(max(1.0 + g * g - 2.0 * g * mu, 0.0), 1.5));

    float3 sumR = float3(0.0, 0.0, 0.0), sumM = float3(0.0, 0.0, 0.0);
    float odR = 0.0, odM = 0.0, odO = 0.0;            // view-ray optical depth accumulators
    float tCur = tStart;
    for (int i = 0; i < ATMOS_PRIMARY_STEPS; i++) {
        float3 p = orig + dir * (tCur + segLen * 0.5);
        float h = length(p) - PLANET_R;
        float hr = exp(-h / RAY_SCALE_H) * segLen;
        float hm = exp(-h / MIE_SCALE_H) * segLen;
        odR += hr; odM += hm; odO += ozoneDensity(h) * segLen;

        // March toward the sun to accumulate the light-ray optical depth (transmittance to space).
        float2 tl = raySphere(p, sunDir, ATMOS_R);
        float segLenL = tl.y / float(ATMOS_LIGHT_STEPS);
        float tlCur = 0.0, odRL = 0.0, odML = 0.0, odOL = 0.0;
        bool blocked = false;
        for (int j = 0; j < ATMOS_LIGHT_STEPS; j++) {
            float3 pl = p + sunDir * (tlCur + segLenL * 0.5);
            float hl = length(pl) - PLANET_R;
            if (hl < 0.0) { blocked = true; break; } // sun is below this point's horizon -> in shadow
            odRL += exp(-hl / RAY_SCALE_H) * segLenL;
            odML += exp(-hl / MIE_SCALE_H) * segLenL;
            odOL += ozoneDensity(hl) * segLenL;
            tlCur += segLenL;
        }
        if (!blocked) {
            float3 tau = RAY_BETA * (odR + odRL) + MIE_BETA * 1.1 * (odM + odML)
                       + OZONE_BETA * (odO + odOL);
            float3 atten = exp(-tau);
            sumR += hr * atten;
            sumM += hm * atten;
        }
        tCur += segLen;
    }
    return SUN_INTENSITY * (sumR * RAY_BETA * phaseR + sumM * MIE_BETA * phaseM);
}

// Extinction from the camera to space along `dir` (Rayleigh + Mie + ozone; the sun-below-horizon case
// needs no explicit planet test - a grazing/downward path picks up enormous optical depth, so the
// transmittance rolls to zero smoothly on its own). Tints the sun/moon discs at draw time, and is ported
// verbatim to RtComposite.writeSky so the NEE sunlight on terrain follows the identical sunset curve -
// the disc, the sky, and the light can never disagree.
public float3 transmittanceToSpace(float3 dir) {
    float3 orig = float3(0.0, PLANET_R + 2000.0, 0.0);
    float2 t = raySphere(orig, dir, ATMOS_R);
    if (t.y <= 0.0) return float3(1.0, 1.0, 1.0);
    float segLen = t.y / float(ATMOS_LIGHT_STEPS);
    float odR = 0.0, odM = 0.0, odO = 0.0;
    for (int i = 0; i < ATMOS_LIGHT_STEPS; i++) {
        float3 p = orig + dir * (segLen * (float(i) + 0.5));
        float h = length(p) - PLANET_R;
        odR += exp(-h / RAY_SCALE_H) * segLen;
        odM += exp(-h / MIE_SCALE_H) * segLen;
        odO += ozoneDensity(h) * segLen;
    }
    return exp(-(RAY_BETA * odR + MIE_BETA * 1.1 * odM + OZONE_BETA * odO));
}

// ---- The End's sky.
//
// Both constants live here because they describe the same sky and both are consumed by more than one
// stage: the miss shader draws with them, and rainfog.slang lights the End's haze with them.
//
// The End has no atmosphere, so strictly its sky is a starfield and nothing else. A literally black sky is
// also the ONLY ambient term the End's terrain receives: with it gone the ground is lit by the moon alone
// and reads as unlit rock. Vanilla's End is not black either - it carries a dim violet wash that every
// surface there is shaded by. This constant is that wash, and it is also the colour the End's haze
// scatters.
public static const float3 END_SKY_GLOW = float3(0.035, 0.015, 0.055);

// The End's moon is a dull red rather than the overworld's white, and it is the only colour that
// dimension's light has. The tint reaches the light NEE samples - and therefore everything the moon
// illuminates, the haze included - as well as the disc drawn in the sky, so the two cannot disagree.
public static const float3 END_MOON_COLOR = float3(1.0, 0.34, 0.24);

// The End's moon is its only directional light, and it is scaled up by this much.
//
// Two reasons, both specific to the dimension. The atmospheric curve that normally dims a low moon is
// skipped there (the End has no air), so nothing needs compensating; and the End has no sky light at all,
// so a moon at the overworld's brightness leaves the terrain unreadable. A legibility constant, not a
// physical one, and set high enough that the red tint above - which removes roughly half the moon's
// luminance - still leaves the terrain readable. Applied on the CPU (see RtComposite.skyPush).
public static const float END_MOON_BOOST = 6.0;

// Faint night-sky ambient so the night isn't pure black where the atmosphere in-scatter falls to zero.
//
// Lives here with the rest of the sky so every stage that shades itself with this sky - the miss shader and
// the fog, which needs a floor under the zenith term or a windless night would render as black air - reads
// one definition.
public static const float3 NIGHT_ZENITH  = float3(0.004, 0.008, 0.022) / 5.0;
public static const float3 NIGHT_HORIZON = float3(0.015, 0.022, 0.045) / 5.0;