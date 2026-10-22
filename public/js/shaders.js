// WebGL2 shaders.
//
// Convention: every texture is addressed with uv where v = 0 is the TOP row. Images and
// video uploaded from the DOM already land that way; for offscreen framebuffers we flip
// clip-space y (uYSign = -1) so they match. Drawing to the screen uses uYSign = 1.

export const FULLSCREEN_VS = `#version 300 es
uniform float uYSign;
out vec2 vUV;
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)) * 2.0 - 1.0;
  gl_Position = vec4(p, 0.0, 1.0);
  vUV = vec2(p.x * 0.5 + 0.5, (1.0 - uYSign * p.y) * 0.5);
}`;

const COMMON = `
precision highp float;
const float PI = 3.14159265;
const float TAU = 6.2831853;
float hash11(float p) { p = fract(p * 0.1031); p *= p + 33.33; p *= p + p; return fract(p); }
float hash21(vec2 p) { vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
vec2 hash22(vec2 p) { vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973)); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.xx + p3.yz) * p3.zy); }
float vnoise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash21(i), hash21(i + vec2(1, 0)), u.x), mix(hash21(i + vec2(0, 1)), hash21(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {
  float v = 0.0, a = 0.5;
  for (int i = 0; i < 5; i++) { v += a * vnoise(p); p = p * 2.03 + 17.1; a *= 0.5; }
  return v;
}
vec3 hueRotate(vec3 c, float turns) {
  const vec3 k = vec3(0.57735);
  float a = turns * TAU, ca = cos(a);
  return c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca);
}
`;

