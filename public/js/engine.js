// Owns the open project, the render loop and every live input. The UI mutates the
// project through these helpers so saving, scene switching and playback stay consistent.

import { Renderer } from './renderer.js';
import { Media } from './media.js';
import { AudioEngine, MIDI } from './audio.js';
import { Tracker } from './vision.js';
import { saveProject, assetURL } from './storage.js';
import { rectMesh, quadMesh, translateMesh } from './geometry.js';
import {
  uid, newScene, newSurface, randomPresetLayer, emptyContext, lfoValue, envValue,
  clipAt, laneValue, timelineDuration, shapeName,
} from './model.js';

export class Engine {
  constructor(canvas, project) {
    this.canvas = canvas;
    this.project = project;
    this.media = new Media();
    this.renderer = new Renderer(canvas, {
      source: (l, c) => this.media.source(l, c),
      mask: (s, w, h) => this.media.mask(s, w, h),
      depth: (s) => this.media.depth(s),
    });
    this.media.attach(this.renderer.gl);
    this.audio = new AudioEngine();
    this.midi = new MIDI();
    this.tracker = new Tracker(this.media.camera);

    this.selectedId = null;
    this.showOutlines = true;
    this.micOn = false;
    this.midiScenes = true;
    this.transition = null; // { from, to, start, style, duration }
    this.playing = false; // timeline
    this.position = 0;
    this.listeners = new Set();
    this.frameListeners = new Set();
    this.envTriggers = [];
    this.tapTimes = [];
    this.beatOrigin = 0;
    this.lastBeat = 0;
    this.frame = 0;
    this.ctx = emptyContext();
    this.recordSize = null; // [w, h] while exporting
    this.t0 = performance.now();
    this.running = true;
    requestAnimationFrame((t) => this.tick(t));
  }

  get now() { return (performance.now() - this.t0) / 1000; }

  // MARK: Change notification & saving

  onChange(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  onFrame(fn) { this.frameListeners.add(fn); return () => this.frameListeners.delete(fn); }

  /** Call after mutating `project`. `quiet` skips UI re-render (e.g. while dragging). */
  commit(quiet = false) {
    clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => saveProject(this.project), 600);
    if (!quiet) this.notify();
  }

  notify() {
    if (this.notifyQueued) return;
    this.notifyQueued = true;
    queueMicrotask(() => { this.notifyQueued = false; this.listeners.forEach((f) => f()); });
  }

  saveNow() { clearTimeout(this.saveTimer); return saveProject(this.project); }

  destroy() {
    this.running = false;
    this.stopTimeline();
    this.audio.stopMic();
    this.tracker.disable();
    this.saveNow();
  }

  // MARK: Output size

  /** Size the canvas drawing buffer: export size while recording, else fit the display. */
  layout() {
    const p = this.project, c = this.canvas;
    let w, h;
    if (this.recordSize) [w, h] = this.recordSize;
    else {
      const box = c.parentElement.getBoundingClientRect();
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      let cw = box.width, ch = cw / p.outputAspect;
      if (ch > box.height) { ch = box.height; cw = ch * p.outputAspect; }
      c.style.width = cw + 'px';
      c.style.height = ch + 'px';
      // Cap the buffer so phones stay smooth; 1080p-class is plenty for a live projector.
      const scale = Math.min(dpr, 1920 / Math.max(cw, 1));
      w = Math.round(cw * scale); h = Math.round(ch * scale);
    }
    if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
  }

  // MARK: Render loop

  tick(ts) {
    if (!this.running) return;
    requestAnimationFrame((t) => this.tick(t));
    this.frame++;
    this.layout();
    const t = this.now;
    const ctx = this.makeContext(t, ts);
    this.processTimeline(t, ctx);
    this.processTriggers(t, ctx);
    ctx.env = this.project.envelopes.map((e, i) => envValue(e, this.envTriggers[i] == null ? null : t - this.envTriggers[i]));
    this.ctx = ctx;
    this.renderer.render(this.frameState(ctx, t));
    if (this.frame % 4 === 0) this.frameListeners.forEach((f) => f(ctx));
    if (this.frame % 120 === 0) this.media.purge();
    if (this.midiLearn) {
      const cc = this.midi.takeLastCC();
      if (cc) { this.midiLearn(`midi:${cc[0]}:${cc[1]}`); this.midiLearn = null; this.notify(); }
    }
  }

  makeContext(t, ts) {
    const p = this.project, ctx = emptyContext();
    ctx.time = t;
    ctx.frame = this.frame;
    ctx.beat = ((t - this.beatOrigin) * p.bpm) / 60;
    ctx.lfo = p.lfos.map((l) => lfoValue(l, ctx.beat));
    ctx.macros = [...p.macros];
    ctx.midi = this.midi.cc;
    ctx.audio = this.audio.read(ts);
    ctx.tracking = this.tracker.update(ts);
    return ctx;
  }

