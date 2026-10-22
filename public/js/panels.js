// Side panel / bottom sheet views and modals.

import { h, clear, button, section, row, slider, toggle, select, numberInput, colorInput, paramControl, menu, pickFile, modal, toast, meter } from './ui.js';
import { GENERATORS, SHAPE_AWARE, CATEGORIES, PRESETS } from './presets.js';
import { EFFECTS, effect, newLayer, layerFromPreset, shapeName, uid, timelineDuration } from './model.js';
import { resample, rectMesh } from './geometry.js';
import { putAsset } from './storage.js';
import { drawStrokes, DRAWING_SIZE } from './media.js';
import { segmentAt, estimateDepth } from './vision.js';
import { recordShow, shareFile, canExport, RESOLUTIONS } from './export.js';
import { LinkSender } from './link.js';

const fmt = (t) => `${Math.floor(t / 60)}:${(t % 60).toFixed(1).padStart(4, '0')}`;
const sourceIcon = { generator: '✨', photo: '🖼', video: '🎞', camera: '📷', drawing: '✏️' };

// MARK: Surfaces

export function surfacesPanel(eng, ui) {
  const s = eng.selected;
  if (!s) {
    return h('div',
      section(null, eng.project.surfaces.length ? null : h('p.hint', 'Add a surface with ＋, then drag its corners onto your wall, object or window.'),
        h('div.list', [...eng.project.surfaces].reverse().map((x) =>
          h('button.item', { type: 'button', onClick: () => eng.select(x.id) },
            h('span', x.visible ? '👁' : '🚫'), h('span.grow', x.name), h('small', shapeName(x.shape)))))));
  }
  const edit = (fn, quiet) => eng.updateSurface(s.id, fn, quiet);
  const layers = eng.content(s.id).layers;
  return h('div',
    h('div.panel-nav', button('‹ All surfaces', () => eng.select(null), 'link')),
    section('Surface',
      row('Name', h('input', { value: s.name, onChange: (e) => edit((x) => { x.name = e.target.value; }) })),
      row('Visible', toggle(s.visible, (v) => edit((x) => { x.visible = v; }))),
      row('Lock position', toggle(s.locked, (v) => edit((x) => { x.locked = v; }))),
      row('Opacity', slider(s.opacity, 0, 1, 0.01, (v) => edit((x) => { x.opacity = v; }, true))),
      row('Soft edge', slider(s.feather, 0, 0.25, 0.005, (v) => edit((x) => { x.feather = v; }, true))),
      row('Warp grid', select(s.mesh.cols, [[2, 'Corners'], [3, '3 × 3'], [4, '4 × 4'], [5, '5 × 5']], (v) => edit((x) => { x.mesh = resample(x.mesh, +v); }))),
      h('div.buttons',
        button('✂︎ Cut out', () => ui.setTool('cutout')),
        s.cutouts.length ? button(`Clear ${s.cutouts.length} cutout${s.cutouts.length > 1 ? 's' : ''}`, () => edit((x) => { x.cutouts = []; })) : null,
        button('Forward', () => eng.moveSurface(s.id, 1)),
        button('Back', () => eng.moveSurface(s.id, -1)),
        button('Duplicate', () => eng.duplicateSurface(s.id)),
        button('Delete', () => confirm(`Delete “${s.name}”?`) && eng.deleteSurface(s.id), 'danger'))),
    section(`Layers in ${eng.activeScene.name}`,
      h('p.hint', 'Top of the list draws last (in front).'),
      h('div.list', layers.map((l, i) => h('div.item',
        h('button.grow', { type: 'button', onClick: () => ui.open('layer', { layerId: l.id }) }, `${sourceIcon[l.source.type] || ''} ${l.name}${l.visible ? '' : ' (hidden)'}`),
        button('↑', () => eng.updateContent(s.id, (c) => { if (i > 0) [c.layers[i - 1], c.layers[i]] = [c.layers[i], c.layers[i - 1]]; }), 'icon'),
        button('↓', () => eng.updateContent(s.id, (c) => { if (i < c.layers.length - 1) [c.layers[i + 1], c.layers[i]] = [c.layers[i], c.layers[i + 1]]; }), 'icon'),
        button('✕', () => eng.updateContent(s.id, (c) => { c.layers.splice(i, 1); }), 'icon danger')))),
      h('div.buttons', button('＋ Add layer', (e) => addLayerMenu(eng, ui, s, e.currentTarget), 'primary'))));
}