export const GENERATOR_FS = `#version 300 es
${COMMON}
in vec2 vUV;
out vec4 outColor;
uniform vec3 uA, uB, uC;
uniform vec2 uRes;
uniform float uTime, uSpeed, uScale, uIntensity, uLevel, uBass, uMid, uHigh, uSeed, uHasMask, uHasDepth;
uniform int uKind;
uniform sampler2D uMask, uDepth;

vec3 tri(vec3 a, vec3 b, vec3 c, float t) {
  t = fract(t);
  return t < 0.5 ? mix(a, b, t * 2.0) : mix(b, c, (t - 0.5) * 2.0);
}

// Approximate "near an edge of the mask" with a radial probe.
float maskEdge(vec2 uv, float radius) {
  float center = texture(uMask, uv).r, acc = 0.0;
  for (int i = 0; i < 12; i++) {
    float a = float(i) / 12.0 * TAU;
    acc += abs(texture(uMask, uv + vec2(cos(a), sin(a)) * radius).r - center);
  }
  return clamp(acc / 6.0, 0.0, 1.0);
}

void main() {
  vec2 uv = vUV;
  float aspect = uRes.x / max(uRes.y, 1.0);
  vec2 p = (uv - 0.5) * vec2(aspect, 1.0) / max(uScale, 0.05);
  float t = uTime * uSpeed + uSeed * 100.0;
  vec3 A = uA, B = uB, C = uC, col = C;
  float I = uIntensity;

  if (uKind == 0) { // solid
    col = mix(A, B, 0.5 + 0.5 * sin(t * 0.5));
  } else if (uKind == 1) { // gradient
    col = tri(A, B, C, (uv.y + 0.15 * sin(uv.x * 3.0 + t * 0.7)) * 0.5 + t * 0.05);
  } else if (uKind == 2) { // plasma
    float v = sin(p.x * 3.0 + t) + sin(p.y * 4.0 - t * 1.3) + sin((p.x + p.y) * 3.0 + t * 0.7) + sin(length(p) * 6.0 - t * 1.7);
    col = tri(A, B, C, v * 0.125 + 0.5);
  } else if (uKind == 3) { // tunnel
    float r = length(p) + 1e-3, a = atan(p.y, p.x) / TAU, z = 0.3 / r + t * 0.6;
    float rings = 0.5 + 0.5 * sin(z * TAU * 2.0), spokes = 0.5 + 0.5 * sin(a * TAU * 6.0 + z * 2.0);
    col = mix(C, mix(A, B, spokes), rings) * smoothstep(0.0, 0.25, r) * (0.6 + uBass * 1.5 * I);
  } else if (uKind == 4) { // neon rings
    float r = length(p), w = abs(fract(r * 4.0 - t * 0.5) - 0.5);
    float glow = 0.02 / max(w, 0.005) * (0.6 + uBass * I);
    col = C + mix(A, B, fract(r * 2.0 - t * 0.25)) * glow * 0.4;
  } else if (uKind == 5) { // VJ bars
    float x = uv.x * 8.0 * uScale + t;
    vec3 c = hash11(floor(x) + floor(t * 2.0)) > 0.5 ? A : B;
    col = mix(C, c, step(0.5, fract(x))) * (0.7 + 0.3 * I);
  } else if (uKind == 6) { // checker pulse
    vec2 g = floor(p * 6.0);
    float chk = mod(g.x + g.y, 2.0), beat = 0.5 + 0.5 * sin(t * TAU);
    col = mix(mix(A, B, abs(chk - step(0.5, beat))), C, 0.25 * hash21(g + floor(t * 4.0)));
  } else if (uKind == 7) { // spectrum
    float band = floor(uv.x * 24.0), f = band / 24.0;
    float level = f < 0.33 ? uBass : (f < 0.66 ? uMid : uHigh);
    level = clamp(level * I * (0.8 + 0.4 * hash11(band + floor(t * 8.0))) + 0.04, 0.0, 1.0);
    float h = 1.0 - uv.y;
    col = mix(C, mix(A, B, h), step(h, level) * step(0.12, fract(uv.x * 24.0)));
  } else if (uKind == 8) { // starfield
    vec3 acc = C;
    for (int l = 0; l < 3; l++) {
      float d = 1.0 + float(l);
      vec2 q = p * (8.0 * d) + vec2(0.0, t * 0.3 * d);
      vec2 id = floor(q), f = fract(q) - 0.5;
      float dist = length(f - (hash22(id) - 0.5) * 0.7);
      float tw = 0.6 + 0.4 * sin(t * 3.0 + hash21(id) * 20.0);
      acc += mix(A, B, hash21(id + 3.0)) * smoothstep(0.08 / d, 0.0, dist) * tw * step(0.6, hash21(id + 7.0));
    }
    col = acc;
  } else if (uKind == 9) { // noise flow
    vec2 q = vec2(fbm(p * 1.5 + t * 0.1), fbm(p * 1.5 - t * 0.12 + 4.0));
    col = tri(C, A, B, fbm(p * 2.0 + q * 2.5 + t * 0.05) * 1.2);
  } else if (uKind == 10) { // edge glow (shape aware)
    float e = uHasMask > 0.5 ? maskEdge(uv, 0.01 + 0.01 * uScale)
      : 1.0 - smoothstep(0.0, 0.03, min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
    float travel = 0.5 + 0.5 * sin(atan(p.y, p.x) * 3.0 - t * 2.0);
    col = C + mix(A, B, travel) * e * (1.5 + uLevel * 2.0 * I);
  } else if (uKind == 11) { // scan sweep (shape aware)
    float pos = fract(t * 0.25), d = abs(uv.y - pos);
    float line = smoothstep(0.02, 0.0, d) + 0.3 * smoothstep(0.15, 0.0, d) * step(uv.y, pos);
    float m = uHasMask > 0.5 ? texture(uMask, uv).r : 1.0;
    float e = uHasMask > 0.5 ? maskEdge(uv, 0.008) : 0.0;
    col = C + (A * line + B * e * 0.8) * m * I;
  } else if (uKind == 12) { // kaleido noise
    float r = length(p), a = atan(p.y, p.x), seg = TAU / 8.0;
    a = abs(mod(a + TAU, seg) - seg * 0.5);
    col = tri(A, B, C, fbm(vec2(cos(a), sin(a)) * r * 3.0 + t * 0.2) + r * 0.5 - t * 0.05);
  } else if (uKind == 13) { // fire (flames rise from the bottom)
    float n = fbm(vec2(p.x * 2.0, uv.y * 2.0 + t * 1.5));
    float heat = clamp((uv.y * 1.3 - 0.2) + n * 0.6 - 0.25, 0.0, 1.0) * (0.8 + 0.4 * I);
    heat *= 0.85 + 0.15 * sin(t * 13.0 + hash11(floor(t * 6.0)) * 5.0);
    col = heat < 0.5 ? mix(C, B, heat * 2.0) : mix(B, A, (heat - 0.5) * 2.0);
  } else if (uKind == 14) { // snowfall
    vec3 acc = C;
    for (int l = 0; l < 4; l++) {
      float fl = float(l), sz = 6.0 + fl * 5.0;
      vec2 q = uv * vec2(aspect, 1.0) * sz;
      q.y -= t * (0.6 + fl * 0.25);
      q.x += sin(q.y * 0.5 + fl) * 0.4;
      vec2 id = floor(q), f = fract(q) - 0.5;
      float d = length(f - (hash22(id) - 0.5) * 0.6);
      float flake = smoothstep(0.12 - fl * 0.02, 0.0, d) * step(0.35, hash21(id));
      acc = mix(acc, mix(A, B, fl / 4.0), flake * (1.0 - fl * 0.15));
    }
    col = acc;
  } else if (uKind == 15) { // twinkle lights
    vec2 q = p * 7.0, id = floor(q), f = fract(q) - 0.5;
    float d = length(f - (hash22(id) - 0.5) * 0.5);
    float tw = 0.4 + 0.6 * pow(0.5 + 0.5 * sin(t * 2.0 + hash21(id) * TAU), 3.0);
    vec3 c = hash21(id + 9.0) > 0.5 ? A : B;
    col = C + c * (smoothstep(0.12, 0.0, d) + 0.01 / max(d, 0.02)) * tw * I;
  } else if (uKind == 16) { // lightning
    float seed = floor(t * 1.7), local = fract(t * 1.7);
    float strike = step(0.82, hash11(seed));
    float flash = strike * exp(-local * 9.0) * (0.6 + 0.4 * step(0.5, fract(local * 7.0)));
    float xb = hash11(seed + 2.0) - 0.5 + (fbm(vec2(uv.y * 6.0, seed)) - 0.5) * 0.35;
    float bolt = smoothstep(0.012, 0.0, abs(p.x - xb * aspect)) * strike * step(local, 0.25);
    col = C + B * flash * 0.8 + A * bolt * 2.0;
  } else if (uKind == 17) { // fog
    float n = fbm(p * 1.4 + vec2(t * 0.15, 0.0)) * 0.6 + fbm(p * 3.0 - vec2(t * 0.08, t * 0.03)) * 0.4;
    col = mix(C, mix(B, A, n), clamp(n * 1.4 * smoothstep(0.0, 1.0, uv.y) * I, 0.0, 1.0));
  } else if (uKind == 18) { // candy stripes
    float s = fract((p.x + p.y) * 4.0 * uScale - t * 0.3);
    col = mix(A, B, step(0.5, s)) * (0.85 + 0.15 * smoothstep(0.0, 0.1, abs(s - 0.5)));
  } else if (uKind == 19) { // hex grid
    vec2 q = p * 6.0, r2 = vec2(1.0, 1.7320508), h = r2 * 0.5;
    vec2 a = mod(q, r2) - h, b = mod(q - h, r2) - h;
    vec2 g = dot(a, a) < dot(b, b) ? a : b;
    vec2 id = q - g;
    float edge = 0.5 - max(abs(g.x) * 0.866 + abs(g.y) * 0.5, abs(g.y));
    float pulse = 0.5 + 0.5 * sin(length(id) * 0.8 - t * 2.0);
    col = C + mix(A, B, pulse) * smoothstep(0.06, 0.0, edge) * (0.5 + pulse * I);
  } else if (uKind == 20) { // depth contours
    float d = uHasDepth > 0.5 ? texture(uDepth, uv).r : 1.0 - length(uv - 0.5) * 1.6;
    float lines = smoothstep(0.08, 0.0, abs(fract(d * 12.0 * uScale - t * 0.3) - 0.5) - 0.42);
    col = mix(C, mix(B, A, d), lines * I) + A * d * 0.1;
  } else if (uKind == 21) { // depth scan
    float d = uHasDepth > 0.5 ? texture(uDepth, uv).r : 1.0 - uv.y;
    float front = fract(t * 0.3);
    col = C + A * smoothstep(0.06, 0.0, abs(d - front)) * 1.5 + B * smoothstep(0.3, 0.0, front - d) * step(d, front) * 0.4 * I;
  } else if (uKind == 22) { // strobe: free-running, or on audio hits when sound is present
    float on = step(0.5, fract(uTime * 4.0 * uSpeed));
    float hit = step(0.6, uLevel * I);
    col = mix(B, A, max(on * step(uLevel, 0.001), hit));
  } else if (uKind == 23) { // ripple
    float r = length(p), w = sin(r * 20.0 * uScale - t * 4.0) * exp(-r * 1.5);
    col = tri(C, A, B, fbm((p + normalize(p + 1e-4) * w * 0.03) * 3.0 + t * 0.1) + w * 0.3);
  } else if (uKind == 24) { // blinking eyes
    vec2 q = p * 3.0 / max(uScale, 0.1), id = floor(q), f = fract(q) - 0.5;
    float present = step(0.55, hash21(id));
    float open = smoothstep(0.0, 0.03, abs(fract(t * 0.2 + hash21(id + 4.0)) - 0.5));
    vec2 off = (hash22(id) - 0.5) * 0.3;
    vec3 eyes = vec3(0.0);
    for (int k = -1; k <= 1; k += 2) {
      vec2 e = f - off - vec2(0.12 * float(k), 0.0);
      e.y /= max(open, 0.05);
      float d = length(e * vec2(1.0, 1.6));
      float pupil = smoothstep(0.03, 0.0, abs(e.x - sin(t * 0.7 + id.x) * 0.03));
      eyes += mix(A, B, d * 6.0) * smoothstep(0.09, 0.07, d) * (1.0 - pupil * 0.9);
    }
    col = C + eyes * present * I;
  } else if (uKind == 25) { // brick outline
    vec2 q = uv * vec2(6.0, 12.0) * uScale;
    q.x += step(1.0, mod(floor(q.y), 2.0)) * 0.5;
    vec2 f = fract(q);
    float line = smoothstep(0.05, 0.0, min(min(f.x, 1.0 - f.x) * 2.0, min(f.y, 1.0 - f.y)));
    float wave = 0.5 + 0.5 * sin(floor(q.x) * 0.7 + floor(q.y) * 1.3 - t * 2.0);
    col = C + mix(A, B, wave) * line * (0.6 + 0.6 * I);
  }
  outColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}`;

