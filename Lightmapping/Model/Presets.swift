import Foundation
import simd

/// Generative visuals implemented in `Shaders.metal` (`generatorFragment`).
/// Raw values are passed to the shader, so never reorder existing cases.
enum GeneratorKind: Int, Codable, CaseIterable, Identifiable {
    case solid = 0
    case gradient
    case plasma
    case tunnel
    case neonRings
    case bars
    case checkerPulse
    case spectrum
    case starfield
    case noiseFlow
    case edgeGlow
    case scanSweep
    case kaleidoNoise
    case fire
    case snowfall
    case twinkleLights
    case lightning
    case fog
    case candyStripes
    case hexGrid
    case depthContours
    case depthScan
    case strobe
    case ripple
    case blinkingEyes
    case brickOutline

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .solid: return "Solid"
        case .gradient: return "Gradient"
        case .plasma: return "Plasma"
        case .tunnel: return "Tunnel"
        case .neonRings: return "Neon rings"
        case .bars: return "VJ bars"
        case .checkerPulse: return "Checker pulse"
        case .spectrum: return "Spectrum"
        case .starfield: return "Starfield"
        case .noiseFlow: return "Noise flow"
        case .edgeGlow: return "Edge glow"
        case .scanSweep: return "Scan sweep"
        case .kaleidoNoise: return "Kaleido noise"
        case .fire: return "Fire"
        case .snowfall: return "Snowfall"
        case .twinkleLights: return "Twinkle lights"
        case .lightning: return "Lightning"
        case .fog: return "Fog"
        case .candyStripes: return "Candy stripes"
        case .hexGrid: return "Hex grid"
        case .depthContours: return "Depth contours"
        case .depthScan: return "Depth scan"
        case .strobe: return "Strobe"
        case .ripple: return "Ripple"
        case .blinkingEyes: return "Blinking eyes"
        case .brickOutline: return "Brick outline"
        }
    }

    /// Generators that read the surface mask (shape-aware) or depth map.
    var isShapeAware: Bool { [.edgeGlow, .scanSweep, .depthContours, .depthScan].contains(self) }
}

enum PresetCategory: String, CaseIterable, Identifiable {
    case vj = "VJ loops"
    case ambient = "Ambient"
    case neon = "Neon"
    case shapeAware = "Shape aware"
    case audio = "Audio reactive"
    case halloween = "Halloween"
    case christmas = "Christmas"
    var id: String { rawValue }
}

struct VisualPreset: Identifiable {
    let id: String
    let name: String
    let category: PresetCategory
    let kind: GeneratorKind
    let colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    var speed: Float = 1
    var scale: Float = 1
    var intensity: Float = 1
    var effects: [EffectKind] = []
    var audioReactive = false

    func makeLayer() -> Layer {
        var layer = Layer(name: name, source: .generator(kind))
        layer.generator.colorA = colors.0
        layer.generator.colorB = colors.1
        layer.generator.colorC = colors.2
        layer.generator.speed = Param(speed)
        layer.generator.scale = Param(scale)
        layer.generator.intensity = Param(intensity, modulation: audioReactive ? Modulation(source: .audioLevel, depth: 1.2) : nil)
        // Stable across launches (String.hashValue is randomised per process).
        layer.generator.seed = Float(id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 10_007 }) / 10_007
        layer.effects = effects.map { Effect(kind: $0) }
        return layer
    }
}

private func rgb(_ hex: UInt32) -> SIMD4<Float> {
    SIMD4(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, 1)
}

enum PresetLibrary {
    static let all: [VisualPreset] = vj + ambient + neon + shapeAware + audio + halloween + halloweenVariations + christmas + christmasVariations

    static func presets(in category: PresetCategory) -> [VisualPreset] { all.filter { $0.category == category } }

