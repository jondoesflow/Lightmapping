// Touch overlay on top of the output canvas: tap to select a surface, drag corner/grid
// handles, drag the centre handle to move, pinch/rotate with two fingers, and draw
// outlines (new surfaces) or cutouts (holes in the selected surface).

import { centroid, meshContains, simplify, bounds, rectMesh, inverseMapUV, scaleRotateMesh, translateMesh } from './geometry.js';

const NS = 'http://www.w3.org/2000/svg';
const svgEl = (tag, attrs = {}) => { const e = document.createElementNS(NS, tag); for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v); return e; };

export class Stage {
  constructor(engine, canvas, svg, onToolDone) {
    this.engine = engine;
    this.canvas = canvas;
    this.svg = svg;
    this.tool = 'select'; // 'select' | 'outline' | 'cutout'
    this.onToolDone = onToolDone;
    this.pointers = new Map();
    this.drag = null;
    this.stroke = [];
    svg.addEventListener('pointerdown', (e) => this.down(e));
    svg.addEventListener('pointermove', (e) => this.move(e));
    svg.addEventListener('pointerup', (e) => this.up(e));
    svg.addEventListener('pointercancel', (e) => this.up(e));
    new ResizeObserver(() => this.render()).observe(canvas);
  }

  setTool(t) { this.tool = t; this.stroke = []; this.render(); }

  rect() { return this.canvas.getBoundingClientRect(); }

