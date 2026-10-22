// Unit tests for the pure logic: run with `npm test` (Node 18+, no dependencies).
import test from 'node:test';
import assert from 'node:assert/strict';
import { squareToQuad, applyH, invertH, mapUV, rectMesh, quadMesh, resample, tessellate, meshContains, simplify, inverseMapUV } from '../public/js/geometry.js';
import { lfoValue, envValue, pv, emptyContext, laneValue, clipAt, timelineDuration, demoProject, layerFromPreset } from '../public/js/model.js';
import { PRESETS, GENERATORS, CATEGORIES } from '../public/js/presets.js';

const close = (a, b, eps = 1e-6) => assert.ok(Math.abs(a - b) < eps, `${a} ≉ ${b}`);
const close2 = (p, q, eps = 1e-6) => { close(p[0], q[0], eps); close(p[1], q[1], eps); };

test('homography maps the unit square onto the quad', () => {
  const tl = [0.1, 0.2], tr = [0.8, 0.1], br = [0.9, 0.95], bl = [0.05, 0.7];
  const H = squareToQuad(tl, tr, br, bl);
  close2(applyH(H, 0, 0), tl); close2(applyH(H, 1, 0), tr); close2(applyH(H, 1, 1), br); close2(applyH(H, 0, 1), bl);
  close2(applyH(invertH(H), ...applyH(H, 0.3, 0.6)), [0.3, 0.6]);
});

test('perspective keeps straight lines straight', () => {
  const m = quadMesh([0.1, 0.1], [0.9, 0.3], [0.1, 0.9], [0.9, 0.7]);
  const [a, b, c] = [mapUV(m, 0, 0.5), mapUV(m, 0.5, 0.5), mapUV(m, 1, 0.5)];
  close((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]), 0, 1e-9);
});

test('resampled curved mesh preserves shape and passes through control points', () => {
  const m = rectMesh(0.5, 0.5, 0.4, 0.4), d = resample(m, 4);
  assert.equal(d.points.length, 16);
  for (const [u, v] of [[0, 0], [1, 1], [0.5, 0.5], [1 / 3, 2 / 3]]) close2(mapUV(d, u, v), mapUV(m, u, v), 1e-9);
  close2(mapUV(d, 1 / 3, 0), d.points[1]);
});

test('inverse mapping round-trips on curved meshes', () => {
  const d = resample(quadMesh([0.1, 0.1], [0.9, 0.2], [0.15, 0.9], [0.85, 0.8]), 3);
  d.points[4] = [d.points[4][0] + 0.05, d.points[4][1] - 0.04]; // bend the middle
  const uv = inverseMapUV(d, ...mapUV(d, 0.37, 0.61));
  close2(uv, [0.37, 0.61], 1e-4);
});

test('tessellation, hit-testing, simplification', () => {
  assert.equal(tessellate(rectMesh(0.5, 0.5, 1, 1), 8).length, 8 * 8 * 6 * 4);
  const m = rectMesh(0.5, 0.5, 0.2, 0.2);
  assert.ok(meshContains(m, 0.5, 0.5));
  assert.ok(!meshContains(m, 0.9, 0.9));
  assert.equal(simplify(Array.from({ length: 21 }, (_, i) => [i / 20, 0.5]), 0.001).length, 2);
});

test('LFOs, envelopes and parameter modulation', () => {
  close(lfoValue({ shape: 'sine', beats: 1 }, 0), 0);
  close(lfoValue({ shape: 'sine', beats: 1 }, 0.5), 1);
  close(lfoValue({ shape: 'triangle', beats: 2 }, 1), 1);
  close(lfoValue({ shape: 'saw', beats: 4 }, 1), 0.25);
  assert.equal(lfoValue({ shape: 'random', beats: 1 }, 3.1), lfoValue({ shape: 'random', beats: 1 }, 3.9));
  const env = { attack: 0.1, decay: 1 };
  assert.equal(envValue(env, null), 0);
  close(envValue(env, 0.05), 0.5);
  assert.ok(envValue(env, 1.1) < 0.1);
  const ctx = emptyContext();
  ctx.audio.bass = 0.5; ctx.lfo = [1];
  close(pv({ base: 1, mod: { src: 'audioBass', depth: 2 } }, ctx), 2);
  close(pv({ base: 1, mod: { src: 'lfo0', depth: 0.5 } }, ctx), 1.5); // bipolar
});

test('timeline lookup and automation', () => {
  const tl = { clips: [{ id: 'a', sceneId: 'A', start: 0, duration: 5 }, { id: 'b', sceneId: 'B', start: 5, duration: 5 }] };
  assert.equal(clipAt(tl, 2).sceneId, 'A');
  assert.equal(clipAt(tl, 5).sceneId, 'B');
  assert.equal(clipAt(tl, 11), null);
  assert.equal(timelineDuration(tl), 10);
  const lane = { keys: [{ t: 0, v: 0 }, { t: 10, v: 1 }] };
  close(laneValue(lane, 5), 0.5);
  assert.equal(laneValue(lane, 20), 1);
});

test('preset library', () => {
  assert.equal(new Set(PRESETS.map((p) => p.id)).size, PRESETS.length);
  assert.ok(PRESETS.filter((p) => p.cat === 'Halloween' || p.cat === 'Christmas').length > 50);
  for (const p of PRESETS) {
    assert.ok(Number.isInteger(p.kind) && p.kind >= 0 && p.kind < GENERATORS.length, p.id);
    assert.ok(CATEGORIES.includes(p.cat), p.id);
  }
  assert.equal(layerFromPreset(PRESETS[0]).gen.seed, layerFromPreset(PRESETS[0]).gen.seed);
});

test('demo project is consistent', () => {
  const p = demoProject();
  for (const s of p.scenes) for (const id of Object.keys(s.content)) assert.ok(p.surfaces.some((x) => x.id === id));
  for (const c of p.timeline.clips) assert.ok(p.scenes.some((s) => s.id === c.sceneId));
  assert.ok(JSON.parse(JSON.stringify(p)));
});