function addLayerMenu(eng, ui, s, anchor) {
  const add = (l) => { eng.updateContent(s.id, (c) => c.layers.push(l)); return l; };
  menu(anchor, [
    ['✨ Visual library', () => libraryModal((p) => add(layerFromPreset(p)))],
    ['🖼 Photo or video…', async () => {
      const [file] = await pickFile('image/*,video/*');
      if (!file) return;
      const id = uid();
      await putAsset(id, file);
      const video = file.type.startsWith('video');
      add(newLayer(video ? 'Video' : 'Photo', { type: video ? 'video' : 'photo', assetId: id }));
    }],
    ['📷 Live camera', () => add(newLayer('Camera', { type: 'camera', facing: 'environment' }))],
    ['🤳 Front camera', () => add(newLayer('Front camera', { type: 'camera', facing: 'user' }))],
    ['✏️ Hand drawing', () => {
      const l = add(newLayer('Drawing', { type: 'drawing', drawing: { strokes: [], animation: 'traceOn', period: 4 } }));
      drawingModal(eng, s.id, l.id);
    }],
  ]);
}

// MARK: Layer

export function layerPanel(eng, ui) {
  const s = eng.selected, l = s && eng.layer(s.id, ui.layerId);
  if (!l) { ui.open('surfaces'); return h('div'); }
  const quiet = () => eng.commit(true), loud = () => eng.commit();
  const pc = (title, p, min, max) => paramControl(eng, title, p, min, max, (structural) => (structural ? loud() : quiet()));
  const src = l.source;
  return h('div',
    h('div.panel-nav', button(`‹ ${s.name}`, () => ui.open('surfaces'), 'link')),
    section('Layer',
      row('Name', h('input', { value: l.name, onChange: (e) => { l.name = e.target.value; loud(); } })),
      row('Visible', toggle(l.visible, (v) => { l.visible = v; loud(); })),
      pc('Opacity', l.opacity, 0, 1),
      row('Blend', select(l.blend, [['normal', 'Normal'], ['add', 'Add'], ['screen', 'Screen'], ['multiply', 'Multiply']], (v) => { l.blend = v; loud(); })),
      row('Fit', select(l.fit, [['fill', 'Fill'], ['fit', 'Fit'], ['stretch', 'Stretch']], (v) => { l.fit = v; loud(); }))),
    src.type === 'generator' ? section(`Visual · ${GENERATORS[src.kind]}`,
      row('Pattern', select(src.kind, GENERATORS.map((n, i) => [i, n]), (v) => { src.kind = +v; loud(); })),
      pc('Speed', l.gen.speed, 0, 4),
      pc('Scale', l.gen.scale, 0.1, 4),
      pc('Intensity', l.gen.intensity, 0, 2),
      row('Colour A', colorInput(l.gen.a, (c) => { l.gen.a = c; quiet(); })),
      row('Colour B', colorInput(l.gen.b, (c) => { l.gen.b = c; quiet(); })),
      row('Background', colorInput(l.gen.c, (c) => { l.gen.c = c; quiet(); })),
      SHAPE_AWARE.has(src.kind) ? h('p.hint', 'Follows this surface’s shape and depth.') : null) : null,
    src.type === 'camera' ? section('Camera', row('Camera', select(src.facing, [['environment', 'Back'], ['user', 'Front']], (v) => { src.facing = v; loud(); }))) : null,
    src.type === 'drawing' ? section('Drawing', h('div.buttons', button('✏️ Edit drawing', () => drawingModal(eng, s.id, l.id), 'primary'))) : null,
    section('Crop',
      ['Left', 'Top', 'Width', 'Height'].map((n, i) => row(n, slider(l.crop[i], i < 2 ? 0 : 0.05, i < 2 ? 0.95 : 1, 0.005, (v) => { l.crop[i] = v; quiet(); })))),
    section('Effects',
      l.effects.map((e, i) => h('div.effect',
        h('div.effect-head', toggle(e.on, (v) => { e.on = v; quiet(); }), button('✕', () => { l.effects.splice(i, 1); loud(); }, 'icon danger')),
        pc(EFFECTS[e.kind].name, e.amount, EFFECTS[e.kind].min, EFFECTS[e.kind].max))),
      h('div.buttons', button('＋ Add effect', (ev) => menu(ev.currentTarget, Object.entries(EFFECTS).map(([k, v]) => [v.name, () => { l.effects.push(effect(k)); loud(); }]))))));
}