export const LAYER_FS = `#version 300 es
${COMMON}
in vec2 vUV;
out vec4 outColor;
uniform sampler2D uSrc;
uniform vec4 uCrop;
uniform vec2 uSrcSize, uDstSize;
uniform float uKaleido, uTile, uSlide, uRotate, uZoom, uBlur, uMono, uInvert, uHue, uOpacity, uTime;
uniform int uFit;

vec2 rot(vec2 v, float a) { float c = cos(a), s = sin(a); return vec2(v.x * c - v.y * s, v.x * s + v.y * c); }

void main() {
  float dstAspect = uDstSize.x / max(uDstSize.y, 1.0);
  vec2 p = (vUV - 0.5) * vec2(dstAspect, 1.0);
  p /= max(uZoom, 0.01);
  p = rot(p, uRotate * uTime * TAU * 0.25);
  if (uKaleido >= 2.0) {
    float r = length(p), a = atan(p.y, p.x), seg = TAU / floor(uKaleido);
    a = abs(mod(a, seg) - seg * 0.5);
    p = vec2(cos(a), sin(a)) * r;
  }
  vec2 uv = p / vec2(dstAspect, 1.0) + 0.5;
  uv.x += uSlide * uTime * 0.1;
  uv = uTile > 1.0 ? fract(uv * floor(uTile)) : fract(uv);

  float srcAspect = (uSrcSize.x * uCrop.z) / max(uSrcSize.y * uCrop.w, 1.0);
  vec2 f = uv;
  float inside = 1.0;
  if (uFit == 0) { // fill (cover)
    if (srcAspect > dstAspect) f.x = (uv.x - 0.5) * dstAspect / srcAspect + 0.5;
    else f.y = (uv.y - 0.5) * srcAspect / dstAspect + 0.5;
  } else if (uFit == 1) { // fit (contain)
    if (srcAspect > dstAspect) f.y = (uv.y - 0.5) * srcAspect / dstAspect + 0.5;
    else f.x = (uv.x - 0.5) * dstAspect / srcAspect + 0.5;
    inside = step(0.0, f.x) * step(f.x, 1.0) * step(0.0, f.y) * step(f.y, 1.0);
  }
  vec2 suv = uCrop.xy + clamp(f, 0.0, 1.0) * uCrop.zw;

  vec4 c;
  if (uBlur > 0.001) {
    vec2 texel = 1.0 / max(uSrcSize, vec2(1.0));
    float radius = uBlur * 24.0, wsum = 0.0;
    c = vec4(0.0);
    for (int i = -3; i <= 3; i++) for (int j = -3; j <= 3; j++) {
      float w = exp(-float(i * i + j * j) / 8.0);
      c += texture(uSrc, suv + vec2(i, j) * texel * radius / 3.0) * w;
      wsum += w;
    }
    c /= wsum;
  } else {
    c = texture(uSrc, suv);
  }
  vec3 rgb = c.rgb;
  if (uHue > 0.0) rgb = hueRotate(rgb, uHue * uTime);
  if (uMono > 0.0) rgb = mix(rgb, vec3(dot(rgb, vec3(0.299, 0.587, 0.114))), clamp(uMono, 0.0, 1.0));
  if (uInvert > 0.0) rgb = mix(rgb, 1.0 - rgb, clamp(uInvert, 0.0, 1.0));
  float a = c.a * inside * clamp(uOpacity, 0.0, 1.0);
  outColor = vec4(rgb * a, a); // premultiplied
}`;

