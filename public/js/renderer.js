// WebGL2 renderer. Per frame:
//   1. generators render into per-layer textures (mask/depth aware)
//   2. each surface's layer stack is composited into its content texture (effects, blend)
//   3. every surface is drawn as a warped mesh onto the output (mask, feather)
//   4. optional scene transition and alignment outlines

import * as S from './shaders.js';
import { tessellate, outline, mapUV, bounds } from './geometry.js';
import { pv } from './model.js';

const BLENDS = {
  normal: (gl) => gl.blendFuncSeparate(gl.ONE, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA),
  add: (gl) => gl.blendFuncSeparate(gl.ONE, gl.ONE, gl.ONE, gl.ONE_MINUS_SRC_ALPHA),
  screen: (gl) => gl.blendFuncSeparate(gl.ONE, gl.ONE_MINUS_SRC_COLOR, gl.ONE, gl.ONE_MINUS_SRC_ALPHA),
  multiply: (gl) => gl.blendFuncSeparate(gl.DST_COLOR, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA),
};

export class Renderer {
  /**
   * @param canvas output canvas
   * @param providers { source(layer, ctx) -> {tex,w,h}|null, mask(surface, w, h) -> tex|null, depth(surface) -> tex|null }
   */
  constructor(canvas, providers) {
    const gl = canvas.getContext('webgl2', { alpha: false, antialias: true, premultipliedAlpha: true, preserveDrawingBuffer: false, powerPreference: 'high-performance' });
    if (!gl) throw new Error('WebGL2 is not available in this browser.');
    this.gl = gl;
    this.canvas = canvas;
    this.providers = providers;
    this.maxContent = Math.min(1024, gl.getParameter(gl.MAX_TEXTURE_SIZE));
    this.frame = 0;
    this.targets = new Map(); // key -> {fb, tex, w, h, used}
    this.meshes = new Map(); // surfaceId -> {key, buf, count, used}

    const fs = S.FULLSCREEN_VS;
    this.pGen = this.program(fs, S.GENERATOR_FS);
    this.pLayer = this.program(fs, S.LAYER_FS);
    this.pTrans = this.program(fs, S.TRANSITION_FS);
    this.pSurf = this.program(S.SURFACE_VS, S.SURFACE_FS);
    this.pLine = this.program(S.LINE_VS, S.LINE_FS);
    this.vao = gl.createVertexArray();
    this.lineBuf = gl.createBuffer();
    this.white = this.texture(1, 1, new Uint8Array([255, 255, 255, 255]));
  }

