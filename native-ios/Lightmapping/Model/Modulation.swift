import Foundation

/// A float parameter that can be animated by a modulation source.
struct Param: Codable, Equatable {
    var base: Float
    var modulation: Modulation?

    init(_ base: Float, modulation: Modulation? = nil) {
        self.base = base
        self.modulation = modulation
    }

    func value(_ ctx: ModulationContext) -> Float {
        guard let m = modulation else { return base }
        let v = ctx.value(of: m.source)
        // Bipolar sources swing around the base value; unipolar ones push it upward.
        let s = m.source.isBipolar ? (v * 2 - 1) : v
        return base + s * m.depth
    }
}

struct Modulation: Codable, Equatable {
    var source: ModSource
    var depth: Float
}

enum ModSource: Codable, Hashable {
    case audioLevel, audioBass, audioMid, audioHigh
    case lfo(Int)
    case envelope(Int)
    case macro(Int)
    case midiCC(channel: Int, cc: Int)
    case handX, handY, pinch
    case faceX, faceY, mouthOpen

    var isBipolar: Bool {
        switch self {
        case .lfo, .handX, .handY, .faceX, .faceY: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .audioLevel: return "Audio level"
        case .audioBass: return "Audio bass"
        case .audioMid: return "Audio mid"
        case .audioHigh: return "Audio high"
        case .lfo(let i): return "LFO \(i + 1)"
        case .envelope(let i): return "Envelope \(i + 1)"
        case .macro(let i): return "Macro \(i + 1)"
        case .midiCC(let ch, let cc): return "MIDI ch\(ch + 1) CC\(cc)"
        case .handX: return "Hand X"
        case .handY: return "Hand Y"
        case .pinch: return "Pinch"
        case .faceX: return "Face X"
        case .faceY: return "Face Y"
        case .mouthOpen: return "Mouth open"
        }
    }

    static let pickerSources: [ModSource] = [
        .audioLevel, .audioBass, .audioMid, .audioHigh,
        .lfo(0), .lfo(1), .lfo(2), .lfo(3),
        .envelope(0), .envelope(1),
        .macro(0), .macro(1), .macro(2), .macro(3),
        .handX, .handY, .pinch, .faceX, .faceY, .mouthOpen,
    ]
}

/// Snapshot of every modulation source for one frame. Built by the live engine from
/// sensors, or by the exporter from offline analysis so exports are deterministic.
struct ModulationContext {
    var time: Double = 0
    var beat: Double = 0
    var audio = AudioBands()
    var lfo: [Float] = []
    var envelope: [Float] = []
    var macros: [Float] = [0, 0, 0, 0]
    var midiCC: [Int: Float] = [:]
    var tracking = TrackingValues()

    func value(of source: ModSource) -> Float {
        switch source {
        case .audioLevel: return audio.level
        case .audioBass: return audio.bass
        case .audioMid: return audio.mid
        case .audioHigh: return audio.high
        case .lfo(let i): return lfo.indices.contains(i) ? lfo[i] : 0.5
        case .envelope(let i): return envelope.indices.contains(i) ? envelope[i] : 0
        case .macro(let i): return macros.indices.contains(i) ? macros[i] : 0
        case .midiCC(let ch, let cc): return midiCC[ch * 128 + cc] ?? 0
        case .handX: return tracking.handX
        case .handY: return tracking.handY
        case .pinch: return tracking.pinch
        case .faceX: return tracking.faceX
        case .faceY: return tracking.faceY
        case .mouthOpen: return tracking.mouthOpen
        }
    }
}

struct AudioBands: Codable, Equatable {
    var level: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var high: Float = 0
    var onset = false
}

struct TrackingValues: Equatable {
    var handX: Float = 0.5
    var handY: Float = 0.5
    var pinch: Float = 0
    var faceX: Float = 0.5
    var faceY: Float = 0.5
    var mouthOpen: Float = 0
}

// MARK: - LFO & envelope

enum LFOShape: String, Codable, CaseIterable, Identifiable {
    case sine, triangle, saw, square, random
    var id: String { rawValue }
}

struct LFO: Codable, Equatable {
    var shape: LFOShape = .sine
    /// Cycle length in beats, so it stays locked to BPM.
    var rateBeats: Double = 1
    var phase: Double = 0

    func value(beat: Double) -> Float {
        let p = (beat / max(rateBeats, 1e-3) + phase).truncatingRemainder(dividingBy: 1)
        let x = p < 0 ? p + 1 : p
        switch shape {
        case .sine: return Float(0.5 - 0.5 * cos(x * 2 * .pi))
        case .triangle: return Float(x < 0.5 ? x * 2 : 2 - x * 2)
        case .saw: return Float(x)
        case .square: return x < 0.5 ? 1 : 0
        case .random:
            // Stepped noise: a new value every cycle, deterministic per cycle index.
            let cycle = floor(beat / max(rateBeats, 1e-3) + phase)
            var h = UInt64(bitPattern: Int64(cycle)) &* 0x9E37_79B9_7F4A_7C15
            h ^= h >> 31
            return Float(h % 10_000) / 10_000
        }
    }
}

enum EnvelopeTrigger: String, Codable, CaseIterable, Identifiable {
    case beat, bar, audioOnset, midiNote, manual
    var id: String { rawValue }
}

struct Envelope: Codable, Equatable {
    var trigger: EnvelopeTrigger = .beat
    var attack: Double = 0.01
    var decay: Double = 0.35

    /// Envelope value `dt` seconds after the most recent trigger.
    func value(sinceTrigger dt: Double?) -> Float {
        guard let dt, dt >= 0 else { return 0 }
        if dt < attack { return Float(dt / max(attack, 1e-4)) }
        let d = dt - attack
        return Float(max(0, exp(-d / max(decay, 1e-4) * 3)))
    }
}
