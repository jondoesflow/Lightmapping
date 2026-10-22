// Warp geometry. Points are [x, y] in normalised output space (0..1, y down).
//
// A 2x2 mesh is a corner pin rendered with a true perspective homography, so straight
// lines stay straight on flat walls. Denser grids let edges bend around curved forms and
// are interpolated with a Catmull-Rom patch through the control points.

export function rectMesh(cx, cy, w, h) {
  return quadMesh([cx - w / 2, cy - h / 2], [cx + w / 2, cy - h / 2], [cx - w / 2, cy + h / 2], [cx + w / 2, cy + h / 2]);
}

export function quadMesh(tl, tr, bl, br) {
  return { cols: 2, rows: 2, points: [tl, tr, bl, br].map((p) => [p[0], p[1]]) };
}

const at = (m, c, r) => m.points[r * m.cols + c];

export function corners(m) {
  return { tl: at(m, 0, 0), tr: at(m, m.cols - 1, 0), bl: at(m, 0, m.rows - 1), br: at(m, m.cols - 1, m.rows - 1) };
}

// Maps the unit square (0,0),(1,0),(1,1),(0,1) to p0..p3.
// Heckbert, "Fundamentals of Texture Mapping and Image Warping", 1989.
export function squareToQuad(p0, p1, p2, p3) {
  const sx = p0[0] - p1[0] + p2[0] - p3[0], sy = p0[1] - p1[1] + p2[1] - p3[1];
  let a, b, c, d, e, f, g, h;
  if (Math.abs(sx) < 1e-9 && Math.abs(sy) < 1e-9) {
    a = p1[0] - p0[0]; b = p2[0] - p1[0]; c = p0[0];
    d = p1[1] - p0[1]; e = p2[1] - p1[1]; f = p0[1];
    g = 0; h = 0;
  } else {
    const dx1 = p1[0] - p2[0], dy1 = p1[1] - p2[1], dx2 = p3[0] - p2[0], dy2 = p3[1] - p2[1];
    const den = dx1 * dy2 - dx2 * dy1;
    g = (sx * dy2 - dx2 * sy) / den;
    h = (dx1 * sy - sx * dy1) / den;
    a = p1[0] - p0[0] + g * p1[0]; b = p3[0] - p0[0] + h * p3[0]; c = p0[0];
    d = p1[1] - p0[1] + g * p1[1]; e = p3[1] - p0[1] + h * p3[1]; f = p0[1];
  }
  return [a, b, c, d, e, f, g, h, 1]; // row-major 3x3
}

export function applyH(H, u, v) {
  const w = H[6] * u + H[7] * v + H[8];
  return [(H[0] * u + H[1] * v + H[2]) / w, (H[3] * u + H[4] * v + H[5]) / w];
}

export function invertH(m) {
  const [a, b, c, d, e, f, g, h, i] = m;
  const A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
  const det = a * A + b * B + c * C;
  return [A, -(b * i - c * h), b * f - c * e, B, a * i - c * g, -(a * f - c * d), C, -(a * h - b * g), a * e - b * d].map((x) => x / det);
}

function catmullRom(p0, p1, p2, p3, t) {
  const t2 = t * t, t3 = t2 * t;
  return [0, 1].map((k) => 0.5 * (2 * p1[k] + (p2[k] - p0[k]) * t + (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * t2 + (-p0[k] + 3 * p1[k] - 3 * p2[k] + p3[k]) * t3));
}

export function mapUV(m, u, v) {
  if (m.cols === 2 && m.rows === 2) {
    const c = corners(m);
    return applyH(squareToQuad(c.tl, c.tr, c.br, c.bl), u, v);
  }
  const fx = u * (m.cols - 1), fy = v * (m.rows - 1);
  const cx = Math.min(Math.max(Math.floor(fx), 0), m.cols - 2);
  const cy = Math.min(Math.max(Math.floor(fy), 0), m.rows - 2);
  const tx = fx - cx, ty = fy - cy;
  const p = (c, r) => {
    // Linear extrapolation past the border keeps edges straight-ish instead of clamping.
    const cc = Math.min(Math.max(c, 0), m.cols - 1), rr = Math.min(Math.max(r, 0), m.rows - 1);
    let q = at(m, cc, rr);
    if (c < 0) q = sub2(scale2(q, 2), at(m, 1, rr));
    if (c > m.cols - 1) q = sub2(scale2(q, 2), at(m, m.cols - 2, rr));
    if (r < 0) q = sub2(scale2(q, 2), at(m, cc, 1));
    if (r > m.rows - 1) q = sub2(scale2(q, 2), at(m, cc, m.rows - 2));
    return q;
  };
  const rows = [-1, 0, 1, 2].map((j) => catmullRom(p(cx - 1, cy + j), p(cx, cy + j), p(cx + 1, cy + j), p(cx + 2, cy + j), tx));
  return catmullRom(rows[0], rows[1], rows[2], rows[3], ty);
}

const sub2 = (a, b) => [a[0] - b[0], a[1] - b[1]];
const scale2 = (a, s) => [a[0] * s, a[1] * s];

/** Output point -> surface UV. Exact for corner pins, refined numerically for curved meshes. */
export function inverseMapUV(m, x, y) {
  const c = corners(m);
  let uv = applyH(invertH(squareToQuad(c.tl, c.tr, c.br, c.bl)), x, y);
  if (m.cols > 2 || m.rows > 2) {
    for (let i = 0; i < 8; i++) {
      const p = mapUV(m, uv[0], uv[1]), e = 1e-3;
      const fx = p[0] - x, fy = p[1] - y;
      const px = mapUV(m, uv[0] + e, uv[1]), py = mapUV(m, uv[0], uv[1] + e);
      const dx = [(px[0] - p[0]) / e, (px[1] - p[1]) / e], dy = [(py[0] - p[0]) / e, (py[1] - p[1]) / e];
      const det = dx[0] * dy[1] - dx[1] * dy[0];
      if (Math.abs(det) < 1e-10) break;
      uv = [uv[0] - (fx * dy[1] - fy * dy[0]) / det, uv[1] - (dx[0] * fy - dx[1] * fx) / det];
    }
  }
  return uv;
}

export function resample(m, n) {
  const pts = [];
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) pts.push(mapUV(m, c / (n - 1), r / (n - 1)));
  return { cols: n, rows: n, points: pts };
}