  program(vsSrc, fsSrc) {
    const gl = this.gl;
    const compile = (type, src) => {
      const s = gl.createShader(type);
      gl.shaderSource(s, src);
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s) + '\n' + src.split('\n').slice(0, 3).join('\n'));
      return s;
    };
    const p = gl.createProgram();
    gl.attachShader(p, compile(gl.VERTEX_SHADER, vsSrc));
    gl.attachShader(p, compile(gl.FRAGMENT_SHADER, fsSrc));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    const u = {};
    const n = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS);
    for (let i = 0; i < n; i++) { const info = gl.getActiveUniform(p, i); u[info.name] = gl.getUniformLocation(p, info.name); }
    return { p, u, aPos: gl.getAttribLocation(p, 'aPos') };
  }

  texture(w, h, data = null) {
    const gl = this.gl, t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, data);
    for (const [k, v] of [[gl.TEXTURE_MIN_FILTER, gl.LINEAR], [gl.TEXTURE_MAG_FILTER, gl.LINEAR], [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE]]) gl.texParameteri(gl.TEXTURE_2D, k, v);
    return t;
  }

  target(key, w, h) {
    let t = this.targets.get(key);
    if (!t || t.w !== w || t.h !== h) {
      const gl = this.gl;
      if (t) { gl.deleteTexture(t.tex); gl.deleteFramebuffer(t.fb); }
      const tex = this.texture(w, h), fb = gl.createFramebuffer();
      gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
      t = { tex, fb, w, h };
      this.targets.set(key, t);
    }
    t.used = this.frame;
    return t;
  }

  bindTarget(t) {
    const gl = this.gl;
    gl.bindFramebuffer(gl.FRAMEBUFFER, t ? t.fb : null);
    gl.viewport(0, 0, t ? t.w : gl.drawingBufferWidth, t ? t.h : gl.drawingBufferHeight);
    return t ? -1 : 1; // uYSign
  }

  /** Content texture size for a surface: its on-output aspect, long edge capped. */
  contentSize(surface) {
    const b = bounds(surface.mesh.points), W = this.gl.drawingBufferWidth, H = this.gl.drawingBufferHeight;
    const w = Math.max((b.x1 - b.x0) * W, 1), h = Math.max((b.y1 - b.y0) * H, 1);
    const s = this.maxContent / Math.max(w, h);
    // 32px steps so dragging handles doesn't reallocate every frame.
    const q = (v) => Math.max(64, Math.round((v * s) / 32) * 32);
    return [q(w), q(h)];
  }

  render(state) {
    const gl = this.gl;
    this.frame++;
    gl.bindVertexArray(this.vao);
    const W = gl.drawingBufferWidth, H = gl.drawingBufferHeight;
    if (state.incoming && state.incoming.style !== 'cut') {
      const a = this.target('sceneA', W, H), b = this.target('sceneB', W, H);
      this.renderScene(state.scene, state, a);
      this.renderScene(state.incoming.scene, state, b);
      const ys = this.bindTarget(null);
      gl.disable(gl.BLEND);
      const P = this.pTrans;
      gl.useProgram(P.p);
      gl.uniform1f(P.u.uYSign, ys);
      gl.uniform1f(P.u.uProgress, state.incoming.progress);
      gl.uniform1i(P.u.uStyle, state.incoming.style === 'dissolve' ? 2 : 1);
      this.bindTex(P.u.uFrom, 0, a.tex);
      this.bindTex(P.u.uTo, 1, b.tex);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    } else {
      this.renderScene(state.incoming ? state.incoming.scene : state.scene, state, null);
    }
    if (state.showOutlines) this.drawOutlines(state);
    if (this.frame % 120 === 0) this.evict();
  }

  bindTex(loc, unit, tex) {
    const gl = this.gl;
    gl.activeTexture(gl.TEXTURE0 + unit);
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.uniform1i(loc, unit);
  }

  renderScene(scene, state, out) {
    const gl = this.gl, ctx = state.ctx;
    const draws = [];
    for (const surface of state.project.surfaces) {
      if (!surface.visible) continue;
      const layers = (scene.content[surface.id]?.layers || []).filter((l) => l.visible);
      if (!layers.length) continue;
      const [w, h] = this.contentSize(surface);
      const mask = this.providers.mask(surface, Math.min(w, 512), Math.min(h, 512));
      const depth = this.providers.depth(surface);

      // 1. Sources (generators render now).
      const srcs = [];
      for (const layer of layers) {
        if (layer.source.type === 'generator') {
          const t = this.target('gen:' + layer.id, w, h);
          this.renderGenerator(layer, t, mask, depth, ctx);
          srcs.push([layer, { tex: t.tex, w, h }]);
        } else {
          const s = this.providers.source(layer, ctx);
          if (s) srcs.push([layer, s]);
        }
      }
      if (!srcs.length) continue;

      // 2. Composite the layer stack.
      const content = this.target(`content:${scene.id}:${surface.id}`, w, h);
      const ys = this.bindTarget(content);
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.enable(gl.BLEND);
      const P = this.pLayer;
      gl.useProgram(P.p);
      gl.uniform1f(P.u.uYSign, ys);
      for (const [layer, src] of srcs) {
        (BLENDS[layer.blend] || BLENDS.normal)(gl);
        const fx = { kaleidoscope: 0, tile: 0, slide: 0, rotate: 0, zoom: 1, blur: 0, monochrome: 0, invert: 0, colorCycle: 0 };
        for (const e of layer.effects) {
          if (!e.on) continue;
          const v = pv(e.amount, ctx);
          if (e.kind === 'zoom') fx.zoom *= Math.max(v, 0.01);
          else if (['slide', 'rotate', 'colorCycle'].includes(e.kind)) fx[e.kind] += v;
          else fx[e.kind] = Math.max(fx[e.kind], v);
        }
        gl.uniform4fv(P.u.uCrop, layer.crop);
        gl.uniform2f(P.u.uSrcSize, src.w, src.h);
        gl.uniform2f(P.u.uDstSize, w, h);
        gl.uniform1f(P.u.uKaleido, fx.kaleidoscope);
        gl.uniform1f(P.u.uTile, fx.tile);
        gl.uniform1f(P.u.uSlide, fx.slide);
        gl.uniform1f(P.u.uRotate, fx.rotate);
        gl.uniform1f(P.u.uZoom, fx.zoom);
        gl.uniform1f(P.u.uBlur, fx.blur);
        gl.uniform1f(P.u.uMono, fx.monochrome);
        gl.uniform1f(P.u.uInvert, fx.invert);
        gl.uniform1f(P.u.uHue, fx.colorCycle);
        gl.uniform1f(P.u.uOpacity, pv(layer.opacity, ctx));
        gl.uniform1f(P.u.uTime, ctx.time % 3600);
        gl.uniform1i(P.u.uFit, { fill: 0, fit: 1, stretch: 2 }[layer.fit] ?? 0);
        this.bindTex(P.u.uSrc, 0, src.tex);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
      }
      draws.push([surface, content, mask]);
    }

    // 3. Warp every surface onto the output.
    const ys = this.bindTarget(out);
    gl.clearColor(0, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.enable(gl.BLEND);
    BLENDS.normal(gl);
    const P = this.pSurf;
    gl.useProgram(P.p);
    gl.uniform1f(P.u.uYSign, ys);
    for (const [surface, content, mask] of draws) {
      const m = this.mesh(surface);
      gl.bindBuffer(gl.ARRAY_BUFFER, m.buf);
      gl.enableVertexAttribArray(P.aPos);
      gl.vertexAttribPointer(P.aPos, 4, gl.FLOAT, false, 0, 0);
      gl.uniform1f(P.u.uOpacity, surface.opacity);
      gl.uniform1f(P.u.uFeather, surface.feather);
      gl.uniform1f(P.u.uHasMask, mask ? 1 : 0);
      this.bindTex(P.u.uContent, 0, content.tex);
      this.bindTex(P.u.uMask, 1, mask || this.white);
      gl.drawArrays(gl.TRIANGLES, 0, m.count);
    }
    gl.disableVertexAttribArray(P.aPos);
  }

  renderGenerator(layer, t, mask, depth, ctx) {
    const gl = this.gl, P = this.pGen, g = layer.gen;
    const ys = this.bindTarget(t);
    gl.disable(gl.BLEND);
    gl.useProgram(P.p);
    gl.uniform1f(P.u.uYSign, ys);
    gl.uniform3fv(P.u.uA, g.a);
    gl.uniform3fv(P.u.uB, g.b);
    gl.uniform3fv(P.u.uC, g.c);
    gl.uniform2f(P.u.uRes, t.w, t.h);
    gl.uniform1f(P.u.uTime, ctx.time % 3600);
    gl.uniform1f(P.u.uSpeed, pv(g.speed, ctx));
    gl.uniform1f(P.u.uScale, pv(g.scale, ctx));
    gl.uniform1f(P.u.uIntensity, pv(g.intensity, ctx));
    gl.uniform1f(P.u.uLevel, ctx.audio.level);
    gl.uniform1f(P.u.uBass, ctx.audio.bass);
    gl.uniform1f(P.u.uMid, ctx.audio.mid);
    gl.uniform1f(P.u.uHigh, ctx.audio.high);
    gl.uniform1f(P.u.uSeed, g.seed);
    gl.uniform1i(P.u.uKind, layer.source.kind);
    gl.uniform1f(P.u.uHasMask, mask ? 1 : 0);
    gl.uniform1f(P.u.uHasDepth, depth ? 1 : 0);
    this.bindTex(P.u.uMask, 0, mask || this.white);
    this.bindTex(P.u.uDepth, 1, depth || this.white);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  mesh(surface) {
    const key = JSON.stringify(surface.mesh);
    let m = this.meshes.get(surface.id);
    if (!m || m.key !== key) {
      const gl = this.gl, data = tessellate(surface.mesh);
      const buf = m?.buf || gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      gl.bufferData(gl.ARRAY_BUFFER, data, gl.DYNAMIC_DRAW);
      m = { key, buf, count: data.length / 4 };
      this.meshes.set(surface.id, m);
    }
    m.used = this.frame;
    return m;
  }

  drawOutlines(state) {
    const gl = this.gl, P = this.pLine;
    this.bindTarget(null);
    gl.enable(gl.BLEND);
    BLENDS.normal(gl);
    gl.useProgram(P.p);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.lineBuf);
    gl.enableVertexAttribArray(P.aPos);
    gl.vertexAttribPointer(P.aPos, 2, gl.FLOAT, false, 0, 0);
    for (const s of state.project.surfaces) {
      if (!s.visible) continue;
      const sel = s.id === state.selectedId;
      const pts = [];
      const o = outline(s.mesh);
      o.forEach((p, i) => pts.push(...p, ...o[(i + 1) % o.length]));
      if (sel) {
        // Interior grid lines help line up with physical edges.
        for (let k = 1; k < 8; k++) for (let i = 0; i < 16; i++) {
          const f = k / 8, a = i / 16, b = (i + 1) / 16;
          pts.push(...mapUV(s.mesh, a, f), ...mapUV(s.mesh, b, f), ...mapUV(s.mesh, f, a), ...mapUV(s.mesh, f, b));
        }
      }
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(pts), gl.STREAM_DRAW);
      gl.uniform4fv(P.u.uColor, sel ? [1, 0.8, 0, 1] : [0.3, 0.8, 1, 0.8]);
      gl.drawArrays(gl.LINES, 0, pts.length / 2);
    }
    gl.disableVertexAttribArray(P.aPos);
  }

  evict() {
    const gl = this.gl, cutoff = this.frame - 240;
    for (const [k, t] of this.targets) if (t.used < cutoff) { gl.deleteTexture(t.tex); gl.deleteFramebuffer(t.fb); this.targets.delete(k); }
    for (const [k, m] of this.meshes) if (m.used < cutoff) { gl.deleteBuffer(m.buf); this.meshes.delete(k); }
  }
}