    static let vj: [VisualPreset] = [
        VisualPreset(id: "vj.tunnel.cyan", name: "Hyper tunnel", category: .vj, kind: .tunnel, colors: (rgb(0x00E5FF), rgb(0xFF00AA), rgb(0x05001A)), speed: 1.4),
        VisualPreset(id: "vj.tunnel.gold", name: "Gold warp", category: .vj, kind: .tunnel, colors: (rgb(0xFFC300), rgb(0xFF5733), rgb(0x0B0500)), speed: 0.8, scale: 1.6),
        VisualPreset(id: "vj.bars.rgb", name: "RGB bars", category: .vj, kind: .bars, colors: (rgb(0xFF0040), rgb(0x00FF9C), rgb(0x0030FF)), speed: 1.5),
        VisualPreset(id: "vj.bars.mono", name: "Mono sweep", category: .vj, kind: .bars, colors: (rgb(0xFFFFFF), rgb(0x808080), rgb(0x000000)), speed: 2, effects: [.monochrome]),
        VisualPreset(id: "vj.checker", name: "Checker pulse", category: .vj, kind: .checkerPulse, colors: (rgb(0xFFFFFF), rgb(0x000000), rgb(0xFF0066))),
        VisualPreset(id: "vj.kaleido", name: "Kaleido bloom", category: .vj, kind: .kaleidoNoise, colors: (rgb(0xFF3CAC), rgb(0x784BA0), rgb(0x2B86C5)), effects: [.kaleidoscope]),
        VisualPreset(id: "vj.hex", name: "Hex circuit", category: .vj, kind: .hexGrid, colors: (rgb(0x39FF14), rgb(0x00B3FF), rgb(0x000A05))),
        VisualPreset(id: "vj.strobe", name: "White strobe", category: .vj, kind: .strobe, colors: (rgb(0xFFFFFF), rgb(0x000000), rgb(0x000000)), speed: 2),
        VisualPreset(id: "vj.ripple", name: "Acid ripple", category: .vj, kind: .ripple, colors: (rgb(0xC6FF00), rgb(0xFF00E1), rgb(0x0A0014))),
        VisualPreset(id: "vj.plasma.tile", name: "Plasma tiles", category: .vj, kind: .plasma, colors: (rgb(0xFF6EC7), rgb(0x7DF9FF), rgb(0x1A0033)), effects: [.tile]),
    ]

    static let ambient: [VisualPreset] = [
        VisualPreset(id: "amb.sunset", name: "Sunset gradient", category: .ambient, kind: .gradient, colors: (rgb(0xFF7E5F), rgb(0xFEB47B), rgb(0x6A3093)), speed: 0.3),
        VisualPreset(id: "amb.ocean", name: "Ocean gradient", category: .ambient, kind: .gradient, colors: (rgb(0x00C9FF), rgb(0x92FE9D), rgb(0x003049)), speed: 0.2),
        VisualPreset(id: "amb.plasma", name: "Soft plasma", category: .ambient, kind: .plasma, colors: (rgb(0xA18CD1), rgb(0xFBC2EB), rgb(0x1B1B3A)), speed: 0.4),
        VisualPreset(id: "amb.flow", name: "Ink flow", category: .ambient, kind: .noiseFlow, colors: (rgb(0x2C3E50), rgb(0x4CA1AF), rgb(0x0F2027)), speed: 0.3, scale: 1.5),
        VisualPreset(id: "amb.aurora", name: "Aurora", category: .ambient, kind: .noiseFlow, colors: (rgb(0x00FF87), rgb(0x60EFFF), rgb(0x020024)), speed: 0.5, scale: 0.7),
        VisualPreset(id: "amb.stars", name: "Deep space", category: .ambient, kind: .starfield, colors: (rgb(0xFFFFFF), rgb(0x8EC5FC), rgb(0x000005)), speed: 0.5),
        VisualPreset(id: "amb.warm", name: "Warm glow", category: .ambient, kind: .solid, colors: (rgb(0xFFB347), rgb(0xFFCC33), rgb(0x000000)), speed: 0.2),
        VisualPreset(id: "amb.fog", name: "Blue mist", category: .ambient, kind: .fog, colors: (rgb(0x9CC9FF), rgb(0x3A6EA5), rgb(0x020814)), speed: 0.3),
    ]