export const SURFACE_VS = `#version 300 es
in vec4 aPos; // xy = output position (0..1, y down), zw = surface uv
uniform float uYSign;
out vec2 vUV;
void main() {
  gl_Position = vec4(aPos.x * 2.0 - 1.0, (1.0 - aPos.y * 2.0) * uYSign, 0.0, 1.0);
  vUV = aPos.zw;
}`;

export const SURFACE_FS = `#version 300 es
precision highp float;
in vec2 vUV;
out vec4 outColor;
uniform sampler2D uContent, uMask;
uniform float uOpacity, uFeather, uHasMask;
void main() {
  vec4 c = texture(uContent, vUV);
  float m = uHasMask > 0.5 ? texture(uMask, vUV).r : 1.0;
  if (uFeather > 0.0) m *= smoothstep(0.0, uFeather, min(min(vUV.x, 1.0 - vUV.x), min(vUV.y, 1.0 - vUV.y)));
  outColor = c * (m * uOpacity);
}`;

export const LINE_VS = `#version 300 es
in vec2 aPos;
void main() { gl_Position = vec4(aPos.x * 2.0 - 1.0, 1.0 - aPos.y * 2.0, 0.0, 1.0); }`;

export const LINE_FS = `#version 300 es
precision highp float;
uniform vec4 uColor;
out vec4 outColor;
void main() { outColor = uColor; }`;

export const TRANSITION_FS = `#version 300 es
${COMMON}
in vec2 vUV;
out vec4 outColor;
uniform sampler2D uFrom, uTo;
uniform float uProgress;
uniform int uStyle;
void main() {
  vec4 a = texture(uFrom, vUV), b = texture(uTo, vUV);
  float t = clamp(uProgress, 0.0, 1.0);
  if (uStyle == 2) { // dissolve: noisy threshold with a soft edge
    float n = fbm(vUV * 12.0);
    t = smoothstep(n - 0.08, n + 0.08, t * 1.16 - 0.08);
  }
  outColor = mix(a, b, t);
}`;
