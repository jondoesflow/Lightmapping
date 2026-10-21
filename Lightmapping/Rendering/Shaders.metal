#include <metal_stdlib>
using namespace metal;

// Keep these structs in lock-step with ShaderTypes.swift.

struct GeneratorUniforms {
    float4 colorA;
    float4 colorB;
    float4 colorC;
    float2 resolution;
    float time;
    float speed;
    float scale;
    float intensity;
    float audioLevel;
    float audioBass;
    float audioMid;
    float audioHigh;
    float seed;
    int kind;
    float hasMask;
    float hasDepth;
};

struct LayerUniforms {
    float4 crop;
    float2 srcSize;
    float2 dstSize;
    float kaleido;
    float tile;
    float slideX;
    float slideY;
    float rotate;
    float zoom;
    float blur;
    float mono;
    float invert;
    float hueShift;
    float opacity;
    float time;
    int fit;
    float pad0;
    float pad1;
    float pad2;
};

struct SurfaceUniforms {
    float4 tint;
    float opacity;
    float feather;
    float hasMask;
    float pad;
};

struct TransitionUniforms {
    float progress;
    int style;
    float time;
    float pad;
};

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

// Single triangle covering the viewport; uv is y-down to match texture space.
vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 pos = float2((vid << 1) & 2, vid & 2);
    FullscreenOut out;
    out.position = float4(pos * 2.0 - 1.0, 0, 1);
    out.uv = float2(pos.x, 1.0 - pos.y);
    return out;
}

// MARK: - Helpers

constant float PI = 3.14159265;
constant float TAU = 6.2831853;

float hash11(float p) { p = fract(p * 0.1031); p *= p + 33.33; p *= p + p; return fract(p); }
float hash21(float2 p) { float3 p3 = fract(float3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float2 hash22(float2 p) { float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973)); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.xx + p3.yz) * p3.zy); }

float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
}

float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) { v += a * vnoise(p); p = p * 2.03 + 17.1; a *= 0.5; }
    return v;
}

float3 hueRotate(float3 c, float turns) {
    const float3 k = float3(0.57735);
    float a = turns * TAU;
    float ca = cos(a);
    return c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca);
}

float3 tri(float3 a, float3 b, float3 c, float t) {
    t = fract(t);
    return t < 0.5 ? mix(a, b, t * 2.0) : mix(b, c, (t - 0.5) * 2.0);
}

// Distance (in uv) to the nearest mask edge, approximated with a radial probe.
float maskEdge(texture2d<float> mask, sampler s, float2 uv, float radius) {
    float center = mask.sample(s, uv).r;
    float acc = 0.0;
    for (int i = 0; i < 12; i++) {
        float a = float(i) / 12.0 * TAU;
        acc += abs(mask.sample(s, uv + float2(cos(a), sin(a)) * radius).r - center);
    }
    return saturate(acc / 6.0);
}

// MARK: - Generators

