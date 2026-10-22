// Generative visuals (implemented in shaders.js, `kind` is the shader switch index)
// and the preset library built on them.

export const GENERATORS = [
  'Solid', 'Gradient', 'Plasma', 'Tunnel', 'Neon rings', 'VJ bars', 'Checker pulse', 'Spectrum',
  'Starfield', 'Noise flow', 'Edge glow', 'Scan sweep', 'Kaleido noise', 'Fire', 'Snowfall',
  'Twinkle lights', 'Lightning', 'Fog', 'Candy stripes', 'Hex grid', 'Depth contours', 'Depth scan',
  'Strobe', 'Ripple', 'Blinking eyes', 'Brick outline',
];
/** Generator index by lower-case name without spaces, e.g. G.neonrings. */
export const G = Object.fromEntries(GENERATORS.map((n, i) => [n.toLowerCase().replace(/[^a-z]/g, ''), i]));
/** Generators that read the surface mask (shape-aware) or depth map. */
export const SHAPE_AWARE = new Set([G.edgeglow, G.scansweep, G.depthcontours, G.depthscan]);

export const CATEGORIES = ['VJ loops', 'Ambient', 'Neon', 'Shape aware', 'Audio reactive', 'Halloween', 'Christmas'];

const rgb = (hex) => [((hex >> 16) & 255) / 255, ((hex >> 8) & 255) / 255, (hex & 255) / 255];
const P = (id, name, cat, kind, a, b, c, opts = {}) => ({ id, name, cat, kind, colors: [rgb(a), rgb(b), rgb(c)], speed: 1, scale: 1, intensity: 1, effects: [], audio: false, ...opts });