    static let neon: [VisualPreset] = [
        VisualPreset(id: "neon.rings.pink", name: "Neon rings", category: .neon, kind: .neonRings, colors: (rgb(0xFF2079), rgb(0x00F0FF), rgb(0x05000A))),
        VisualPreset(id: "neon.rings.green", name: "Toxic rings", category: .neon, kind: .neonRings, colors: (rgb(0x39FF14), rgb(0xFFFF00), rgb(0x000500)), speed: 1.6),
        VisualPreset(id: "neon.edge.blue", name: "Neon outline", category: .neon, kind: .edgeGlow, colors: (rgb(0x00E5FF), rgb(0x7C4DFF), rgb(0x000000))),
        VisualPreset(id: "neon.edge.pink", name: "Hot outline", category: .neon, kind: .edgeGlow, colors: (rgb(0xFF1493), rgb(0xFFD700), rgb(0x000000)), speed: 1.5),
        VisualPreset(id: "neon.bricks", name: "Facade lines", category: .neon, kind: .brickOutline, colors: (rgb(0x00FFFF), rgb(0xFF00FF), rgb(0x000000))),
        VisualPreset(id: "neon.grid", name: "Synth grid", category: .neon, kind: .hexGrid, colors: (rgb(0xFF00FF), rgb(0x00FFFF), rgb(0x0D0221)), scale: 1.6),
    ]

    static let shapeAware: [VisualPreset] = [
        VisualPreset(id: "shape.scan", name: "Laser scan", category: .shapeAware, kind: .scanSweep, colors: (rgb(0xFF0033), rgb(0xFFFFFF), rgb(0x000000))),
        VisualPreset(id: "shape.scan.green", name: "Matrix scan", category: .shapeAware, kind: .scanSweep, colors: (rgb(0x00FF41), rgb(0xB3FFB3), rgb(0x000000)), speed: 0.6),
        VisualPreset(id: "shape.edge.white", name: "Traced edge", category: .shapeAware, kind: .edgeGlow, colors: (rgb(0xFFFFFF), rgb(0x99CCFF), rgb(0x000000)), speed: 0.7),
        VisualPreset(id: "shape.depth.contours", name: "Topographic", category: .shapeAware, kind: .depthContours, colors: (rgb(0x00FFD5), rgb(0xFF6B00), rgb(0x000000))),
        VisualPreset(id: "shape.depth.scan", name: "Depth sweep", category: .shapeAware, kind: .depthScan, colors: (rgb(0xFFFFFF), rgb(0x00AAFF), rgb(0x000000))),
        VisualPreset(id: "shape.depth.heat", name: "Heat relief", category: .shapeAware, kind: .depthContours, colors: (rgb(0xFFEA00), rgb(0xFF0055), rgb(0x10002B)), scale: 2),
    ]

    static let audio: [VisualPreset] = [
        VisualPreset(id: "audio.spectrum", name: "Spectrum", category: .audio, kind: .spectrum, colors: (rgb(0x00FFA3), rgb(0xDC1FFF), rgb(0x000000)), audioReactive: true),
        VisualPreset(id: "audio.spectrum.fire", name: "Fire spectrum", category: .audio, kind: .spectrum, colors: (rgb(0xFFDD00), rgb(0xFF2200), rgb(0x0A0000)), audioReactive: true),
        VisualPreset(id: "audio.rings", name: "Bass rings", category: .audio, kind: .neonRings, colors: (rgb(0xFF0090), rgb(0x00D4FF), rgb(0x000000)), audioReactive: true),
        VisualPreset(id: "audio.tunnel", name: "Kick tunnel", category: .audio, kind: .tunnel, colors: (rgb(0xFFFFFF), rgb(0xFF3B3B), rgb(0x000000)), speed: 1.2, audioReactive: true),
        VisualPreset(id: "audio.strobe", name: "Beat strobe", category: .audio, kind: .strobe, colors: (rgb(0xFFFFFF), rgb(0x000000), rgb(0x000000)), audioReactive: true),
        VisualPreset(id: "audio.edge", name: "Pulse outline", category: .audio, kind: .edgeGlow, colors: (rgb(0xFF00FF), rgb(0x00FFFF), rgb(0x000000)), audioReactive: true),
    ]