// MARK: Library

export function libraryModal(onPick) {
  let cat = CATEGORIES[0];
  const chips = h('div.chips'), grid = h('div.grid');
  const draw = () => {
    clear(chips, CATEGORIES.map((c) => button(c, () => { cat = c; draw(); }, c === cat ? 'chip on' : 'chip')));
    clear(grid, PRESETS.filter((p) => p.cat === cat).map((p) => {
      const css = (c) => `rgb(${c.map((x) => Math.round(x * 255)).join(',')})`;
      return h('button.tile', { type: 'button', onClick: () => { onPick(p); m.close(); } },
        h('div.swatch', { style: { background: `linear-gradient(45deg, ${css(p.colors[2])}, ${css(p.colors[0])}, ${css(p.colors[1])})` } },
          p.audio ? '〰' : SHAPE_AWARE.has(p.kind) ? '◎' : ''),
        h('strong', p.name), h('small', GENERATORS[p.kind]));
    }));
  };
  const m = modal(`Visual library (${PRESETS.length})`, [chips, grid], { wide: true });
  draw();
}

// MARK: Drawing editor

export function drawingModal(eng, surfaceId, layerId) {
  const l = eng.layer(surfaceId, layerId);
  if (!l) return;
  const d = l.source.drawing;
  const pen = { color: '#00e5ff', width: 12, glow: 0.6 };
  const cv = h('canvas.draw-canvas', { width: DRAWING_SIZE, height: DRAWING_SIZE });
  let cur = null, raf = 0;
  const pos = (e) => { const r = cv.getBoundingClientRect(); return [(e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height]; };
  cv.addEventListener('pointerdown', (e) => { cv.setPointerCapture(e.pointerId); cur = { points: [pos(e)], ...pen }; d.strokes.push(cur); });
  cv.addEventListener('pointermove', (e) => { if (cur) cur.points.push(pos(e)); });
  const end = () => { if (cur) { if (cur.points.length < 2) d.strokes.pop(); cur = null; eng.commit(true); } };
  cv.addEventListener('pointerup', end);
  cv.addEventListener('pointercancel', end);
  const t0 = performance.now();
  const loop = () => {
    const g = cv.getContext('2d');
    g.fillStyle = '#000';
    g.fillRect(0, 0, DRAWING_SIZE, DRAWING_SIZE);
    // While drawing, show everything; otherwise preview the animation.
    drawStrokes(g, cur ? { ...d, animation: 'none' } : d, (performance.now() - t0) / 1000, DRAWING_SIZE);
    raf = requestAnimationFrame(loop);
  };
  loop();
  modal('Drawing', h('div.drawing',
    cv,
    h('div.drawing-tools',
      row('Colour', h('input.color', { type: 'color', value: pen.color, onInput: (e) => { pen.color = e.target.value; } })),
      row('Width', slider(pen.width, 2, 40, 1, (v) => { pen.width = v; })),
      row('Glow', slider(pen.glow, 0, 1, 0.05, (v) => { pen.glow = v; })),
      row('Animation', select(d.animation, [['none', 'None'], ['traceOn', 'Trace on'], ['pulse', 'Pulse'], ['hueCycle', 'Hue cycle'], ['flicker', 'Flicker']], (v) => { d.animation = v; eng.commit(true); })),
      row('Cycle (s)', slider(d.period, 0.5, 12, 0.5, (v) => { d.period = v; eng.commit(true); })),
      h('div.buttons', button('Undo', () => { d.strokes.pop(); eng.commit(true); }), button('Clear', () => { d.strokes.length = 0; eng.commit(true); }, 'danger')))),
  { wide: true, onClose: () => { cancelAnimationFrame(raf); eng.commit(); } });
}

// MARK: Shape from photo (silhouette / depth)

export async function photoShapeFlow(eng, wantDepth) {
  const [file] = await pickFile('image/*');
  if (!file) return;
  const img = new Image();
  img.src = URL.createObjectURL(file);
  await img.decode();
  const status = h('p.hint', 'Tap the object you want to project onto.');
  const preview = h('canvas.shape-preview');
  const aiToggle = toggle(false, () => {});
  let mask = null;
  const pv = preview.getContext('2d');
  const scale = Math.min(1, 1200 / Math.max(img.naturalWidth, img.naturalHeight));
  preview.width = Math.round(img.naturalWidth * scale);
  preview.height = Math.round(img.naturalHeight * scale);
  // Dim the photo and show the selected object at full brightness.
  const paint = () => {
    pv.clearRect(0, 0, preview.width, preview.height);
    pv.globalAlpha = mask ? 0.35 : 1;
    pv.drawImage(img, 0, 0, preview.width, preview.height);
    pv.globalAlpha = 1;
    if (!mask) return;
    const tmp = document.createElement('canvas');
    tmp.width = preview.width; tmp.height = preview.height;
    const tg = tmp.getContext('2d');
    tg.drawImage(mask, 0, 0, tmp.width, tmp.height);
    tg.globalCompositeOperation = 'source-in';
    tg.drawImage(img, 0, 0, tmp.width, tmp.height);
    pv.drawImage(tmp, 0, 0);
  };
  paint();
  preview.addEventListener('click', async (e) => {
    const r = preview.getBoundingClientRect();
    status.textContent = 'Finding the object…';
    mask = await segmentAt(img, (e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height);
    // Mask comes back white-on-black; turn black into transparent for the preview composite.
    mask = toAlpha(mask);
    paint();
    status.textContent = 'Happy with it? Tap “Create shape”, or tap again to pick something else.';
  });
  const create = button('Create shape', async () => {
    if (!mask) return toast('Tap the object first');
    create.disabled = true;
    try {
      const maskOpaque = toOpaque(mask);
      const maskId = uid();
      await putAsset(maskId, await canvasBlob(maskOpaque));
      const aspect = img.naturalWidth / img.naturalHeight;
      const hgt = 0.6, mesh = rectMesh(0.5, 0.5, (hgt * aspect) / eng.project.outputAspect, hgt);
      if (wantDepth) {
        const depth = await estimateDepth(img, maskOpaque, aiToggle.checked, (t) => { status.textContent = t; });
        const depthId = uid();
        await putAsset(depthId, await canvasBlob(depth));
        eng.addSurface({ type: 'depth', maskId, depthId }, { name: 'Depth shape', mesh, layer: layerFromPreset(PRESETS.find((p) => p.id === 'shape.depth.contours')) });
      } else {
        eng.addSurface({ type: 'silhouette', maskId }, { name: 'Silhouette', mesh, layer: layerFromPreset(PRESETS.find((p) => p.id === 'neon.edge.blue')) });
      }
      m.close();
    } catch (err) {
      toast('Couldn’t create shape: ' + err.message);
      create.disabled = false;
    }
  }, 'primary');
  const m = modal(wantDepth ? 'Depth shape from photo' : 'Silhouette from photo', h('div.shape-flow',
    preview, status,
    wantDepth ? row('AI depth (downloads ~30 MB once)', aiToggle) : null,
    h('div.buttons', create)), { wide: true });
}

function toAlpha(c) {
  const g = c.getContext('2d'), d = g.getImageData(0, 0, c.width, c.height);
  for (let i = 0; i < d.data.length; i += 4) { d.data[i + 3] = d.data[i]; d.data[i] = d.data[i + 1] = d.data[i + 2] = 255; }
  g.putImageData(d, 0, 0);
  return c;
}

function toOpaque(c) {
  const o = document.createElement('canvas');
  o.width = c.width; o.height = c.height;
  const g = o.getContext('2d');
  g.fillStyle = '#000';
  g.fillRect(0, 0, o.width, o.height);
  g.drawImage(c, 0, 0);
  return o;
}

const canvasBlob = (c) => new Promise((r) => c.toBlob(r, 'image/png'));

// MARK: Perform

export function performPanel(eng) {
  const p = eng.project;
  return h('div',
    section('Scenes', h('div.pads', p.scenes.map((s, i) => h('button.pad', {
      type: 'button',
      class: (s.id === p.activeSceneId ? 'on ' : '') + (eng.transition?.to === s.id ? 'next' : ''),
      onClick: () => eng.goToScene(s.id),
    }, h('strong', s.name), h('small', `Pad ${i + 1}`))))),
    tempoRow(eng),
    section('Macros', p.macros.map((v, i) => row(`M${i + 1}`, slider(v, 0, 1, 0.01, (x) => { p.macros[i] = x; eng.commit(true); }))),
      h('p.hint', 'Map any setting to a macro from its modulation menu. Timeline automation drives macros during playback.')),
    h('div.buttons', button('⚡ Hit (manual envelopes)', () => eng.hit(), 'primary big')),
    metersSection(eng));
}

function tempoRow(eng) {
  const p = eng.project;
  return section('Tempo', h('div.tempo',
    numberInput(p.bpm, 1, (v) => { p.bpm = Math.min(240, Math.max(40, v || 120)); eng.commit(); }, 40),
    h('span', 'BPM'), h('span.beat', { 'data-beat': 1 }), button('Tap', () => eng.tapTempo(), 'primary')));
}

function metersSection(eng) {
  return section('Inputs',
    meter('Level', 'audio.level'), meter('Bass', 'audio.bass', '#ff5252'), meter('Mid', 'audio.mid', '#ffd740'), meter('High', 'audio.high', '#40c4ff'),
    eng.project.lfos.map((_, i) => meter(`LFO ${i + 1}`, `lfo${i}`, '#b388ff')),
    eng.project.envelopes.map((_, i) => meter(`Env ${i + 1}`, `env${i}`, '#ffab40')));
}

// MARK: Timeline

export function timelinePanel(eng) {
  const p = eng.project, tl = p.timeline, dur = timelineDuration(tl) || 1;
  const sceneOpts = p.scenes.map((s) => [s.id, s.name]);
  const loud = () => eng.commit();
  const bar = 4 * 60 / p.bpm;
  return h('div',
    section(null,
      h('div.overview', tl.clips.map((c) => h('div.clip', {
        style: { left: (c.start / dur) * 100 + '%', width: (c.duration / dur) * 100 + '%', background: `hsl(${(p.scenes.findIndex((s) => s.id === c.sceneId) * 67) % 360} 60% 40%)` },
      }, p.scenes.find((s) => s.id === c.sceneId)?.name || '?')), h('div.playhead', { 'data-playhead': 1, style: { left: (eng.position / dur) * 100 + '%' } })),
      h('div.buttons',
        button(eng.playing ? '■ Stop' : '▶ Play show', () => (eng.playing ? eng.stopTimeline() : eng.playTimeline().then((ok) => ok || toast('Add a clip first'))), 'primary'),
        h('span.time', { 'data-time': 1 }, `${fmt(eng.position)} / ${fmt(timelineDuration(tl))}`))),
    section('Audio track',
      tl.audioAssetId ? h('p', '🎵 Audio attached') : h('p.hint', 'Optional: visuals react to it and it’s included in exports.'),
      h('div.buttons',
        button('Choose audio file…', async () => {
          const [f] = await pickFile('audio/*');
          if (!f) return;
          const id = uid();
          await putAsset(id, f);
          tl.audioAssetId = id;
          loud();
        }),
        tl.audioAssetId ? button('Remove', () => { tl.audioAssetId = null; eng.audio.setTrack(null); loud(); }, 'danger') : null)),
    section('Clips',
      tl.clips.map((c, i) => h('div.clip-row',
        select(c.sceneId, sceneOpts, (v) => { c.sceneId = v; loud(); }),
        h('label', 'Start', numberInput(c.start, 0.5, (v) => { c.start = Math.max(0, v); loud(); })),
        h('label', 'Length', numberInput(c.duration, 0.5, (v) => { c.duration = Math.max(0.5, v); loud(); }, 0.5)),
        h('div.buttons',
          button('Duplicate', () => { tl.clips.push({ ...c, id: uid(), start: timelineDuration(tl) }); loud(); }),
          button('Snap to bar', () => { c.start = Math.round(c.start / bar) * bar; c.duration = Math.max(bar, Math.round(c.duration / bar) * bar); loud(); }),
          button('Delete', () => { tl.clips.splice(i, 1); loud(); }, 'danger')))),
      h('div.buttons', button('＋ Add clip', () => {
        tl.clips.push({ id: uid(), sceneId: p.activeSceneId, start: timelineDuration(tl), duration: 4 * bar });
        loud();
      }, 'primary'))),
    section('Automation',
      h('p.hint', 'Each lane drives a macro over time. Set a macro to any parameter’s modulation to automate it.'),
      tl.automation.map((lane, li) => h('div.lane',
        h('div.buttons', select(lane.macro, [0, 1, 2, 3].map((m) => [m, `Macro ${m + 1}`]), (v) => { lane.macro = +v; loud(); }),
          button('Delete lane', () => { tl.automation.splice(li, 1); loud(); }, 'danger')),
        lane.keys.map((k, ki) => h('div.key', h('span', fmt(k.t)), slider(k.v, 0, 1, 0.01, (v) => { k.v = v; eng.commit(true); }), button('✕', () => { lane.keys.splice(ki, 1); loud(); }, 'icon danger'))),
        h('div.buttons', button('◆ Keyframe at playhead', () => {
          lane.keys.push({ t: eng.position, v: p.macros[lane.macro] });
          lane.keys.sort((a, b) => a.t - b.t);
          loud();
        })))),
      h('div.buttons', button('＋ Add lane', () => { tl.automation.push({ id: uid(), macro: tl.automation.length % 4, keys: [] }); loud(); }))));
}

// MARK: Export & Link

const exportState = { resolution: '1080p', fps: 30, length: 30, audio: true, progress: null, result: null, abort: null, code: '', link: new LinkSender(), live: false, sendProgress: null };

export function exportPanel(eng, ui) {
  const st = exportState, tl = eng.project.timeline;
  const rerender = () => ui.refresh();
  return h('div',
    !canExport() ? h('p.warn', 'This browser can’t record video. Use Safari 15+ on iPhone or Chrome.') : null,
    section('Export show',
      h('div.chips', Object.keys(RESOLUTIONS).map((r) => button(r, () => { st.resolution = r; rerender(); }, st.resolution === r ? 'chip on' : 'chip'))),
      row('Frame rate', select(st.fps, [[30, '30 fps'], [60, '60 fps']], (v) => { st.fps = +v; })),
      tl.clips.length ? h('p.hint', `Records the timeline (${Math.round(timelineDuration(tl))} s).`)
        : row('Length (s, current scene)', numberInput(st.length, 5, (v) => { st.length = Math.max(1, v); }, 1)),
      tl.audioAssetId ? row('Include audio', toggle(st.audio, (v) => { st.audio = v; })) : null,
      h('p.hint', 'Recording runs in real time and shows on screen. Keep this tab open until it finishes.'),
      st.progress != null
        ? h('div', h('progress', { max: 1, value: st.progress }), h('div.buttons', button('Cancel', () => st.abort?.abort(), 'danger')))
        : h('div.buttons', button('🎬 Export', () => startExport(eng, ui), 'primary'))),
    st.result ? section('Finished',
      h('p', `${st.result.name} · ${st.result.blob.size > 1e6 ? (st.result.blob.size / 1e6).toFixed(1) + ' MB' : Math.ceil(st.result.blob.size / 1e3) + ' KB'}`),
      h('div.buttons', button('Save / share…', () => shareFile(st.result.blob, st.result.name), 'primary')),
      h('p.hint', 'On iPhone choose “Save Video” to put it in Photos.')) : null,
    section('Lightmapping Link',
      h('p.hint', 'Open this site on the device plugged into the projector (laptop, TV browser, spare tablet) and choose “Receiver”. Type its code here.'),
      row('Receiver code', h('input.code', { inputMode: 'numeric', maxLength: 4, placeholder: '1234', value: st.code, onInput: (e) => { st.code = e.target.value.trim(); } })),
      h('div.buttons',
        st.result ? button(st.sendProgress != null ? `Sending ${Math.round(st.sendProgress * 100)}%` : '📤 Send show (loops on receiver)', async () => {
          if (st.code.length !== 4) return toast('Enter the 4-digit code shown on the receiver');
          try {
            st.sendProgress = 0; rerender();
            await st.link.sendFile(st.code, st.result.blob, st.result.name, (p) => { st.sendProgress = p; rerender(); });
            toast('Sent. The receiver is looping your show — you can close this app.');
          } catch (e) { toast(e.message || String(e)); }
          st.sendProgress = null; rerender();
        }, 'primary') : null,
        button(st.live ? '■ Stop live output' : '📡 Live output to receiver', async () => {
          if (st.live) { st.link.stopLive(); st.live = false; return rerender(); }
          if (st.code.length !== 4) return toast('Enter the 4-digit code shown on the receiver');
          try {
            const call = await st.link.streamLive(st.code, eng.canvas.captureStream(30));
            st.live = true;
            call.on('close', () => { st.live = false; rerender(); });
            toast('Streaming. Turn off outlines for a clean projection.');
          } catch (e) { toast(e.message || String(e)); }
          rerender();
        }))));
}

async function startExport(eng, ui) {
  const st = exportState;
  st.abort = new AbortController();
  st.progress = 0;
  st.result = null;
  ui.refresh();
  try {
    const { blob, ext } = await recordShow(eng, {
      resolution: st.resolution, fps: st.fps, includeAudio: st.audio, fallbackDuration: st.length, signal: st.abort.signal,
      onProgress: (p) => { st.progress = p; ui.root.querySelector('progress')?.setAttribute('value', p); },
    });
    st.result = { blob, name: `${eng.project.name.replace(/[^\w -]/g, '')} ${st.resolution}.${ext}` };
  } catch (e) {
    if (e.name !== 'AbortError') toast('Export failed: ' + e.message);
  }
  st.progress = null;
  ui.refresh();
}

// MARK: Settings

export function settingsPanel(eng, ui) {
  const p = eng.project, loud = () => eng.commit();
  const aspects = [[16 / 9, '16:9 (most projectors)'], [16 / 10, '16:10'], [4 / 3, '4:3'], [1, '1:1'], [9 / 16, '9:16 (portrait)']];
  const screenAspect = screen.width / screen.height;
  return h('div',
    section('Output',
      row('Aspect', select(p.outputAspect, [...aspects, [screenAspect, 'This screen']].map(([v, n]) => [v, n]), (v) => { p.outputAspect = +v; loud(); })),
      row('Show outlines', toggle(eng.showOutlines, (v) => { eng.showOutlines = v; loud(); })),
      h('p.hint', 'Projector: plug in with a USB-C or Lightning HDMI adapter, or AirPlay mirroring, then tap ⛶ for clean full-screen output. To keep controls on your phone, use Live output to a receiver (Export panel).')),
    tempoRow(eng),
    section('LFOs (beat-synced)', p.lfos.map((l, i) => row(`LFO ${i + 1}`, h('div.inline',
      select(l.shape, ['sine', 'triangle', 'saw', 'square', 'random'].map((s) => [s, s]), (v) => { l.shape = v; loud(); }),
      select(l.beats, [0.25, 0.5, 1, 2, 4, 8, 16, 32].map((b) => [b, b < 1 ? `1/${1 / b} beat` : `${b} beat${b > 1 ? 's' : ''}`]), (v) => { l.beats = +v; loud(); }))))),
    section('Envelopes', p.envelopes.map((e, i) => h('div.env',
      row(`Envelope ${i + 1}`, select(e.trigger, [['beat', 'Every beat'], ['bar', 'Every bar'], ['onset', 'Audio hit'], ['midi', 'MIDI note'], ['manual', 'Hit button']], (v) => { e.trigger = v; loud(); })),
      row('Attack', slider(e.attack, 0, 1, 0.01, (v) => { e.attack = v; eng.commit(true); })),
      row('Decay', slider(e.decay, 0.05, 3, 0.05, (v) => { e.decay = v; eng.commit(true); }))))),
    section('Audio', row('React to microphone', toggle(eng.micOn, (v) => eng.setMic(v))),
      meter('Level', 'audio.level'), meter('Bass', 'audio.bass', '#ff5252'), meter('Mid', 'audio.mid', '#ffd740'), meter('High', 'audio.high', '#40c4ff')),
    section('MIDI', eng.midi.supported
      ? [h('div.buttons', button(eng.midi.access ? `Connected: ${eng.midi.inputs.map((i) => i.name).join(', ') || 'no devices'}` : 'Enable MIDI', () => eng.midi.start().then(() => ui.refresh()).catch((e) => toast(e.message)))),
        row('Notes from C1 switch scenes', toggle(eng.midiScenes, (v) => { eng.midiScenes = v; })),
        eng.midiLearn ? h('p.warn', 'Listening — move a knob or fader…') : null]
      : h('p.hint', 'Web MIDI isn’t available in this browser (Safari on iPhone doesn’t support it). Use Chrome on Android, a laptop, or map with audio, LFOs and macros instead.')),
    section('Hand & face tracking',
      row('Track with front camera', toggle(eng.tracker.enabled, (v) => eng.setTracking(v))),
      h('p.hint', `Status: ${eng.tracker.status}`),
      meter('Hand X', 'handX', '#64ffda'), meter('Hand Y', 'handY', '#64ffda'), meter('Pinch', 'pinch', '#1de9b6'), meter('Face X', 'faceX', '#8c9eff'), meter('Mouth', 'mouthOpen', '#ff80ab')));
}
