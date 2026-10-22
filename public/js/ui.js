// Tiny DOM helpers and shared controls (no framework, no build step).

import { MOD_SOURCES, modName, needsAudio, needsTracking } from './model.js';

/** h('div.class#id', {props, onClick, style}, ...children) */
export function h(sel, props = {}, ...children) {
  if (props == null || typeof props !== 'object' || props instanceof Node || Array.isArray(props)) { children.unshift(props); props = {}; }
  const [, tag = 'div', rest = ''] = sel.match(/^([a-z0-9-]*)(.*)$/i);
  const el = document.createElement(tag || 'div');
  for (const part of rest.match(/[.#][^.#]+/g) || []) {
    if (part[0] === '.') el.classList.add(part.slice(1)); else el.id = part.slice(1);
  }
  for (const [k, v] of Object.entries(props)) {
    if (v == null || v === false) continue;
    if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
    else if (k === 'class') el.className += ' ' + v;
    else if (k in el && k !== 'list') el[k] = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  append(el, children);
  return el;
}

function append(el, children) {
  for (const c of children.flat(Infinity)) {
    if (c == null || c === false) continue;
    el.appendChild(c instanceof Node ? c : document.createTextNode(String(c)));
  }
}

export const clear = (el, ...children) => { el.replaceChildren(); append(el, children); return el; };

export function button(label, onClick, cls = '') {
  return h('button' + (cls ? '.' + cls.split(' ').join('.') : ''), { type: 'button', onClick }, label);
}

export function section(title, ...children) {
  return h('section.group', title ? h('h3', title) : null, ...children);
}

export function row(label, control) {
  return h('label.row', h('span.label', label), control);
}

/** Range slider. `onInput` fires continuously; `onChange` once when released. */
export function slider(value, min, max, step, onInput, onChange) {
  return h('input', {
    type: 'range', min, max, step: step ?? (max - min) / 200, value,
    onInput: (e) => onInput(+e.target.value),
    onChange: (e) => onChange?.(+e.target.value),
  });
}

export function toggle(checked, onChange) {
  return h('input.switch', { type: 'checkbox', checked, onChange: (e) => onChange(e.target.checked) });
}

export function select(value, options, onChange) {
  return h('select', { onChange: (e) => onChange(e.target.value) },
    options.map(([v, label]) => h('option', { value: v, selected: String(v) === String(value) }, label)));
}

export function numberInput(value, step, onChange, min = 0) {
  return h('input.num', { type: 'number', inputMode: 'decimal', value: +value.toFixed(2), step, min, onChange: (e) => onChange(+e.target.value) });
}

const toHex = (c) => '#' + c.map((x) => Math.round(Math.max(0, Math.min(1, x)) * 255).toString(16).padStart(2, '0')).join('');
const fromHex = (s) => [1, 3, 5].map((i) => parseInt(s.slice(i, i + 2), 16) / 255);

export function colorInput(rgb, onChange) {
  return h('input.color', { type: 'color', value: toHex(rgb), onInput: (e) => onChange(fromHex(e.target.value)) });
}

/**
 * Slider for a modulatable parameter, with a source picker (audio, LFOs, envelopes,
 * macros, tracking, MIDI learn) and a depth control.
 */
export function paramControl(engine, title, param, min, max, onEdit = () => {}) {
  const span = max - min;
  const valueText = h('span.value', param.base.toFixed(2));
  const sources = [['', '— none —'], ...MOD_SOURCES];
  if (param.mod?.src.startsWith('midi:')) sources.push([param.mod.src, modName(param.mod.src)]);
  if (engine.midi.supported) sources.push(['learn', 'MIDI learn (move a knob)…']);
  const modSel = select(param.mod?.src || '', sources, (v) => {
    if (v === 'learn') {
      engine.learnMIDI((src) => { param.mod = { src, depth: span }; onEdit(true); });
      modSel.value = param.mod?.src || '';
      return;
    }
    param.mod = v ? { src: v, depth: param.mod?.depth ?? span * 0.5 } : null;
    if (v && needsAudio(v) && !engine.micOn && !engine.project.timeline.audioAssetId) engine.setMic(true);
    if (v && needsTracking(v) && !engine.tracker.enabled) engine.setTracking(true);
    onEdit(true);
  });
  modSel.classList.add('mod');
  return h('div.param',
    h('div.param-head', h('span.label', title), valueText, modSel),
    slider(param.base, min, max, span / 200, (v) => { param.base = v; valueText.textContent = v.toFixed(2); onEdit(false); }, () => onEdit(false)),
    param.mod ? h('div.param-mod', h('span', '↳ ' + modName(param.mod.src) + ' depth'),
      slider(param.mod.depth, -span, span, span / 100, (v) => { param.mod.depth = v; onEdit(false); })) : null,
  );
}

/** Popover menu anchored to an element. items: [label, fn] or null for a divider. */
export function menu(anchor, items) {
  closeMenus();
  const r = anchor.getBoundingClientRect();
  const m = h('div.menu', items.map((it) => (it ? h('button', { type: 'button', onClick: () => { closeMenus(); it[1](); } }, it[0]) : h('hr'))));
  document.body.appendChild(m);
  const mw = m.offsetWidth, mh = m.offsetHeight;
  m.style.left = Math.max(8, Math.min(window.innerWidth - mw - 8, r.left)) + 'px';
  m.style.top = (r.bottom + mh + 8 < window.innerHeight ? r.bottom + 4 : Math.max(8, r.top - mh - 4)) + 'px';
  setTimeout(() => document.addEventListener('pointerdown', outside, { once: true }), 0);
  function outside(e) { if (!m.contains(e.target)) closeMenus(); else document.addEventListener('pointerdown', outside, { once: true }); }
}

export function closeMenus() { document.querySelectorAll('.menu').forEach((m) => m.remove()); }

/** Pick files with a hidden <input type=file>. */
export function pickFile(accept, multiple = false) {
  return new Promise((resolve) => {
    const input = h('input', { type: 'file', accept, multiple, style: { display: 'none' } });
    input.addEventListener('change', () => { resolve([...input.files]); input.remove(); });
    document.body.appendChild(input);
    input.click();
  });
}

export function modal(title, body, { onClose, wide = false } = {}) {
  const close = () => { overlay.remove(); onClose?.(); };
  const overlay = h('div.modal-overlay',
    h('div.modal' + (wide ? '.wide' : ''), h('header', h('h2', title), button('Done', close, 'primary')), h('div.modal-body', body)));
  document.body.appendChild(overlay);
  return { close, overlay };
}

export function toast(text, ms = 2600) {
  const t = h('div.toast', text);
  document.body.appendChild(t);
  setTimeout(() => t.remove(), ms);
}

export function meter(label, key, color = '#3ddc84') {
  return h('div.meter', h('span', label), h('div.bar', h('div.fill', { 'data-meter': key, style: { background: color } })));
}

/** Update every [data-meter] under `root` from the modulation context. */
export function updateMeters(root, ctx) {
  for (const el of root.querySelectorAll('[data-meter]')) {
    const k = el.dataset.meter;
    const v = k.startsWith('audio.') ? ctx.audio[k.slice(6)] : k.startsWith('lfo') ? ctx.lfo[+k[3]] : k.startsWith('env') ? ctx.env[+k[3]] : ctx.tracking[k];
    el.style.width = Math.max(0, Math.min(1, v ?? 0)) * 100 + '%';
  }
  for (const el of root.querySelectorAll('[data-beat]')) el.classList.toggle('on', ctx.beat % 1 < 0.2);
}