  frameState(ctx, t) {
    const p = this.project;
    const scene = p.scenes.find((s) => s.id === p.activeSceneId) || p.scenes[0];
    const state = { project: p, scene, incoming: null, ctx, showOutlines: this.showOutlines && !this.recordSize, selectedId: this.selectedId };
    const tr = this.transition;
    if (tr) {
      const from = p.scenes.find((s) => s.id === tr.from), to = p.scenes.find((s) => s.id === tr.to);
      const progress = Math.min(1, (t - tr.start) / Math.max(tr.duration, 0.001));
      if (from && to && progress < 1) {
        state.scene = from;
        state.incoming = { scene: to, progress, style: tr.style };
      } else {
        this.transition = null;
        p.activeSceneId = tr.to;
        if (to) state.scene = to;
        this.commit();
      }
    }
    return state;
  }

  processTriggers(t, ctx) {
    const beat = Math.floor(ctx.beat), newBeat = beat !== Math.floor(this.lastBeat), newBar = newBeat && beat % 4 === 0;
    this.lastBeat = ctx.beat;
    const notes = this.midi.drainNotes();
    if (this.midiScenes) {
      // Pads from C1 (36) upward select scenes in order.
      for (const [, n] of notes) { const s = this.project.scenes[n - 36]; if (s) this.goToScene(s.id); }
    }
    this.project.envelopes.forEach((env, i) => {
      const fire = { beat: newBeat, bar: newBar, onset: ctx.audio.onset, midi: notes.length > 0, manual: false }[env.trigger];
      if (fire) this.envTriggers[i] = t;
    });
  }

  // MARK: Tempo, envelopes, MIDI learn

  tapTempo() {
    const t = this.now;
    this.tapTimes = this.tapTimes.filter((x) => t - x < 3).concat(t);
    if (this.tapTimes.length >= 2) {
      const iv = this.tapTimes.slice(1).map((x, i) => x - this.tapTimes[i]);
      this.project.bpm = Math.min(240, Math.max(40, Math.round(60 / (iv.reduce((a, b) => a + b) / iv.length))));
      this.commit();
    }
    this.beatOrigin = t;
  }

  hit() {
    this.project.envelopes.forEach((e, i) => { if (e.trigger === 'manual') this.envTriggers[i] = this.now; });
  }

  learnMIDI(cb) {
    this.midi.start().catch(() => {});
    this.midi.takeLastCC();
    this.midiLearn = cb;
    this.notify();
  }

  async setMic(on) {
    this.micOn = on;
    if (on) {
      try { await this.audio.startMic(); } catch (e) { this.micOn = false; alert('Microphone unavailable: ' + e.message); }
    } else this.audio.stopMic();
    this.notify();
  }

  async setTracking(on) {
    if (on) { this.tracker.enable().then(() => this.notify()); } else this.tracker.disable();
    this.notify();
  }

  // MARK: Scenes

  get activeScene() { return this.project.scenes.find((s) => s.id === this.project.activeSceneId) || this.project.scenes[0]; }

  goToScene(id) {
    const p = this.project;
    if (this.transition) {
      if (this.transition.to === id) return;
      p.activeSceneId = this.transition.to; // snap the running transition
      this.transition = null;
    }
    if (id === p.activeSceneId) return;
    const tr = p.transition;
    if (tr.style === 'cut' || tr.duration <= 0) p.activeSceneId = id;
    else this.transition = { from: p.activeSceneId, to: id, start: this.now, style: tr.style, duration: tr.duration };
    this.commit();
  }

  addScene(source) {
    const s = newScene(`Scene ${this.project.scenes.length + 1}`);
    if (source) {
      s.name = source.name + ' copy';
      // New layer ids so generator textures aren't shared between scenes.
      s.content = JSON.parse(JSON.stringify(source.content));
      for (const c of Object.values(s.content)) for (const l of c.layers) l.id = uid();
    }
    this.project.scenes.push(s);
    this.goToScene(s.id);
    this.commit();
  }

  deleteScene(id) {
    const p = this.project;
    if (p.scenes.length < 2) return;
    p.scenes = p.scenes.filter((s) => s.id !== id);
    p.timeline.clips = p.timeline.clips.filter((c) => c.sceneId !== id);
    if (p.activeSceneId === id) p.activeSceneId = p.scenes[0].id;
    this.commit();
  }

  // MARK: Surfaces

  get selected() { return this.project.surfaces.find((s) => s.id === this.selectedId) || null; }

  select(id) { this.selectedId = id; this.notify(); }

  addSurface(shape, { name, mesh, layer } = {}) {
    const p = this.project, a = p.outputAspect, n = p.surfaces.length;
    const off = (n % 5) * 0.04;
    mesh ??= shape.type === 'text' ? rectMesh(0.5, 0.5, 0.6, 0.25) : rectMesh(0.5 + off, 0.5 + off, (0.45 / a) * 1.0, 0.45);
    const s = newSurface(name || `${shapeName(shape)} ${n + 1}`, shape, mesh);
    p.surfaces.push(s);
    this.updateContent(s.id, (c) => { c.layers = [layer || randomPresetLayer()]; });
    this.selectedId = s.id;
    this.commit();
    return s;
  }

