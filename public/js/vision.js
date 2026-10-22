// On-device vision, loaded only when first used:
//  - hand & face tracking as modulation sources (MediaPipe)
//  - photo -> silhouette mask (MediaPipe interactive segmenter: tap the object)
//  - photo -> depth map (Depth Anything via transformers.js, or an estimated relief)

const MP_VERSION = '0.10.14';
const MP = `https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@${MP_VERSION}`;
const MODELS = 'https://storage.googleapis.com/mediapipe-models';

let visionPromise;
function loadVision() {
  visionPromise ??= (async () => {
    const mod = await import(`${MP}/vision_bundle.mjs`);
    const files = await mod.FilesetResolver.forVisionTasks(`${MP}/wasm`);
    return { mod, files };
  })();
  return visionPromise;
}

async function create(Task, files, modelPath, extra = {}) {
  for (const delegate of ['GPU', 'CPU']) {
    try { return await Task.createFromOptions(files, { baseOptions: { modelAssetPath: modelPath, delegate }, ...extra }); }
    catch (e) { if (delegate === 'CPU') throw e; }
  }
}

// MARK: Tracking

export class Tracker {
  constructor(camera) {
    this.camera = camera;
    this.values = { handX: 0.5, handY: 0.5, pinch: 0, faceX: 0.5, faceY: 0.5, mouthOpen: 0 };
    this.enabled = false;
    this.status = 'off';
    this.lastRun = 0;
  }

  async enable() {
    this.enabled = true;
    this.camera.keep = true;
    if (this.hands) return;
    this.status = 'loading models…';
    try {
      const { mod, files } = await loadVision();
      [this.hands, this.face] = await Promise.all([
        create(mod.HandLandmarker, files, `${MODELS}/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task`, { runningMode: 'VIDEO', numHands: 1 }),
        create(mod.FaceLandmarker, files, `${MODELS}/face_landmarker/face_landmarker/float16/1/face_landmarker.task`, { runningMode: 'VIDEO', numFaces: 1, outputFaceBlendshapes: true }),
      ]);
      this.status = 'tracking';
    } catch (e) {
      this.status = 'unavailable: ' + e.message;
    }
  }

  disable() { this.enabled = false; this.camera.keep = false; this.status = 'off'; }

  /** Call every frame; runs detection ~15 times a second. */
  update(now) {
    if (!this.enabled || !this.hands || now - this.lastRun < 66) return this.values;
    const v = this.camera.video('user');
    if (v.readyState < 2) return this.values;
    this.lastRun = now;
    const s = (o, n) => o + (n - o) * 0.5;
    const t = this.values;
    // Front camera image is mirrored relative to the viewer, so flip x.
    const h = this.hands.detectForVideo(v, now).landmarks?.[0];
    if (h) {
      const tip = h[8], thumb = h[4];
      t.handX = s(t.handX, 1 - tip.x);
      t.handY = s(t.handY, tip.y);
      t.pinch = s(t.pinch, Math.max(0, Math.min(1, 1 - (Math.hypot(tip.x - thumb.x, tip.y - thumb.y) - 0.02) / 0.15)));
    }
    const f = this.face.detectForVideo(v, now);
    const lm = f.faceLandmarks?.[0];
    if (lm) {
      t.faceX = s(t.faceX, 1 - lm[1].x);
      t.faceY = s(t.faceY, lm[1].y);
      const jaw = f.faceBlendshapes?.[0]?.categories.find((c) => c.categoryName === 'jawOpen');
      if (jaw) t.mouthOpen = s(t.mouthOpen, jaw.score);
    }
    return t;
  }
}

// MARK: Shapes from photos

/**
 * Silhouette mask for the object at (x, y) (normalised) in the image.
 * Returns a canvas (white = object). Falls back to a background-colour key if the
 * segmentation model can't load (e.g. offline).
 */
export async function segmentAt(img, x, y) {
  try {
    const { mod, files } = await loadVision();
    const seg = await create(mod.InteractiveSegmenter, files, `${MODELS}/interactive_segmenter/magic_touch/float32/1/magic_touch.tflite`, { outputCategoryMask: true, outputConfidenceMasks: false });
    const result = await new Promise((resolve) => seg.segment(img, { keypoint: { x, y } }, (r) => {
      const m = r.categoryMask;
      resolve({ w: m.width, h: m.height, data: m.getAsUint8Array().slice() });
      m.close();
    }));
    seg.close();
    // Mask polarity varies by model version: whatever value sits under the tap is the object.
    const tapped = result.data[Math.min(result.h - 1, Math.floor(y * result.h)) * result.w + Math.min(result.w - 1, Math.floor(x * result.w))];
    return maskCanvas(result.w, result.h, (i) => (result.data[i] === tapped ? 255 : 0), img);
  } catch (e) {
    console.warn('Segmenter unavailable, using colour key', e);
    return colourKeyMask(img);
  }
}

function maskCanvas(w, h, valueAt, img) {
  const c = document.createElement('canvas');
  c.width = w; c.height = h;
  const g = c.getContext('2d');
  const d = g.createImageData(w, h);
  for (let i = 0; i < w * h; i++) {
    const v = valueAt(i);
    d.data.set([v, v, v, 255], i * 4);
  }
  g.putImageData(d, 0, 0);
  return resizeCanvas(c, img.naturalWidth || img.width, img.naturalHeight || img.height);
}