const base = [
  P('vj.tunnel.cyan', 'Hyper tunnel', 'VJ loops', G.tunnel, 0x00e5ff, 0xff00aa, 0x05001a, { speed: 1.4 }),
  P('vj.tunnel.gold', 'Gold warp', 'VJ loops', G.tunnel, 0xffc300, 0xff5733, 0x0b0500, { speed: 0.8, scale: 1.6 }),
  P('vj.bars.rgb', 'RGB bars', 'VJ loops', G.vjbars, 0xff0040, 0x00ff9c, 0x0030ff, { speed: 1.5 }),
  P('vj.bars.mono', 'Mono sweep', 'VJ loops', G.vjbars, 0xffffff, 0x808080, 0x000000, { speed: 2, effects: ['monochrome'] }),
  P('vj.checker', 'Checker pulse', 'VJ loops', G.checkerpulse, 0xffffff, 0x000000, 0xff0066),
  P('vj.kaleido', 'Kaleido bloom', 'VJ loops', G.kaleidonoise, 0xff3cac, 0x784ba0, 0x2b86c5, { effects: ['kaleidoscope'] }),
  P('vj.hex', 'Hex circuit', 'VJ loops', G.hexgrid, 0x39ff14, 0x00b3ff, 0x000a05),
  P('vj.strobe', 'White strobe', 'VJ loops', G.strobe, 0xffffff, 0x000000, 0x000000, { speed: 2 }),
  P('vj.ripple', 'Acid ripple', 'VJ loops', G.ripple, 0xc6ff00, 0xff00e1, 0x0a0014),
  P('vj.plasma.tile', 'Plasma tiles', 'VJ loops', G.plasma, 0xff6ec7, 0x7df9ff, 0x1a0033, { effects: ['tile'] }),

  P('amb.sunset', 'Sunset gradient', 'Ambient', G.gradient, 0xff7e5f, 0xfeb47b, 0x6a3093, { speed: 0.3 }),
  P('amb.ocean', 'Ocean gradient', 'Ambient', G.gradient, 0x00c9ff, 0x92fe9d, 0x003049, { speed: 0.2 }),
  P('amb.plasma', 'Soft plasma', 'Ambient', G.plasma, 0xa18cd1, 0xfbc2eb, 0x1b1b3a, { speed: 0.4 }),
  P('amb.flow', 'Ink flow', 'Ambient', G.noiseflow, 0x2c3e50, 0x4ca1af, 0x0f2027, { speed: 0.3, scale: 1.5 }),
  P('amb.aurora', 'Aurora', 'Ambient', G.noiseflow, 0x00ff87, 0x60efff, 0x020024, { speed: 0.5, scale: 0.7 }),
  P('amb.stars', 'Deep space', 'Ambient', G.starfield, 0xffffff, 0x8ec5fc, 0x000005, { speed: 0.5 }),
  P('amb.warm', 'Warm glow', 'Ambient', G.solid, 0xffb347, 0xffcc33, 0x000000, { speed: 0.2 }),
  P('amb.fog', 'Blue mist', 'Ambient', G.fog, 0x9cc9ff, 0x3a6ea5, 0x020814, { speed: 0.3 }),

  P('neon.rings.pink', 'Neon rings', 'Neon', G.neonrings, 0xff2079, 0x00f0ff, 0x05000a),
  P('neon.rings.green', 'Toxic rings', 'Neon', G.neonrings, 0x39ff14, 0xffff00, 0x000500, { speed: 1.6 }),
  P('neon.edge.blue', 'Neon outline', 'Neon', G.edgeglow, 0x00e5ff, 0x7c4dff, 0x000000),
  P('neon.edge.pink', 'Hot outline', 'Neon', G.edgeglow, 0xff1493, 0xffd700, 0x000000, { speed: 1.5 }),
  P('neon.bricks', 'Facade lines', 'Neon', G.brickoutline, 0x00ffff, 0xff00ff, 0x000000),
  P('neon.grid', 'Synth grid', 'Neon', G.hexgrid, 0xff00ff, 0x00ffff, 0x0d0221, { scale: 1.6 }),

  P('shape.scan', 'Laser scan', 'Shape aware', G.scansweep, 0xff0033, 0xffffff, 0x000000),
  P('shape.scan.green', 'Matrix scan', 'Shape aware', G.scansweep, 0x00ff41, 0xb3ffb3, 0x000000, { speed: 0.6 }),
  P('shape.edge.white', 'Traced edge', 'Shape aware', G.edgeglow, 0xffffff, 0x99ccff, 0x000000, { speed: 0.7 }),
  P('shape.depth.contours', 'Topographic', 'Shape aware', G.depthcontours, 0x00ffd5, 0xff6b00, 0x000000),
  P('shape.depth.scan', 'Depth sweep', 'Shape aware', G.depthscan, 0xffffff, 0x00aaff, 0x000000),
  P('shape.depth.heat', 'Heat relief', 'Shape aware', G.depthcontours, 0xffea00, 0xff0055, 0x10002b, { scale: 2 }),

  P('audio.spectrum', 'Spectrum', 'Audio reactive', G.spectrum, 0x00ffa3, 0xdc1fff, 0x000000, { audio: true }),
  P('audio.spectrum.fire', 'Fire spectrum', 'Audio reactive', G.spectrum, 0xffdd00, 0xff2200, 0x0a0000, { audio: true }),
  P('audio.rings', 'Bass rings', 'Audio reactive', G.neonrings, 0xff0090, 0x00d4ff, 0x000000, { audio: true }),
  P('audio.tunnel', 'Kick tunnel', 'Audio reactive', G.tunnel, 0xffffff, 0xff3b3b, 0x000000, { speed: 1.2, audio: true }),
  P('audio.strobe', 'Beat strobe', 'Audio reactive', G.strobe, 0xffffff, 0x000000, 0x000000, { audio: true }),
  P('audio.edge', 'Pulse outline', 'Audio reactive', G.edgeglow, 0xff00ff, 0x00ffff, 0x000000, { audio: true }),

  P('hw.fire', "Jack-o'-lantern flame", 'Halloween', G.fire, 0xffb000, 0xff4500, 0x1a0500),
  P('hw.greenfire', 'Witch fire', 'Halloween', G.fire, 0xb4ff00, 0x2eb82e, 0x001a05, { speed: 1.3 }),
  P('hw.fog', 'Graveyard fog', 'Halloween', G.fog, 0xc8d6c0, 0x56705a, 0x050805, { speed: 0.4 }),
  P('hw.purplefog', 'Haunted haze', 'Halloween', G.fog, 0xb388ff, 0x4a148c, 0x05000a, { speed: 0.5 }),
  P('hw.lightning', 'Storm lightning', 'Halloween', G.lightning, 0xe0e8ff, 0x6a7fdb, 0x02030a),
  P('hw.eyes', 'Watching eyes', 'Halloween', G.blinkingeyes, 0xff2200, 0xffaa00, 0x000000),
  P('hw.eyes.green', 'Creature eyes', 'Halloween', G.blinkingeyes, 0x66ff00, 0xffff66, 0x000000, { scale: 1.5 }),
  P('hw.blood', 'Blood drip', 'Halloween', G.noiseflow, 0xb00000, 0x4a0000, 0x0a0000, { speed: 0.6, scale: 2 }),
  P('hw.pumpkin', 'Pumpkin plasma', 'Halloween', G.plasma, 0xff7518, 0x6b2d5c, 0x0a0005, { speed: 0.7 }),
  P('hw.slime', 'Slime ripple', 'Halloween', G.ripple, 0x7fff00, 0x006400, 0x000a00),
  P('hw.outline', 'Spooky outline', 'Halloween', G.edgeglow, 0xff6a00, 0x8a2be2, 0x000000),
  P('hw.scan', 'Ghost scan', 'Halloween', G.scansweep, 0xe6fffa, 0x00ffc8, 0x000000, { speed: 0.5 }),
  P('hw.strobe', 'Thunder flash', 'Halloween', G.lightning, 0xffffff, 0xa0a0ff, 0x000000, { speed: 2 }),
  P('hw.candle', 'Candle flicker', 'Halloween', G.fire, 0xffe29a, 0xff8c00, 0x000000, { speed: 0.5, scale: 0.6 }),
  P('hw.spectral', 'Spectral sweep', 'Halloween', G.depthscan, 0x9dfff9, 0x6a00ff, 0x000000),

  P('xm.snow', 'Gentle snow', 'Christmas', G.snowfall, 0xffffff, 0xcfe8ff, 0x061229, { speed: 0.6 }),
  P('xm.blizzard', 'Blizzard', 'Christmas', G.snowfall, 0xffffff, 0xffffff, 0x0a1a33, { speed: 2, scale: 1.8 }),
  P('xm.lights', 'Twinkle lights', 'Christmas', G.twinklelights, 0xff3030, 0x30ff60, 0x000000),
  P('xm.warmlights', 'Warm fairy lights', 'Christmas', G.twinklelights, 0xffd27f, 0xfff1c1, 0x080400, { scale: 1.6 }),
  P('xm.candy', 'Candy cane', 'Christmas', G.candystripes, 0xe00000, 0xffffff, 0xffffff),
  P('xm.candy.green', 'Peppermint', 'Christmas', G.candystripes, 0x0b8a3e, 0xffffff, 0xffffff, { speed: 0.6 }),
  P('xm.stars', 'Starry night', 'Christmas', G.starfield, 0xfff6d5, 0xffd700, 0x020a1f, { speed: 0.2 }),
  P('xm.aurora', 'North Pole aurora', 'Christmas', G.noiseflow, 0x00ff9c, 0xb967ff, 0x000814, { speed: 0.4 }),
  P('xm.gradient', 'Red & green', 'Christmas', G.gradient, 0xc0392b, 0x27ae60, 0x0b3d20, { speed: 0.3 }),
  P('xm.outline', 'Gold outline', 'Christmas', G.edgeglow, 0xffd700, 0xffffff, 0x000000, { speed: 0.6 }),
  P('xm.fire', 'Yule log', 'Christmas', G.fire, 0xffc04d, 0xd9480f, 0x0d0300, { speed: 0.8 }),
  P('xm.bricks', 'Gingerbread house', 'Christmas', G.brickoutline, 0xffffff, 0xff4040, 0x3b1f0e),
  P('xm.checker', 'Present wrap', 'Christmas', G.checkerpulse, 0xc0392b, 0x1e8449, 0xf1c40f, { speed: 0.5 }),
];

