// Audio input for reactive visuals: the microphone, or the timeline's audio track while a
// show plays. Bands are auto-gained against a slowly decaying peak so visuals respond the
// same in a quiet room or at a loud party.

export class AudioEngine {
  constructor() {
    this.ctx = null;
    this.mic = null; // { stream, analyser }
    this.track = null; // { el, analyser, node }
    this.recordDest = null;
    this.peaks = [1e-4, 1e-4, 1e-4, 1e-4];
    this.bands = { level: 0, bass: 0, mid: 0, high: 0, onset: false };
    this.bassAvg = 0;
    this.lastOnset = -1;
    this.lastTime = performance.now();
  }

  context() {
    this.ctx ??= new (window.AudioContext || window.webkitAudioContext)();
    if (this.ctx.state === 'suspended') this.ctx.resume();
    return this.ctx;
  }

  analyser() {
    const a = this.context().createAnalyser();
    a.fftSize = 2048;
    a.smoothingTimeConstant = 0.3;
    return a;
  }

  async startMic() {
    if (this.mic) return;
    const stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
    const analyser = this.analyser();
    this.context().createMediaStreamSource(stream).connect(analyser);
    this.mic = { stream, analyser };
  }

  stopMic() {
    this.mic?.stream.getTracks().forEach((t) => t.stop());
    this.mic = null;
  }

  /** Destination that export recordings take their audio from. */
  recordingStream() {
    this.recordDest ??= this.context().createMediaStreamDestination();
    return this.recordDest.stream;
  }

  /** Load the timeline audio track (an object URL). */
  setTrack(url) {
    if (this.track?.url === url) return this.track.el;
    this.track?.el.pause();
    if (!url) { this.track = null; return null; }
    const el = new Audio();
    el.src = url;
    el.preload = 'auto';
    el.playsInline = true;
    const ctx = this.context();
    const node = ctx.createMediaElementSource(el);
    const analyser = this.analyser();
    node.connect(analyser);
    node.connect(ctx.destination);
    node.connect(this.recordDest ?? (this.recordDest = ctx.createMediaStreamDestination()));
    this.track = { url, el, analyser, node };
    return el;
  }

  get trackPlaying() { return !!this.track && !this.track.el.paused; }

  /** Analyse the current input. Call once per frame. */
  read(now) {
    const a = this.trackPlaying ? this.track.analyser : this.mic?.analyser;
    const dt = Math.min(0.1, (now - this.lastTime) / 1000);
    this.lastTime = now;
    if (!a) { this.bands = { level: 0, bass: 0, mid: 0, high: 0, onset: false }; return this.bands; }

    const freq = (this._f ??= new Float32Array(a.frequencyBinCount));
    const time = (this._t ??= new Float32Array(a.fftSize));
    a.getFloatFrequencyData(freq);
    a.getFloatTimeDomainData(time);
    let rms = 0;
    for (const s of time) rms += s * s;
    rms = Math.sqrt(rms / time.length);
    const binHz = a.context.sampleRate / a.fftSize;
    const band = (lo, hi) => {
      const i0 = Math.max(1, Math.floor(lo / binHz)), i1 = Math.min(freq.length - 1, Math.floor(hi / binHz));
      let s = 0;
      for (let i = i0; i <= i1; i++) s += Math.pow(10, freq[i] / 20);
      return s / Math.max(1, i1 - i0 + 1);
    };
    const raw = [rms, band(20, 250), band(250, 2000), band(2000, 8000)];

    // Auto-gain: peaks fall by half over ~4 s.
    const decay = Math.pow(0.5, dt / 4);
    const norm = raw.map((r, i) => {
      this.peaks[i] = Math.max(r, this.peaks[i] * decay, 1e-4);
      return r < 1e-4 ? 0 : Math.min(1, r / this.peaks[i]);
    });
    // Fast attack, slower release.
    const follow = (o, n) => o + (n - o) * (n > o ? 0.6 : Math.min(1, dt * 6));
    const b = this.bands;
    const nowS = now / 1000;
    this.bassAvg += (norm[1] - this.bassAvg) * Math.min(1, dt * 2);
    const onset = norm[1] > 0.6 && norm[1] > this.bassAvg * 1.4 && nowS - this.lastOnset > 0.15;
    if (onset) this.lastOnset = nowS;
    this.bands = { level: follow(b.level, norm[0]), bass: follow(b.bass, norm[1]), mid: follow(b.mid, norm[2]), high: follow(b.high, norm[3]), onset };
    return this.bands;
  }
}

/** Web MIDI (Chrome, Edge, Android; not Safari on iPhone). */
export class MIDI {
  constructor() {
    this.supported = !!navigator.requestMIDIAccess;
    this.cc = {};
    this.notes = [];
    this.lastCC = null;
    this.inputs = [];
  }

  async start() {
    if (!this.supported || this.access) return;
    this.access = await navigator.requestMIDIAccess();
    const hook = () => {
      this.inputs = [...this.access.inputs.values()];
      for (const input of this.inputs) input.onmidimessage = (e) => this.handle(e.data);
    };
    hook();
    this.access.onstatechange = hook;
  }

  handle([status, d1, d2]) {
    const type = status & 0xf0, ch = status & 0x0f;
    if (type === 0xb0) { this.cc[ch * 128 + d1] = d2 / 127; this.lastCC = [ch, d1]; }
    if (type === 0x90 && d2 > 0) this.notes.push([ch, d1]);
  }

  drainNotes() { const n = this.notes; this.notes = []; return n; }
  takeLastCC() { const v = this.lastCC; this.lastCC = null; return v; }
}