  toOut(e) {
    const r = this.rect();
    return [(e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height];
  }

  /** Redraw handles. Cheap; called after every edit. */
  render() {
    const r = this.rect(), sr = this.svg.getBoundingClientRect();
    const ox = r.left - sr.left, oy = r.top - sr.top;
    const P = ([x, y]) => [ox + x * r.width, oy + y * r.height];
    this.svg.replaceChildren();
    const s = this.engine.selected;
    if (this.tool !== 'select') {
      if (this.stroke.length > 1) {
        this.svg.appendChild(svgEl('polyline', {
          points: this.stroke.map((p) => P(p).join(',')).join(' '),
          class: this.tool === 'cutout' ? 'stroke cut' : 'stroke',
        }));
      }
      return;
    }
    if (!s || s.locked) return;
    const m = s.mesh;
    m.points.forEach((p, i) => {
      const c = i % m.cols, row = Math.floor(i / m.cols);
      const corner = (c === 0 || c === m.cols - 1) && (row === 0 || row === m.rows - 1);
      const [x, y] = P(p);
      this.svg.appendChild(svgEl('circle', { cx: x, cy: y, r: 22, class: 'hit', 'data-handle': i }));
      this.svg.appendChild(svgEl('circle', { cx: x, cy: y, r: corner ? 11 : 8, class: corner ? 'handle corner' : 'handle' }));
    });
    const [cx, cy] = P(centroid(m));
    this.svg.appendChild(svgEl('circle', { cx, cy, r: 18, class: 'move', 'data-move': 1 }));
    const arrows = svgEl('text', { x: cx, y: cy + 6, class: 'move-icon' });
    arrows.textContent = '✥';
    this.svg.appendChild(arrows);
  }

  down(e) {
    this.svg.setPointerCapture(e.pointerId);
    const p = this.toOut(e);
    this.pointers.set(e.pointerId, p);
    const eng = this.engine, s = eng.selected;

    if (this.tool !== 'select') { this.stroke = [p]; return; }

    if (this.pointers.size === 2 && s && !s.locked) {
      // Second finger: switch to pinch/rotate for the selected surface.
      const [a, b] = this.aspectPoints();
      this.drag = { type: 'pinch', start: s.mesh, d0: dist(a, b), a0: angle(a, b) };
      return;
    }
    const handle = e.target.dataset?.handle, mv = e.target.dataset?.move;
    if (s && !s.locked && handle != null) {
      const i = +handle;
      this.drag = { type: 'handle', i, start: s.mesh, p0: p, linked: this.linkedCorners(s, s.mesh.points[i]) };
    } else if (s && !s.locked && mv) {
      this.drag = { type: 'move', start: s.mesh, p0: p };
    } else {
      this.drag = { type: 'tap', p0: p };
    }
  }

  move(e) {
    if (!this.pointers.has(e.pointerId)) return;
    const p = this.toOut(e);
    this.pointers.set(e.pointerId, p);
    const d = this.drag, eng = this.engine, s = eng.selected;
    if (this.tool !== 'select') {
      if (this.stroke.length) { this.stroke.push(p); this.render(); }
      return;
    }
    if (!d || !s) return;
    if (d.type === 'handle') {
      const q = [d.start.points[d.i][0] + p[0] - d.p0[0], d.start.points[d.i][1] + p[1] - d.p0[1]];
      eng.updateSurface(s.id, (x) => { x.mesh = { ...x.mesh, points: x.mesh.points.map((pt, i) => (i === d.i ? q : pt)) }; }, true);
      for (const l of d.linked) eng.updateSurface(l.id, (x) => { x.mesh = { ...x.mesh, points: x.mesh.points.map((pt, i) => (i === l.i ? q : pt)) }; }, true);
      this.render();
    } else if (d.type === 'move') {
      eng.updateSurface(s.id, (x) => { x.mesh = translateMesh(d.start, p[0] - d.p0[0], p[1] - d.p0[1]); }, true);
      this.render();
    } else if (d.type === 'pinch' && this.pointers.size >= 2) {
      const [a, b] = this.aspectPoints();
      const mesh = scaleRotateMesh(d.start, dist(a, b) / d.d0, angle(a, b) - d.a0, eng.project.outputAspect);
      eng.updateSurface(s.id, (x) => { x.mesh = mesh; }, true);
      this.render();
    }
  }

  up(e) {
    const d = this.drag, p = this.pointers.get(e.pointerId);
    this.pointers.delete(e.pointerId);
    if (this.tool !== 'select') { if (this.pointers.size === 0) this.finishStroke(); return; }
    if (d?.type === 'tap' && p && dist(p, d.p0) < 0.01) {
      // Tap selects the top-most surface under the finger.
      const hit = [...this.engine.project.surfaces].reverse().find((s) => s.visible && meshContains(s.mesh, p[0], p[1]));
      this.engine.select(hit?.id || null);
      this.render();
    }
    if (this.pointers.size === 0) {
      if (d && d.type !== 'tap') this.engine.commit();
      this.drag = null;
    }
  }

  /** First two touch points in aspect-corrected space, so rotation isn't skewed. */
  aspectPoints() {
    const k = this.engine.project.outputAspect;
    return [...this.pointers.values()].slice(0, 2).map(([x, y]) => [x * k, y]);
  }

  /** Box faces share corners: dragging one drags the matching corner of sibling faces. */
  linkedCorners(s, pt) {
    if (!s.groupId) return [];
    const out = [];
    for (const o of this.engine.project.surfaces) {
      if (o.groupId !== s.groupId || o.id === s.id) continue;
      o.mesh.points.forEach((q, i) => { if (dist(q, pt) < 0.004) out.push({ id: o.id, i }); });
    }
    return out;
  }

  finishStroke() {
    const pts = simplify(this.stroke, 0.002), eng = this.engine;
    this.stroke = [];
    if (pts.length >= 3) {
      if (this.tool === 'outline') {
        // New surface: bounding quad plus the outline as a mask in its UV space.
        const b = bounds(pts), w = Math.max(b.x1 - b.x0, 0.01), hh = Math.max(b.y1 - b.y0, 0.01);
        const uv = pts.map(([x, y]) => [(x - b.x0) / w, (y - b.y0) / hh]);
        eng.addSurface({ type: 'freehand', points: uv }, { name: `Outline ${eng.project.surfaces.length + 1}`, mesh: rectMesh(b.x0 + w / 2, b.y0 + hh / 2, w, hh) });
      } else if (this.tool === 'cutout' && eng.selected) {
        // Stored in surface UV space so the hole follows the surface when it's re-mapped.
        const s = eng.selected;
        eng.updateSurface(s.id, (x) => x.cutouts.push(pts.map(([px, py]) => inverseMapUV(s.mesh, px, py))));
      }
    }
    this.tool = 'select';
    this.render();
    this.onToolDone?.();
  }
}

const dist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);
const angle = (a, b) => Math.atan2(b[1] - a[1], b[0] - a[0]);