    static let halloween: [VisualPreset] = [
        VisualPreset(id: "hw.fire", name: "Jack-o'-lantern flame", category: .halloween, kind: .fire, colors: (rgb(0xFFB000), rgb(0xFF4500), rgb(0x1A0500))),
        VisualPreset(id: "hw.greenfire", name: "Witch fire", category: .halloween, kind: .fire, colors: (rgb(0xB4FF00), rgb(0x2EB82E), rgb(0x001A05)), speed: 1.3),
        VisualPreset(id: "hw.fog", name: "Graveyard fog", category: .halloween, kind: .fog, colors: (rgb(0xC8D6C0), rgb(0x56705A), rgb(0x050805)), speed: 0.4),
        VisualPreset(id: "hw.purplefog", name: "Haunted haze", category: .halloween, kind: .fog, colors: (rgb(0xB388FF), rgb(0x4A148C), rgb(0x05000A)), speed: 0.5),
        VisualPreset(id: "hw.lightning", name: "Storm lightning", category: .halloween, kind: .lightning, colors: (rgb(0xE0E8FF), rgb(0x6A7FDB), rgb(0x02030A))),
        VisualPreset(id: "hw.eyes", name: "Watching eyes", category: .halloween, kind: .blinkingEyes, colors: (rgb(0xFF2200), rgb(0xFFAA00), rgb(0x000000))),
        VisualPreset(id: "hw.eyes.green", name: "Creature eyes", category: .halloween, kind: .blinkingEyes, colors: (rgb(0x66FF00), rgb(0xFFFF66), rgb(0x000000)), scale: 1.5),
        VisualPreset(id: "hw.blood", name: "Blood drip", category: .halloween, kind: .noiseFlow, colors: (rgb(0xB00000), rgb(0x4A0000), rgb(0x0A0000)), speed: 0.6, scale: 2),
        VisualPreset(id: "hw.pumpkin", name: "Pumpkin plasma", category: .halloween, kind: .plasma, colors: (rgb(0xFF7518), rgb(0x6B2D5C), rgb(0x0A0005)), speed: 0.7),
        VisualPreset(id: "hw.slime", name: "Slime ripple", category: .halloween, kind: .ripple, colors: (rgb(0x7FFF00), rgb(0x006400), rgb(0x000A00))),
        VisualPreset(id: "hw.outline", name: "Spooky outline", category: .halloween, kind: .edgeGlow, colors: (rgb(0xFF6A00), rgb(0x8A2BE2), rgb(0x000000))),
        VisualPreset(id: "hw.scan", name: "Ghost scan", category: .halloween, kind: .scanSweep, colors: (rgb(0xE6FFFA), rgb(0x00FFC8), rgb(0x000000)), speed: 0.5),
        VisualPreset(id: "hw.strobe", name: "Thunder flash", category: .halloween, kind: .lightning, colors: (rgb(0xFFFFFF), rgb(0xA0A0FF), rgb(0x000000)), speed: 2),
        VisualPreset(id: "hw.candle", name: "Candle flicker", category: .halloween, kind: .fire, colors: (rgb(0xFFE29A), rgb(0xFF8C00), rgb(0x000000)), speed: 0.5, scale: 0.6),
        VisualPreset(id: "hw.spectral", name: "Spectral sweep", category: .halloween, kind: .depthScan, colors: (rgb(0x9DFFF9), rgb(0x6A00FF), rgb(0x000000))),
    ]