// Palette x pattern variations so every holiday look is available on the common generators.
function variations(cat, prefix, palettes, kinds) {
  return palettes.flatMap(([pname, a, b, c]) =>
    kinds.map(([kind, kname]) => P(`${prefix}.${pname}.${kname}`.toLowerCase(), `${pname} ${kname}`, cat, kind, a, b, c, { speed: 0.8 })));
}

export const PRESETS = [
  ...base,
  ...variations('Halloween', 'hwv',
    [['Pumpkin', 0xff7518, 0x8a2be2, 0x050005], ['Swamp', 0x7cfc00, 0x2f4f2f, 0x000000], ['Vampire', 0xc00000, 0x2a0000, 0x000000], ['Bone', 0xf5f5dc, 0x8b8378, 0x050505]],
    [[G.kaleidonoise, 'vortex'], [G.tunnel, 'portal'], [G.neonrings, 'rings']]),
  ...variations('Christmas', 'xmv',
    [['Holly', 0xd42426, 0x165b33, 0x020a04], ['Gold', 0xffd700, 0xffffff, 0x1a1000], ['Frost', 0xe0ffff, 0x5dade2, 0x020a1a], ['Sugarplum', 0xff69b4, 0xba55d3, 0x0a000a]],
    [[G.plasma, 'glow'], [G.tunnel, 'tunnel'], [G.neonrings, 'rings']]),
];

export const presetById = (id) => PRESETS.find((p) => p.id === id);
