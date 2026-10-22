// Texture providers for the renderer: imported photos and videos, the live camera,
// animated hand drawings, plus surface masks (shapes, silhouettes, cutouts) and depth maps.

import { assetURL, imageAsset } from './storage.js';

export class Media {
  constructor() {
    this.gl = null;
    this.entries = new Map(); // layer/asset key -> { tex, w, h, el?, used, ... }
    this.masks = new Map(); // surfaceId -> { key, tex }
    this.camera = new Camera();
  }

  attach(gl) { this.gl = gl; }

  tex() {
    const gl = this.gl, t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return t;
  }

  upload(tex, el) {
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, el);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
  }

  entry(key, make) {
    let e = this.entries.get(key);
    if (!e) { e = make(); this.entries.set(key, e); }
    e.used = performance.now();
    return e;
  }

  // MARK: Layer sources

  source(layer, ctx) {
    const src = layer.source;
    switch (src.type) {
      case 'photo': return this.imageTexture('img:' + src.assetId, src.assetId);
      case 'video': return this.videoTexture(layer.id, src.assetId);
      case 'camera': {
        const v = this.camera.video(src.facing || 'environment');
        if (!v || v.readyState < 2 || !v.videoWidth) return null;
        const e = this.entry('cam', () => ({ tex: this.tex() }));
        if (e.frame !== ctx.frame) { this.upload(e.tex, v); e.frame = ctx.frame; }
        return { tex: e.tex, w: v.videoWidth, h: v.videoHeight };
      }
      case 'drawing': {
        const e = this.entry('draw:' + layer.id, () => {
          const c = document.createElement('canvas');
          c.width = c.height = DRAWING_SIZE;
          return { tex: this.tex(), canvas: c };
        });
        const g = e.canvas.getContext('2d');
        g.clearRect(0, 0, DRAWING_SIZE, DRAWING_SIZE);
        drawStrokes(g, src.drawing, ctx.time, DRAWING_SIZE);
        this.upload(e.tex, e.canvas);
        return { tex: e.tex, w: DRAWING_SIZE, h: DRAWING_SIZE };
      }
      default: return null;
    }
  }

  imageTexture(key, assetId) {
    const e = this.entries.get(key);
    if (e?.ready) { e.used = performance.now(); return e; }
    const img = imageAsset(assetId);
    if (!img) return null;
    const ent = { tex: this.tex(), w: img.naturalWidth, h: img.naturalHeight, ready: true, used: performance.now() };
    this.upload(ent.tex, img);
    this.entries.set(key, ent);
    return ent;
  }

  videoTexture(layerId, assetId) {
    const e = this.entry('vid:' + layerId, () => {
      const v = document.createElement('video');
      Object.assign(v, { muted: true, loop: true, playsInline: true, autoplay: true, crossOrigin: 'anonymous' });
      v.setAttribute('playsinline', '');
      assetURL(assetId).then((url) => { if (url) { v.src = url; v.play().catch(() => {}); } });
      return { tex: this.tex(), el: v, uploaded: -1 };
    });
    const v = e.el;
    if (v.readyState < 2 || !v.videoWidth) return null;
    if (v.paused) v.play().catch(() => {});
    if (v.currentTime !== e.uploaded) { this.upload(e.tex, v); e.uploaded = v.currentTime; }
    return { tex: e.tex, w: v.videoWidth, h: v.videoHeight };
  }

  restartVideos() {
    for (const [k, e] of this.entries) if (k.startsWith('vid:')) { e.el.currentTime = 0; e.el.play().catch(() => {}); }
  }

  /** Free textures and stop videos for layers that haven't been drawn for a while. */
  purge() {
    const cutoff = performance.now() - 5000;
    for (const [k, e] of this.entries) {
      if (e.used < cutoff) {
        if (e.el) { e.el.pause(); e.el.removeAttribute('src'); e.el.load(); }
        this.gl.deleteTexture(e.tex);
        this.entries.delete(k);
      }
    }
    if (!this.entries.has('cam')) this.camera.releaseIfIdle();
  }

  // MARK: Masks & depth

  mask(surface, w, h) {
    const shape = surface.shape;
    if ((shape.type === 'quad' || shape.type === 'box') && !surface.cutouts.length) return null;
    const key = JSON.stringify([shape, surface.cutouts, w, h]);
    const cached = this.masks.get(surface.id);
    if (cached?.key === key) return cached.tex;

    const c = document.createElement('canvas');
    c.width = w; c.height = h;
    const g = c.getContext('2d');
    g.fillStyle = '#000';
    g.fillRect(0, 0, w, h);
    g.fillStyle = '#fff';
    let complete = true;
    switch (shape.type) {
      case 'circle': g.beginPath(); g.ellipse(w / 2, h / 2, w / 2, h / 2, 0, 0, Math.PI * 2); g.fill(); break;
      case 'freehand': fillPoly(g, shape.points, w, h); break;
      case 'text': fitText(g, shape.text, shape.font, w, h); break;
      case 'silhouette': case 'depth': {
        const img = imageAsset(shape.maskId);
        if (img) g.drawImage(img, 0, 0, w, h); else complete = false;
        break;
      }
      default: g.fillRect(0, 0, w, h);
    }
    g.fillStyle = '#000';
    for (const cut of surface.cutouts) fillPoly(g, cut, w, h);

    const tex = cached?.tex || this.tex();
    this.upload(tex, c);
    // Images still loading: keep the (blank) mask but re-rasterise next frame.
    this.masks.set(surface.id, { key: complete ? key : null, tex });
    return tex;
  }

  depth(surface) {
    if (surface.shape.type !== 'depth') return null;
    return this.imageTexture('depth:' + surface.shape.depthId, surface.shape.depthId)?.tex || null;
  }
}