    static let christmas: [VisualPreset] = [
        VisualPreset(id: "xm.snow", name: "Gentle snow", category: .christmas, kind: .snowfall, colors: (rgb(0xFFFFFF), rgb(0xCFE8FF), rgb(0x061229)), speed: 0.6),
        VisualPreset(id: "xm.blizzard", name: "Blizzard", category: .christmas, kind: .snowfall, colors: (rgb(0xFFFFFF), rgb(0xFFFFFF), rgb(0x0A1A33)), speed: 2, scale: 1.8),
        VisualPreset(id: "xm.lights", name: "Twinkle lights", category: .christmas, kind: .twinkleLights, colors: (rgb(0xFF3030), rgb(0x30FF60), rgb(0x000000))),
        VisualPreset(id: "xm.warmlights", name: "Warm fairy lights", category: .christmas, kind: .twinkleLights, colors: (rgb(0xFFD27F), rgb(0xFFF1C1), rgb(0x080400)), scale: 1.6),
        VisualPreset(id: "xm.candy", name: "Candy cane", category: .christmas, kind: .candyStripes, colors: (rgb(0xE00000), rgb(0xFFFFFF), rgb(0xFFFFFF))),
        VisualPreset(id: "xm.candy.green", name: "Peppermint", category: .christmas, kind: .candyStripes, colors: (rgb(0x0B8A3E), rgb(0xFFFFFF), rgb(0xFFFFFF)), speed: 0.6),
        VisualPreset(id: "xm.stars", name: "Starry night", category: .christmas, kind: .starfield, colors: (rgb(0xFFF6D5), rgb(0xFFD700), rgb(0x020A1F)), speed: 0.2),
        VisualPreset(id: "xm.aurora", name: "North Pole aurora", category: .christmas, kind: .noiseFlow, colors: (rgb(0x00FF9C), rgb(0xB967FF), rgb(0x000814)), speed: 0.4),
        VisualPreset(id: "xm.gradient", name: "Red & green", category: .christmas, kind: .gradient, colors: (rgb(0xC0392B), rgb(0x27AE60), rgb(0x0B3D20)), speed: 0.3),
        VisualPreset(id: "xm.outline", name: "Gold outline", category: .christmas, kind: .edgeGlow, colors: (rgb(0xFFD700), rgb(0xFFFFFF), rgb(0x000000)), speed: 0.6),
        VisualPreset(id: "xm.fire", name: "Yule log", category: .christmas, kind: .fire, colors: (rgb(0xFFC04D), rgb(0xD9480F), rgb(0x0D0300)), speed: 0.8),
        VisualPreset(id: "xm.bricks", name: "Gingerbread house", category: .christmas, kind: .brickOutline, colors: (rgb(0xFFFFFF), rgb(0xFF4040), rgb(0x3B1F0E))),
        VisualPreset(id: "xm.checker", name: "Present wrap", category: .christmas, kind: .checkerPulse, colors: (rgb(0xC0392B), rgb(0x1E8449), rgb(0xF1C40F)), speed: 0.5),
    ]

    // Palette x pattern variations so every holiday look is available on the common generators.
    static let halloweenVariations: [VisualPreset] = variations(
        category: .halloween, prefix: "hwv",
        palettes: [
            ("Pumpkin", (rgb(0xFF7518), rgb(0x8A2BE2), rgb(0x050005))),
            ("Swamp", (rgb(0x7CFC00), rgb(0x2F4F2F), rgb(0x000000))),
            ("Vampire", (rgb(0xC00000), rgb(0x2A0000), rgb(0x000000))),
            ("Bone", (rgb(0xF5F5DC), rgb(0x8B8378), rgb(0x050505))),
        ],
        kinds: [(.kaleidoNoise, "vortex"), (.tunnel, "portal"), (.neonRings, "rings")])

    static let christmasVariations: [VisualPreset] = variations(
        category: .christmas, prefix: "xmv",
        palettes: [
            ("Holly", (rgb(0xD42426), rgb(0x165B33), rgb(0x020A04))),
            ("Gold", (rgb(0xFFD700), rgb(0xFFFFFF), rgb(0x1A1000))),
            ("Frost", (rgb(0xE0FFFF), rgb(0x5DADE2), rgb(0x020A1A))),
            ("Sugarplum", (rgb(0xFF69B4), rgb(0xBA55D3), rgb(0x0A000A))),
        ],
        kinds: [(.plasma, "glow"), (.tunnel, "tunnel"), (.neonRings, "rings")])

    private static func variations(
        category: PresetCategory, prefix: String,
        palettes: [(String, (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>))],
        kinds: [(GeneratorKind, String)]
    ) -> [VisualPreset] {
        palettes.flatMap { palette in
            kinds.map { kind in
                VisualPreset(id: "\(prefix).\(palette.0).\(kind.1)".lowercased(), name: "\(palette.0) \(kind.1)",
                             category: category, kind: kind.0, colors: palette.1, speed: 0.8)
            }
        }
    }
}
