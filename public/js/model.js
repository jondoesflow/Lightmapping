// Project data model. Everything is plain JSON so it saves straight to IndexedDB.
//
// Surfaces hold the geometry (calibrated once to the physical space). Scenes decide what
// content plays on each surface, so switching scenes never disturbs the alignment.

import { rectMesh, quadMesh } from './geometry.js';
import { PRESETS, presetById } from './presets.js';

export const uid = () => (crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2) + Date.now().toString(36));

export const param = (base, mod = null) => ({ base, mod });

export const EFFECTS = {
  kaleidoscope: { name: 'Kaleidoscope', def: 6, min: 2, max: 16 },
  tile: { name: 'Tile', def: 2, min: 1, max: 8 },
  slide: { name: 'Slide', def: 0.2, min: -2, max: 2 },
  rotate: { name: 'Rotate', def: 0.1, min: -2, max: 2 },
  zoom: { name: 'Zoom', def: 1.5, min: 0.25, max: 4 },
  blur: { name: 'Blur', def: 0.3, min: 0, max: 1 },
  monochrome: { name: 'Monochrome', def: 1, min: 0, max: 1 },
  invert: { name: 'Invert', def: 1, min: 0, max: 1 },
  colorCycle: { name: 'Color cycle', def: 0.2, min: 0, max: 2 },
};

export const effect = (kind) => ({ id: uid(), kind, amount: param(EFFECTS[kind].def), on: true });

export function newProject(name) {
  const scene = newScene('Scene 1');
  return {
    id: uid(), name, created: Date.now(), modified: Date.now(),
    surfaces: [], scenes: [scene], activeSceneId: scene.id,
    bpm: 120,
    lfos: [{ shape: 'sine', beats: 1 }, { shape: 'triangle', beats: 4 }, { shape: 'saw', beats: 2 }, { shape: 'square', beats: 0.5 }],
    envelopes: [{ trigger: 'beat', attack: 0.01, decay: 0.35 }, { trigger: 'onset', attack: 0.01, decay: 0.35 }],
    macros: [0, 0, 0, 0],
    timeline: { clips: [], automation: [], audioAssetId: null },
    transition: { style: 'fade', duration: 1.5 },
    outputAspect: 16 / 9,
  };
}

export const newScene = (name) => ({ id: uid(), name, content: {} });

export function newSurface(name, shape, mesh) {
  return { id: uid(), name, shape, mesh, groupId: null, visible: true, locked: false, opacity: 1, feather: 0, cutouts: [] };
}

export function newLayer(name, source) {
  return {
    id: uid(), name, source, visible: true, opacity: param(1), blend: 'normal', fit: 'fill', crop: [0, 0, 1, 1], effects: [],
    gen: { speed: param(1), scale: param(1), intensity: param(1), a: [1, 0.2, 0.6], b: [0.1, 0.6, 1], c: [0.05, 0, 0.15], seed: Math.random() },
  };
}

export function layerFromPreset(p) {
  const l = newLayer(p.name, { type: 'generator', kind: p.kind });
  l.gen = {
    speed: param(p.speed), scale: param(p.scale),
    intensity: param(p.intensity, p.audio ? { src: 'audioLevel', depth: 1.2 } : null),
    a: [...p.colors[0]], b: [...p.colors[1]], c: [...p.colors[2]],
    // Stable per preset so a look is repeatable.
    seed: [...p.id].reduce((h, ch) => (h * 31 + ch.charCodeAt(0)) % 10007, 0) / 10007,
  };
  l.effects = p.effects.map(effect);
  return l;
}

export const randomPresetLayer = () => layerFromPreset(PRESETS[Math.floor(Math.random() * PRESETS.length)]);

export const shapeName = (shape) => ({
  quad: 'Square', circle: 'Circle', text: `Text “${shape.text}”`, box: 'Box face', silhouette: 'Silhouette', depth: 'Depth shape', freehand: 'Outline',
})[shape.type] || 'Surface';

// MARK: Modulation

export const MOD_SOURCES = [
  ['audioLevel', 'Audio level'], ['audioBass', 'Audio bass'], ['audioMid', 'Audio mid'], ['audioHigh', 'Audio high'],
  ['lfo0', 'LFO 1'], ['lfo1', 'LFO 2'], ['lfo2', 'LFO 3'], ['lfo3', 'LFO 4'],
  ['env0', 'Envelope 1'], ['env1', 'Envelope 2'],
  ['macro0', 'Macro 1'], ['macro1', 'Macro 2'], ['macro2', 'Macro 3'], ['macro3', 'Macro 4'],
  ['handX', 'Hand X'], ['handY', 'Hand Y'], ['pinch', 'Pinch'], ['faceX', 'Face X'], ['faceY', 'Face Y'], ['mouthOpen', 'Mouth open'],
];
export const modName = (src) => (src.startsWith('midi:') ? `MIDI ch${+src.split(':')[1] + 1} CC${src.split(':')[2]}` : (MOD_SOURCES.find((m) => m[0] === src) || [, src])[1]);
const BIPOLAR = /^(lfo|handX|handY|faceX|faceY)/;
export const needsAudio = (src) => src.startsWith('audio');
export const needsTracking = (src) => /^(hand|pinch|face|mouth)/.test(src);