function fillPoly(g, pts, w, h) {
  if (pts.length < 3) return;
  g.beginPath();
  g.moveTo(pts[0][0] * w, pts[0][1] * h);
  for (const p of pts.slice(1)) g.lineTo(p[0] * w, p[1] * h);
  g.closePath();
  g.fill();
}

function fitText(g, text, font = 'Impact, "Arial Black", sans-serif', w, h) {
  const lines = String(text).split('\n');
  let size = h / lines.length;
  g.textAlign = 'center';
  g.textBaseline = 'middle';
  // Shrink until the widest line fits.
  for (; size > 6; size *= 0.92) {
    g.font = `900 ${size}px ${font}`;
    if (Math.max(...lines.map((l) => g.measureText(l).width)) <= w * 0.98) break;
  }
  lines.forEach((l, i) => g.fillText(l, w / 2, h / 2 + (i - (lines.length - 1) / 2) * size));
}

// MARK: Drawings

export const DRAWING_SIZE = 768;

/** Draw an animated drawing. Strokes are in unit space (0..1); widths in DRAWING_SIZE pixels. */
export function drawStrokes(g, drawing, time, size) {
  const k = size / DRAWING_SIZE;
  const phase = drawing.period > 0 ? (time / drawing.period) % 1 : 1;
  const len = (pts) => pts.slice(1).reduce((s, p, i) => s + Math.hypot(p[0] - pts[i][0], p[1] - pts[i][1]), 0);
  const total = drawing.strokes.reduce((s, st) => s + len(st.points), 0);
  // Trace-on: draw over 70% of the cycle, hold, then restart.
  let remaining = drawing.animation === 'traceOn' ? total * Math.min(1, phase / 0.7) : Infinity;
  g.lineCap = 'round';
  g.lineJoin = 'round';
  drawing.strokes.forEach((st, i) => {
    if (st.points.length < 2 || remaining <= 0) return;
    let color = st.color, width = st.width * k;
    if (drawing.animation === 'pulse') width *= 1 + 0.5 * Math.sin(phase * Math.PI * 2 + i);
    if (drawing.animation === 'hueCycle') color = `hsl(${(hueOf(st.color) + phase * 360) % 360} 100% 60%)`;
    if (drawing.animation === 'flicker' && Math.sin(time * 37 + i * 11) * Math.sin(time * 23) > 0.85) color = 'rgba(0,0,0,0)';
    g.beginPath();
    g.moveTo(st.points[0][0] * size, st.points[0][1] * size);
    for (let j = 1; j < st.points.length && remaining > 0; j++) {
      const a = st.points[j - 1], b = st.points[j], seg = Math.hypot(b[0] - a[0], b[1] - a[1]);
      if (seg > remaining) {
        const f = remaining / seg;
        g.lineTo((a[0] + (b[0] - a[0]) * f) * size, (a[1] + (b[1] - a[1]) * f) * size);
        remaining = 0;
      } else {
        g.lineTo(b[0] * size, b[1] * size);
        remaining -= seg;
      }
    }
    g.strokeStyle = color;
    g.lineWidth = width;
    g.shadowColor = color;
    g.shadowBlur = (st.glow ?? 0.5) * 30 * k;
    g.stroke();
    g.shadowBlur = 0;
    g.stroke();
  });
}

function hueOf(hex) {
  const n = parseInt(hex.slice(1), 16), r = (n >> 16) / 255, gg = ((n >> 8) & 255) / 255, b = (n & 255) / 255;
  const max = Math.max(r, gg, b), min = Math.min(r, gg, b), d = max - min;
  if (!d) return 0;
  const h = max === r ? ((gg - b) / d) % 6 : max === gg ? (b - r) / d + 2 : (r - gg) / d + 4;
  return (h * 60 + 360) % 360;
}

// MARK: Camera (shared by camera layers and hand/face tracking)

export class Camera {
  constructor() { this.streams = {}; this.lastUse = 0; this.keep = false; }

  /** Returns a playing <video> for the camera, starting it on first use. */
  video(facing = 'environment') {
    this.lastUse = performance.now();
    let s = this.streams[facing];
    if (!s) {
      const v = document.createElement('video');
      Object.assign(v, { muted: true, playsInline: true, autoplay: true });
      v.setAttribute('playsinline', '');
      s = this.streams[facing] = { video: v, stream: null, error: null };
      navigator.mediaDevices?.getUserMedia({ video: { facingMode: facing, width: { ideal: 1280 }, height: { ideal: 720 } }, audio: false })
        .then((stream) => { s.stream = stream; v.srcObject = stream; v.play().catch(() => {}); })
        .catch((e) => { s.error = e; });
    }
    return s.video;
  }

  releaseIfIdle() {
    if (this.keep || performance.now() - this.lastUse < 3000) return;
    for (const [k, s] of Object.entries(this.streams)) {
      s.stream?.getTracks().forEach((t) => t.stop());
      delete this.streams[k];
    }
  }
}