/** Pixels that differ from the average border colour are "object". */
function colourKeyMask(img) {
  const w = 256, h = Math.round(256 * (img.naturalHeight / img.naturalWidth));
  const c = resizeCanvas(img, w, h);
  const px = c.getContext('2d').getImageData(0, 0, w, h).data;
  let r = 0, g = 0, b = 0, n = 0;
  for (let x = 0; x < w; x++) for (const y of [0, h - 1]) { const i = (y * w + x) * 4; r += px[i]; g += px[i + 1]; b += px[i + 2]; n++; }
  for (let y = 0; y < h; y++) for (const x of [0, w - 1]) { const i = (y * w + x) * 4; r += px[i]; g += px[i + 1]; b += px[i + 2]; n++; }
  r /= n; g /= n; b /= n;
  return maskCanvas(w, h, (i) => (Math.hypot(px[i * 4] - r, px[i * 4 + 1] - g, px[i * 4 + 2] - b) > 60 ? 255 : 0), img);
}

function resizeCanvas(src, w, h) {
  const c = document.createElement('canvas');
  c.width = w; c.height = h;
  const g = c.getContext('2d');
  g.imageSmoothingQuality = 'high';
  g.drawImage(src, 0, 0, w, h);
  return c;
}

/**
 * Depth map (white = near) for a photo, masked to the silhouette.
 * Uses Depth Anything V2 (downloaded on first use) when `useAI`, otherwise a relief
 * estimated from the silhouette's distance to its edge.
 */
export async function estimateDepth(img, mask, useAI, onStatus = () => {}) {
  const w = mask.width, h = mask.height;
  let depth = null;
  if (useAI) {
    try {
      onStatus('Downloading depth model (first time only)…');
      const { pipeline } = await import('https://cdn.jsdelivr.net/npm/@huggingface/transformers@3.0.2');
      const estimator = await pipeline('depth-estimation', 'onnx-community/depth-anything-v2-small');
      onStatus('Estimating depth…');
      const out = await estimator(resizeCanvas(img, 518, Math.round(518 * h / w)).toDataURL('image/jpeg', 0.9));
      depth = resizeCanvas(out.depth.toCanvas(), w, h);
    } catch (e) {
      console.warn('AI depth unavailable, estimating relief', e);
    }
  }
  depth ??= reliefFromMask(mask);
  return multiplyByMask(normalise(depth), mask);
}

/**
 * Rounded "inflated" relief: distance from each pixel to the silhouette's edge (two-pass
 * chamfer transform on a downscaled mask), shaped into a dome.
 */
function reliefFromMask(mask) {
  const W = mask.width, H = mask.height, k = Math.min(1, 192 / Math.max(W, H));
  const w = Math.max(2, Math.round(W * k)), h = Math.max(2, Math.round(H * k));
  const px = resizeCanvas(mask, w, h).getContext('2d').getImageData(0, 0, w, h).data;
  const d = new Float32Array(w * h);
  for (let i = 0; i < w * h; i++) d[i] = px[i * 4] > 127 ? 1e9 : 0;
  const D = Math.SQRT2;
  const relax = (i, j, c) => { if (d[j] + c < d[i]) d[i] = d[j] + c; };
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const i = y * w + x;
    if (x === 0 || y === 0 || x === w - 1 || y === h - 1) { d[i] = Math.min(d[i], 1); continue; }
    relax(i, i - 1, 1); relax(i, i - w, 1); relax(i, i - w - 1, D); relax(i, i - w + 1, D);
  }
  for (let y = h - 1; y >= 0; y--) for (let x = w - 1; x >= 0; x--) {
    const i = y * w + x;
    if (x === 0 || y === 0 || x === w - 1 || y === h - 1) continue;
    relax(i, i + 1, 1); relax(i, i + w, 1); relax(i, i + w + 1, D); relax(i, i + w - 1, D);
  }
  let max = 1;
  for (const v of d) if (v < 1e9 && v > max) max = v;
  const small = document.createElement('canvas');
  small.width = w; small.height = h;
  const g = small.getContext('2d'), img = g.createImageData(w, h);
  for (let i = 0; i < w * h; i++) {
    const t = Math.min(1, d[i] / max);
    const v = Math.round(Math.sqrt(1 - (1 - t) * (1 - t)) * 255); // circular profile: a dome
    img.data.set([v, v, v, 255], i * 4);
  }
  g.putImageData(img, 0, 0);
  return resizeCanvas(small, W, H);
}

function normalise(c) {
  const g = c.getContext('2d'), d = g.getImageData(0, 0, c.width, c.height);
  let lo = 255, hi = 0;
  for (let i = 0; i < d.data.length; i += 4) { lo = Math.min(lo, d.data[i]); hi = Math.max(hi, d.data[i]); }
  const k = 255 / Math.max(1, hi - lo);
  for (let i = 0; i < d.data.length; i += 4) { const v = (d.data[i] - lo) * k; d.data[i] = d.data[i + 1] = d.data[i + 2] = v; d.data[i + 3] = 255; }
  g.putImageData(d, 0, 0);
  return c;
}

function multiplyByMask(depth, mask) {
  const g = depth.getContext('2d');
  g.globalCompositeOperation = 'multiply';
  g.drawImage(mask, 0, 0, depth.width, depth.height);
  g.globalCompositeOperation = 'source-over';
  return depth;
}