/** Evaluate a parameter against a modulation context. */
export function pv(p, ctx) {
  if (!p.mod) return p.base;
  const v = sourceValue(p.mod.src, ctx);
  return p.base + (BIPOLAR.test(p.mod.src) ? v * 2 - 1 : v) * p.mod.depth;
}

export function sourceValue(src, ctx) {
  if (src.startsWith('audio')) return ctx.audio[src.slice(5).toLowerCase()] ?? 0;
  if (src.startsWith('lfo')) return ctx.lfo[+src[3]] ?? 0.5;
  if (src.startsWith('env')) return ctx.env[+src[3]] ?? 0;
  if (src.startsWith('macro')) return ctx.macros[+src[5]] ?? 0;
  if (src.startsWith('midi:')) { const [, ch, cc] = src.split(':'); return ctx.midi[ch * 128 + +cc] ?? 0; }
  return ctx.tracking[src] ?? 0;
}

export function lfoValue(lfo, beat) {
  const x = ((beat / Math.max(lfo.beats, 1e-3)) % 1 + 1) % 1;
  switch (lfo.shape) {
    case 'sine': return 0.5 - 0.5 * Math.cos(x * 2 * Math.PI);
    case 'triangle': return x < 0.5 ? x * 2 : 2 - x * 2;
    case 'saw': return x;
    case 'square': return x < 0.5 ? 1 : 0;
    default: { // stepped random, deterministic per cycle
      const cycle = Math.floor(beat / Math.max(lfo.beats, 1e-3));
      const s = Math.sin(cycle * 12.9898 + 78.233) * 43758.5453;
      return s - Math.floor(s);
    }
  }
}

export function envValue(env, since) {
  if (since == null || since < 0) return 0;
  if (since < env.attack) return since / Math.max(env.attack, 1e-4);
  return Math.max(0, Math.exp(-((since - env.attack) / Math.max(env.decay, 1e-4)) * 3));
}

export function emptyContext() {
  return {
    time: 0, beat: 0, audio: { level: 0, bass: 0, mid: 0, high: 0, onset: false },
    lfo: [], env: [], macros: [0, 0, 0, 0], midi: {},
    tracking: { handX: 0.5, handY: 0.5, pinch: 0, faceX: 0.5, faceY: 0.5, mouthOpen: 0 },
  };
}

// MARK: Timeline

export const timelineDuration = (tl) => tl.clips.reduce((m, c) => Math.max(m, c.start + c.duration), 0);

/** Clip playing at t (later clips win where they overlap). */
export function clipAt(tl, t) {
  let hit = null;
  for (const c of tl.clips) if (t >= c.start && t < c.start + c.duration) hit = c;
  return hit;
}

export function laneValue(lane, t) {
  const k = lane.keys;
  if (!k.length) return null;
  if (t <= k[0].t) return k[0].v;
  for (let i = 1; i < k.length; i++) {
    if (t <= k[i].t) return k[i - 1].v + (k[i].v - k[i - 1].v) * ((t - k[i - 1].t) / Math.max(k[i].t - k[i - 1].t, 1e-6));
  }
  return k[k.length - 1].v;
}

// MARK: Demo

/** A ready-to-map starter: a wall, a window and a porch arch across three scenes. */
export function demoProject() {
  const p = newProject('Demo house');
  const wall = newSurface('Wall', { type: 'quad' }, quadMesh([0.05, 0.1], [0.45, 0.14], [0.05, 0.9], [0.45, 0.86]));
  const win = newSurface('Window', { type: 'quad' }, rectMesh(0.72, 0.35, 0.2, 0.3));
  const porch = newSurface('Porch arch', { type: 'circle' }, rectMesh(0.72, 0.75, 0.25, 0.3));
  p.surfaces = [wall, win, porch];
  const L = (id) => layerFromPreset(presetById(id));
  const scene = (name, w, wi, po) => ({ id: uid(), name, content: { [wall.id]: { layers: w.map(L) }, [win.id]: { layers: [L(wi)] }, [porch.id]: { layers: [L(po)] } } });
  p.scenes = [
    scene('Halloween', ['hw.fog', 'hw.lightning'], 'hw.eyes', 'hw.fire'),
    scene('Christmas', ['xm.snow'], 'xm.warmlights', 'xm.candy'),
    scene('Party', ['audio.spectrum'], 'vj.tunnel.cyan', 'audio.rings'),
  ];
  p.scenes[0].content[wall.id].layers[1].blend = 'add';
  p.activeSceneId = p.scenes[0].id;
  p.timeline.clips = p.scenes.map((s, i) => ({ id: uid(), sceneId: s.id, start: i * 16, duration: 16 }));
  return p;
}