fragment float4 generatorFragment(FullscreenOut in [[stage_in]],
                                  constant GeneratorUniforms &u [[buffer(0)]],
                                  texture2d<float> mask [[texture(0)]],
                                  texture2d<float> depth [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float2 p = (uv - 0.5) * float2(aspect, 1.0) / max(u.scale, 0.05);
    float t = u.time * u.speed + u.seed * 100.0;
    float3 A = u.colorA.rgb, B = u.colorB.rgb, C = u.colorC.rgb;
    float I = u.intensity;
    float3 col = C;

    switch (u.kind) {
    case 0: { // solid
        col = mix(A, B, 0.5 + 0.5 * sin(t * 0.5));
        break; }
    case 1: { // gradient
        float g = uv.y + 0.15 * sin(uv.x * 3.0 + t * 0.7);
        col = tri(A, B, C, g * 0.5 + t * 0.05);
        break; }
    case 2: { // plasma
        float v = sin(p.x * 3.0 + t) + sin(p.y * 4.0 - t * 1.3) + sin((p.x + p.y) * 3.0 + t * 0.7)
                + sin(length(p) * 6.0 - t * 1.7);
        col = tri(A, B, C, v * 0.125 + 0.5);
        break; }
    case 3: { // tunnel
        float r = length(p) + 1e-3;
        float a = atan2(p.y, p.x) / TAU;
        float z = 0.3 / r + t * 0.6;
        float rings = 0.5 + 0.5 * sin(z * TAU * 2.0);
        float spokes = 0.5 + 0.5 * sin(a * TAU * 6.0 + z * 2.0);
        col = mix(C, mix(A, B, spokes), rings) * smoothstep(0.0, 0.25, r) * (0.6 + u.audioBass * 1.5 * I);
        break; }
    case 4: { // neon rings
        float r = length(p);
        float pulse = u.audioBass * I;
        float w = abs(fract(r * 4.0 - t * 0.5) - 0.5);
        float glow = 0.02 / max(w, 0.005) * (0.6 + pulse);
        col = C + mix(A, B, fract(r * 2.0 - t * 0.25)) * glow * 0.4;
        break; }
    case 5: { // bars
        float x = uv.x * 8.0 * u.scale + t;
        float bar = step(0.5, fract(x));
        float idx = floor(x);
        float3 c = hash11(idx + floor(t * 2.0)) > 0.5 ? A : B;
        col = mix(C, c, bar) * (0.7 + 0.3 * I);
        break; }
    case 6: { // checker pulse
        float2 g = floor(p * 6.0);
        float chk = fmod(g.x + g.y, 2.0);
        float beat = 0.5 + 0.5 * sin(t * PI * 2.0);
        col = mix(A, B, abs(chk - step(0.5, beat)));
        col = mix(col, C, 0.25 * hash21(g + floor(t * 4.0)));
        break; }
    case 7: { // spectrum (bands from audio)
        float band = floor(uv.x * 24.0);
        float f = band / 24.0;
        float level = f < 0.33 ? u.audioBass : (f < 0.66 ? u.audioMid : u.audioHigh);
        level = saturate(level * I * (0.8 + 0.4 * hash11(band + floor(t * 8.0))) + 0.04);
        float h = 1.0 - uv.y;
        float lit = step(h, level) * step(0.12, fract(uv.x * 24.0));
        col = mix(C, mix(A, B, h), lit);
        break; }
    case 8: { // starfield
        float3 acc = C;
        for (int layer = 0; layer < 3; layer++) {
            float depthL = 1.0 + float(layer);
            float2 q = p * (8.0 * depthL) + float2(0, t * (0.3 * depthL));
            float2 id = floor(q), f = fract(q) - 0.5;
            float2 o = hash22(id) - 0.5;
            float d = length(f - o * 0.7);
            float tw = 0.6 + 0.4 * sin(t * 3.0 + hash21(id) * 20.0);
            acc += mix(A, B, hash21(id + 3.0)) * smoothstep(0.08 / depthL, 0.0, d) * tw * step(0.6, hash21(id + 7.0));
        }
        col = acc;
        break; }
    case 9: { // noise flow
        float2 q = float2(fbm(p * 1.5 + t * 0.1), fbm(p * 1.5 - t * 0.12 + 4.0));
        float n = fbm(p * 2.0 + q * 2.5 + t * 0.05);
        col = tri(C, A, B, n * 1.2);
        break; }
    case 10: { // edge glow (shape aware)
        float e = u.hasMask > 0.5 ? maskEdge(mask, s, uv, 0.01 + 0.01 * u.scale) :
                  1.0 - smoothstep(0.0, 0.03, min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
        float travel = 0.5 + 0.5 * sin(atan2(p.y, p.x) * 3.0 - t * 2.0);
        col = C + mix(A, B, travel) * e * (1.5 + u.audioLevel * 2.0 * I);
        break; }
    case 11: { // scan sweep (shape aware)
        float pos = fract(t * 0.25);
        float d = abs(uv.y - pos);
        float line = smoothstep(0.02, 0.0, d) + 0.3 * smoothstep(0.15, 0.0, d) * step(uv.y, pos);
        float m = u.hasMask > 0.5 ? mask.sample(s, uv).r : 1.0;
        float e = u.hasMask > 0.5 ? maskEdge(mask, s, uv, 0.008) : 0.0;
        col = C + (A * line + B * e * 0.8) * m * I;
        break; }
    case 12: { // kaleido noise
        float r = length(p), a = atan2(p.y, p.x);
        float seg = TAU / 8.0;
        a = abs(fmod(a + TAU, seg) - seg * 0.5);
        float2 q = float2(cos(a), sin(a)) * r;
        float n = fbm(q * 3.0 + t * 0.2);
        col = tri(A, B, C, n + r * 0.5 - t * 0.05);
        break; }
    case 13: { // fire
        float2 q = float2(p.x * 2.0, uv.y * 2.0);
        float n = fbm(float2(q.x, q.y + t * 1.5)) ;
        float heat = saturate((uv.y * 1.3 - 0.2) + n * 0.6 - 0.25) * (0.8 + 0.4 * I);
        heat *= 0.85 + 0.15 * sin(t * 13.0 + hash11(floor(t * 6.0)) * 5.0);
        col = heat < 0.5 ? mix(C, B, heat * 2.0) : mix(B, A, (heat - 0.5) * 2.0);
        break; }
    case 14: { // snowfall
        float3 acc = C;
        for (int layer = 0; layer < 4; layer++) {
            float sz = 6.0 + float(layer) * 5.0;
            float2 q = uv * float2(aspect, 1.0) * sz;
            q.y -= t * (0.6 + float(layer) * 0.25);
            q.x += sin(q.y * 0.5 + float(layer)) * 0.4;
            float2 id = floor(q), f = fract(q) - 0.5;
            float2 o = (hash22(id) - 0.5) * 0.6;
            float d = length(f - o);
            float flake = smoothstep(0.12 - float(layer) * 0.02, 0.0, d) * step(0.35, hash21(id));
            acc = mix(acc, mix(A, B, float(layer) / 4.0), flake * (1.0 - float(layer) * 0.15));
        }
        col = acc;
        break; }
    case 15: { // twinkle lights
        float2 q = p * 7.0;
        float2 id = floor(q), f = fract(q) - 0.5;
        float2 o = (hash22(id) - 0.5) * 0.5;
        float d = length(f - o);
        float phase = hash21(id) * TAU;
        float tw = 0.4 + 0.6 * pow(0.5 + 0.5 * sin(t * 2.0 + phase), 3.0);
        float3 c = hash21(id + 9.0) > 0.5 ? A : B;
        col = C + c * (smoothstep(0.12, 0.0, d) + 0.02 / max(d, 0.02) * 0.5) * tw * I;
        break; }
    case 16: { // lightning
        float flashSeed = floor(t * 1.7);
        float local = fract(t * 1.7);
        float strike = step(0.82, hash11(flashSeed));
        float flash = strike * exp(-local * 9.0) * (0.6 + 0.4 * step(0.5, fract(local * 7.0)));
        float x0 = hash11(flashSeed + 2.0) - 0.5;
        float bolt = 0.0;
        float y = uv.y;
        float xb = x0 + (fbm(float2(y * 6.0, flashSeed)) - 0.5) * 0.35;
        bolt = smoothstep(0.012, 0.0, abs(p.x - xb * aspect)) * strike * step(local, 0.25);
        col = C + B * flash * 0.8 + A * bolt * 2.0;
        break; }
    case 17: { // fog
        float n = fbm(p * 1.4 + float2(t * 0.15, 0)) * 0.6 + fbm(p * 3.0 - float2(t * 0.08, t * 0.03)) * 0.4;
        float low = smoothstep(0.0, 1.0, uv.y);
        col = mix(C, mix(B, A, n), saturate(n * 1.4 * low * I));
        break; }
    case 18: { // candy stripes
        float s1 = fract((p.x + p.y) * 4.0 * u.scale - t * 0.3);
        col = mix(A, B, step(0.5, s1));
        col *= 0.85 + 0.15 * smoothstep(0.0, 0.1, abs(s1 - 0.5));
        break; }
    case 19: { // hex grid
        float2 q = p * 6.0;
        float2 r2 = float2(1.0, 1.7320508);
        float2 h = r2 * 0.5;
        float2 a = fmod(q + 1000.0, r2) - h;
        float2 b = fmod(q - h + 1000.0, r2) - h;
        float2 g = dot(a, a) < dot(b, b) ? a : b;
        float2 id = q - g;
        float edge = 0.5 - max(abs(g.x) * 0.866 + abs(g.y) * 0.5, abs(g.y));
        float pulse = 0.5 + 0.5 * sin(length(id) * 0.8 - t * 2.0);
        col = C + mix(A, B, pulse) * smoothstep(0.06, 0.0, edge) * (0.5 + pulse * I);
        break; }
    case 20: { // depth contours
        float d = u.hasDepth > 0.5 ? depth.sample(s, uv).r : (1.0 - length(uv - 0.5) * 1.6);
        float lines = smoothstep(0.08, 0.0, abs(fract(d * 12.0 * u.scale - t * 0.3) - 0.5) - 0.42);
        col = mix(C, mix(B, A, d), lines * I) + A * d * 0.1;
        break; }
    case 21: { // depth scan
        float d = u.hasDepth > 0.5 ? depth.sample(s, uv).r : uv.y;
        float front = fract(t * 0.3);
        float band = smoothstep(0.06, 0.0, abs(d - front));
        float trail = smoothstep(0.3, 0.0, front - d) * step(d, front);
        col = C + A * band * 1.5 + B * trail * 0.4 * I;
        break; }
    case 22: { // strobe
        float rate = 4.0 * u.speed;
        float on = step(0.5, fract(u.time * rate));
        float audioHit = step(0.6, u.audioLevel * I);
        col = mix(B, A, max(on * step(u.audioLevel, 0.001), audioHit));
        break; }
    case 23: { // ripple
        float r = length(p);
        float w = sin(r * 20.0 * u.scale - t * 4.0) * exp(-r * 1.5);
        float2 off = normalize(p + 1e-4) * w * 0.03;
        float n = fbm((p + off) * 3.0 + t * 0.1);
        col = tri(C, A, B, n + w * 0.3);
        break; }
    case 24: { // blinking eyes
        float2 q = p * 3.0 / max(u.scale, 0.1);
        float2 id = floor(q), f = fract(q) - 0.5;
        float present = step(0.55, hash21(id));
        float blinkT = fract(t * 0.2 + hash21(id + 4.0));
        float open = smoothstep(0.0, 0.03, abs(blinkT - 0.5));
        float2 off = (hash22(id) - 0.5) * 0.3;
        float3 eyes = float3(0);
        for (int k = -1; k <= 1; k += 2) {
            float2 e = f - off - float2(0.12 * float(k), 0.0);
            e.y /= max(open, 0.05) * 0.5 + 0.02;
            float d = length(e * float2(1.0, 2.0));
            float pupil = smoothstep(0.03, 0.0, abs(e.x - sin(t * 0.7 + id.x) * 0.03));
            eyes += mix(A, B, d * 6.0) * smoothstep(0.09, 0.07, d) * (1.0 - pupil * 0.9);
        }
        col = C + eyes * present * I;
        break; }
    case 25: { // brick outline
        float2 q = uv * float2(6.0, 12.0) * u.scale;
        q.x += step(1.0, fmod(floor(q.y), 2.0)) * 0.5;
        float2 f = fract(q);
        float mortar = min(min(f.x, 1.0 - f.x) * 2.0, min(f.y, 1.0 - f.y));
        float line = smoothstep(0.05, 0.0, mortar);
        float wave = 0.5 + 0.5 * sin(floor(q.x) * 0.7 + floor(q.y) * 1.3 - t * 2.0);
        col = C + mix(A, B, wave) * line * (0.6 + 0.6 * I);
        break; }
    default:
        col = A;
    }

    return float4(saturate(col), 1.0);
}

// MARK: - Layer processing (crop / fit / effects)

float2 rotate2(float2 v, float a) { float c = cos(a), s = sin(a); return float2(v.x * c - v.y * s, v.x * s + v.y * c); }

fragment float4 layerFragment(FullscreenOut in [[stage_in]],
                              constant LayerUniforms &u [[buffer(0)]],
                              texture2d<float> src [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::repeat);
    float2 uv = in.uv;
    float dstAspect = u.dstSize.x / max(u.dstSize.y, 1.0);

    // Geometric effects operate in centred, aspect-corrected space.
    float2 p = (uv - 0.5) * float2(dstAspect, 1.0);
    if (u.zoom > 0.0) p /= u.zoom;
    p = rotate2(p, u.rotate * u.time * TAU * 0.25);
    if (u.kaleido >= 2.0) {
        float r = length(p), a = atan2(p.y, p.x);
        float seg = TAU / floor(u.kaleido);
        a = abs(fmod(a + TAU * 4.0, seg) - seg * 0.5);
        p = float2(cos(a), sin(a)) * r;
    }
    uv = p / float2(dstAspect, 1.0) + 0.5;
    uv += float2(u.slideX, u.slideY) * u.time * 0.1;
    if (u.tile > 1.0) uv = fract(uv * floor(u.tile));
    else uv = fract(uv);

    // Fit the (cropped) source into the destination.
    float2 cropSize = u.crop.zw;
    float srcAspect = (u.srcSize.x * cropSize.x) / max(u.srcSize.y * cropSize.y, 1.0);
    float2 fitUV = uv;
    float inside = 1.0;
    if (u.fit == 0) { // fill (cover)
        if (srcAspect > dstAspect) fitUV.x = (uv.x - 0.5) * dstAspect / srcAspect + 0.5;
        else fitUV.y = (uv.y - 0.5) * srcAspect / dstAspect + 0.5;
    } else if (u.fit == 1) { // fit (contain)
        if (srcAspect > dstAspect) fitUV.y = (uv.y - 0.5) * srcAspect / dstAspect + 0.5;
        else fitUV.x = (uv.x - 0.5) * dstAspect / srcAspect + 0.5;
        inside = step(0.0, fitUV.x) * step(fitUV.x, 1.0) * step(0.0, fitUV.y) * step(fitUV.y, 1.0);
    }
    float2 suv = u.crop.xy + saturate(fitUV) * cropSize;

    float4 c;
    if (u.blur > 0.001) {
        float2 texel = 1.0 / max(u.srcSize, float2(1.0));
        float radius = u.blur * 24.0;
        c = float4(0);
        float wsum = 0.0;
        for (int i = -3; i <= 3; i++) {
            for (int j = -3; j <= 3; j++) {
                float w = exp(-float(i * i + j * j) / 8.0);
                c += src.sample(s, suv + float2(i, j) * texel * radius / 3.0) * w;
                wsum += w;
            }
        }
        c /= wsum;
    } else {
        c = src.sample(s, suv);
    }

    float3 rgb = c.rgb;
    if (u.hueShift > 0.0) rgb = hueRotate(rgb, u.hueShift * u.time);
    if (u.mono > 0.0) rgb = mix(rgb, float3(dot(rgb, float3(0.299, 0.587, 0.114))), saturate(u.mono));
    if (u.invert > 0.0) rgb = mix(rgb, 1.0 - rgb, saturate(u.invert));

    float a = c.a * inside * saturate(u.opacity);
    return float4(rgb * a, a); // premultiplied
}

// MARK: - Surfaces

struct SurfaceVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex SurfaceVertexOut surfaceVertex(const device float4 *verts [[buffer(0)]], uint vid [[vertex_id]]) {
    float4 v = verts[vid]; // xy = output position (0..1, y down), zw = uv
    SurfaceVertexOut out;
    out.position = float4(v.x * 2.0 - 1.0, 1.0 - v.y * 2.0, 0, 1);
    out.uv = v.zw;
    return out;
}

fragment float4 surfaceFragment(SurfaceVertexOut in [[stage_in]],
                                constant SurfaceUniforms &u [[buffer(0)]],
                                texture2d<float> content [[texture(0)]],
                                texture2d<float> mask [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = content.sample(s, in.uv);
    float m = u.hasMask > 0.5 ? mask.sample(s, in.uv).r : 1.0;
    if (u.feather > 0.0) {
        float e = min(min(in.uv.x, 1.0 - in.uv.x), min(in.uv.y, 1.0 - in.uv.y));
        m *= smoothstep(0.0, u.feather, e);
    }
    float a = m * u.opacity;
    return float4(c.rgb * u.tint.rgb, c.a) * a; // content is premultiplied
}

// MARK: - Overlays and transitions

struct LineOut {
    float4 position [[position]];
};

vertex LineOut lineVertex(const device float2 *pts [[buffer(0)]], uint vid [[vertex_id]]) {
    float2 v = pts[vid];
    LineOut out;
    out.position = float4(v.x * 2.0 - 1.0, 1.0 - v.y * 2.0, 0, 1);
    return out;
}

fragment float4 lineFragment(constant float4 &color [[buffer(0)]]) { return color; }

fragment float4 transitionFragment(FullscreenOut in [[stage_in]],
                                   constant TransitionUniforms &u [[buffer(0)]],
                                   texture2d<float> from [[texture(0)]],
                                   texture2d<float> to [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 a = from.sample(s, in.uv);
    float4 b = to.sample(s, in.uv);
    float t = saturate(u.progress);
    if (u.style == 2) { // dissolve: noisy threshold with a soft edge
        float n = fbm(in.uv * 12.0);
        float k = smoothstep(n - 0.08, n + 0.08, t * 1.16 - 0.08);
        return mix(a, b, k);
    }
    return mix(a, b, t);
}

fragment float4 blitFragment(FullscreenOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}