/** Interleaved [x, y, u, v] triangle list. */
export function tessellate(m, n = m.cols === 2 ? 24 : 40) {
  const grid = [];
  for (let j = 0; j <= n; j++) for (let i = 0; i <= n; i++) {
    const u = i / n, v = j / n, p = mapUV(m, u, v);
    grid.push([p[0], p[1], u, v]);
  }
  const out = new Float32Array(n * n * 6 * 4);
  let k = 0;
  for (let j = 0; j < n; j++) for (let i = 0; i < n; i++) {
    const a = grid[j * (n + 1) + i], b = grid[j * (n + 1) + i + 1], c = grid[(j + 1) * (n + 1) + i], d = grid[(j + 1) * (n + 1) + i + 1];
    for (const q of [a, b, c, b, d, c]) { out.set(q, k); k += 4; }
  }
  return out;
}

export function outline(m, n = 24) {
  const out = [];
  for (let i = 0; i < n; i++) out.push(mapUV(m, i / n, 0));
  for (let i = 0; i < n; i++) out.push(mapUV(m, 1, i / n));
  for (let i = 0; i < n; i++) out.push(mapUV(m, 1 - i / n, 1));
  for (let i = 0; i < n; i++) out.push(mapUV(m, 0, 1 - i / n));
  return out;
}

export function bounds(pts) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const [x, y] of pts) { x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y); }
  return { x0, y0, x1, y1 };
}

export function centroid(m) {
  const s = m.points.reduce((a, p) => [a[0] + p[0], a[1] + p[1]], [0, 0]);
  return [s[0] / m.points.length, s[1] / m.points.length];
}

export function polygonContains(poly, x, y) {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [ax, ay] = poly[i], [bx, by] = poly[j];
    if ((ay > y) !== (by > y) && x < ((bx - ax) * (y - ay)) / (by - ay) + ax) inside = !inside;
  }
  return inside;
}

export const meshContains = (m, x, y) => polygonContains(outline(m), x, y);

/** Ramer-Douglas-Peucker simplification for hand-drawn outlines. */
export function simplify(pts, tol) {
  if (pts.length <= 2) return pts;
  const a = pts[0], b = pts[pts.length - 1];
  let maxD = 0, idx = 0;
  for (let i = 1; i < pts.length - 1; i++) {
    const d = segDist(pts[i], a, b);
    if (d > maxD) { maxD = d; idx = i; }
  }
  if (maxD > tol) {
    const left = simplify(pts.slice(0, idx + 1), tol), right = simplify(pts.slice(idx), tol);
    return left.slice(0, -1).concat(right);
  }
  return [a, b];
}

function segDist(p, a, b) {
  const abx = b[0] - a[0], aby = b[1] - a[1], len2 = abx * abx + aby * aby;
  if (len2 === 0) return Math.hypot(p[0] - a[0], p[1] - a[1]);
  const t = Math.max(0, Math.min(1, ((p[0] - a[0]) * abx + (p[1] - a[1]) * aby) / len2));
  return Math.hypot(p[0] - (a[0] + abx * t), p[1] - (a[1] + aby * t));
}

export function translateMesh(m, dx, dy) {
  return { ...m, points: m.points.map(([x, y]) => [x + dx, y + dy]) };
}

export function scaleRotateMesh(m, s, angle, aspect) {
  const [cx, cy] = centroid(m), cs = Math.cos(angle), sn = Math.sin(angle);
  // Rotate in aspect-corrected space so shapes don't skew on a wide canvas.
  return {
    ...m,
    points: m.points.map(([x, y]) => {
      const dx = (x - cx) * aspect * s, dy = (y - cy) * s;
      return [cx + (dx * cs - dy * sn) / aspect, cy + dx * sn + dy * cs];
    }),
  };
}