  /** Three faces of a box seen corner-on (top, left, right) that share edges. */
  addBox() {
    const a = this.project.outputAspect, group = uid();
    const c = [0.5, 0.52], w = (0.16 / a) * 1.6, h = 0.12, d = 0.22;
    const top = [c[0], c[1] - h * 2], left = [c[0] - w, c[1] - h], right = [c[0] + w, c[1] - h];
    const bottom = [c[0], c[1] + d], bl = [left[0], left[1] + d], br = [right[0], right[1] + d];
    const meshes = [quadMesh(left, top, c, right), quadMesh(left, c, bl, bottom), quadMesh(c, right, bottom, br)];
    const layer = randomPresetLayer();
    ['Box top', 'Box left', 'Box right'].forEach((name, i) => {
      const l = JSON.parse(JSON.stringify(layer));
      l.id = uid();
      const s = this.addSurface({ type: 'box', face: i }, { name, mesh: meshes[i], layer: l });
      s.groupId = group;
    });
    this.commit();
  }

  updateSurface(id, fn, quiet = false) {
    const s = this.project.surfaces.find((x) => x.id === id);
    if (s) { fn(s); this.commit(quiet); }
  }

  deleteSurface(id) {
    const p = this.project;
    p.surfaces = p.surfaces.filter((s) => s.id !== id);
    for (const sc of p.scenes) delete sc.content[id];
    if (this.selectedId === id) this.selectedId = null;
    this.commit();
  }

  duplicateSurface(id) {
    const p = this.project, s = p.surfaces.find((x) => x.id === id);
    if (!s) return;
    const copy = JSON.parse(JSON.stringify(s));
    Object.assign(copy, { id: uid(), name: s.name + ' copy', groupId: null, mesh: translateMesh(s.mesh, 0.03, 0.03) });
    p.surfaces.push(copy);
    for (const sc of p.scenes) {
      const c = sc.content[id];
      if (c) { sc.content[copy.id] = JSON.parse(JSON.stringify(c)); sc.content[copy.id].layers.forEach((l) => { l.id = uid(); }); }
    }
    this.selectedId = copy.id;
    this.commit();
  }

  moveSurface(id, delta) {
    const arr = this.project.surfaces, i = arr.findIndex((s) => s.id === id), j = Math.min(Math.max(i + delta, 0), arr.length - 1);
    if (i < 0 || i === j) return;
    [arr[i], arr[j]] = [arr[j], arr[i]];
    this.commit();
  }

  content(surfaceId) {
    const sc = this.activeScene;
    return (sc.content[surfaceId] ??= { layers: [] });
  }

  updateContent(surfaceId, fn) { fn(this.content(surfaceId)); this.commit(); }

  layer(surfaceId, layerId) { return this.content(surfaceId).layers.find((l) => l.id === layerId); }

  // MARK: Timeline

  async playTimeline({ fromStart = true } = {}) {
    const tl = this.project.timeline;
    tl.clips.sort((a, b) => a.start - b.start);
    if (!tl.clips.length) return false;
    const url = tl.audioAssetId ? await assetURL(tl.audioAssetId) : null;
    const el = this.audio.setTrack(url);
    this.timelineStart = this.now;
    this.lastClipId = null;
    this.playing = true;
    if (el) { if (fromStart) el.currentTime = 0; await el.play().catch(() => {}); }
    this.media.restartVideos();
    this.notify();
    return true;
  }

  stopTimeline() {
    this.playing = false;
    this.audio.track?.el.pause();
    this.notify();
  }

  processTimeline(t, ctx) {
    if (!this.playing) return;
    const tl = this.project.timeline, dur = timelineDuration(tl), el = this.audio.track?.el;
    let pos = el && !el.paused ? el.currentTime : t - this.timelineStart;
    if (pos >= dur || (el && el.ended)) {
      if (this.onShowEnd?.()) return; // exporter stops here instead of looping
      this.timelineStart = t; // loop the show
      if (el) { el.currentTime = 0; el.play().catch(() => {}); }
      pos = 0;
    }
    this.position = pos;
    const clip = clipAt(tl, pos);
    if (clip && clip.id !== this.lastClipId) {
      const first = this.lastClipId == null;
      this.lastClipId = clip.id;
      if (first) { this.transition = null; this.project.activeSceneId = clip.sceneId; this.notify(); }
      else this.goToScene(clip.sceneId);
    }
    for (const lane of tl.automation) {
      const v = laneValue(lane, pos);
      if (v != null) ctx.macros[lane.macro] = v;
    }
  }
}
