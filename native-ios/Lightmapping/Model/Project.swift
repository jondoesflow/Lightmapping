import Foundation
import simd

// MARK: - Project

/// A mapping project. Surfaces hold the geometry (they are calibrated once to the
/// physical space). Scenes decide what content plays on each surface, so switching
/// scenes never disturbs the alignment.
struct Project: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var modifiedAt = Date()

    var surfaces: [Surface] = []
    var scenes: [MapScene] = [MapScene(name: "Scene 1")]
    var activeSceneID: UUID?

    var bpm: Double = 120
    var lfos: [LFO] = [LFO(), LFO(shape: .triangle, rateBeats: 4), LFO(shape: .saw, rateBeats: 2), LFO(shape: .square, rateBeats: 0.5)]
    var envelopes: [Envelope] = [Envelope(), Envelope(trigger: .audioOnset)]
    var macros: [Float] = [0, 0, 0, 0]

    var timeline = Timeline()
    var transition = SceneTransition()

    /// Output canvas aspect (projector). Surface coordinates are normalised 0...1 in this space.
    var outputAspect: Float = 16.0 / 9.0

    init(name: String) {
        self.name = name
        activeSceneID = scenes.first?.id
    }

    var activeScene: MapScene? {
        scenes.first { $0.id == activeSceneID } ?? scenes.first
    }

    func sceneIndex(_ id: UUID?) -> Int? { scenes.firstIndex { $0.id == id } }
    func surfaceIndex(_ id: UUID?) -> Int? { surfaces.firstIndex { $0.id == id } }
}

// MARK: - Surfaces

enum SurfaceShape: Codable, Equatable {
    case quad
    case circle
    case text(String, fontName: String)
    /// One face of a box/cube. Faces from the same box share `Surface.groupID`.
    case boxFace(index: Int)
    /// Alpha mask produced by subject segmentation of an imported photo.
    case silhouette(maskAssetID: UUID)
    /// Silhouette plus a per-pixel depth map from a single photo.
    case depth(maskAssetID: UUID, depthAssetID: UUID)
    /// Hand-drawn closed outline, in surface UV space (0...1).
    case freehand([SIMD2<Float>])

    var displayName: String {
        switch self {
        case .quad: return "Square"
        case .circle: return "Circle"
        case .text(let s, _): return "Text \u{201C}\(s)\u{201D}"
        case .boxFace(let i): return "Box face \(i + 1)"
        case .silhouette: return "Silhouette"
        case .depth: return "Depth shape"
        case .freehand: return "Outline"
        }
    }
}

struct Surface: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var shape: SurfaceShape
    var mesh: WarpMesh
    var groupID: UUID?
    var isVisible = true
    var isLocked = false
    var opacity: Float = 1
    /// Soft edge width, in UV units.
    var feather: Float = 0.0
    /// Polygons (surface UV space) that are punched out of the surface.
    var cutouts: [[SIMD2<Float>]] = []
    /// Content resolution of this surface's offscreen texture (long edge).
    var contentResolution: Int = 1024

    init(name: String, shape: SurfaceShape, mesh: WarpMesh) {
        self.name = name
        self.shape = shape
        self.mesh = mesh
    }
}

// MARK: - Scenes & layers

struct MapScene: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Content stack per surface.
    var assignments: [UUID: SurfaceContent] = [:]
    var tint: SIMD4<Float> = SIMD4(1, 1, 1, 1)

    init(name: String) { self.name = name }

    func content(for surfaceID: UUID) -> SurfaceContent {
        assignments[surfaceID] ?? SurfaceContent()
    }
}

struct SurfaceContent: Codable, Equatable {
    var layers: [Layer] = []
}

enum BlendMode: String, Codable, CaseIterable, Identifiable {
    case normal, add, screen, multiply
    var id: String { rawValue }
}

enum FitMode: String, Codable, CaseIterable, Identifiable {
    case fill, fit, stretch
    var id: String { rawValue }
}

struct Layer: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var source: ContentSource
    var isVisible = true
    var opacity = Param(1)
    var blend: BlendMode = .normal
    var fit: FitMode = .fill
    /// Normalised crop rect within the source (x, y, w, h).
    var crop = SIMD4<Float>(0, 0, 1, 1)
    var effects: [Effect] = []
    var generator = GeneratorSettings()

    init(name: String, source: ContentSource) {
        self.name = name
        self.source = source
    }
}

enum CameraPosition: String, Codable { case back, front }

enum ContentSource: Codable, Equatable {
    case generator(GeneratorKind)
    case video(assetID: UUID)
    case photo(assetID: UUID)
    case camera(CameraPosition)
    case drawing(Drawing)

    var displayName: String {
        switch self {
        case .generator(let k): return k.displayName
        case .video: return "Video"
        case .photo: return "Photo"
        case .camera(let p): return p == .front ? "Front camera" : "Camera"
        case .drawing: return "Drawing"
        }
    }
}

struct GeneratorSettings: Codable, Equatable {
    var speed = Param(1)
    var scale = Param(1)
    var intensity = Param(1)
    var colorA = SIMD4<Float>(1.0, 0.2, 0.6, 1)
    var colorB = SIMD4<Float>(0.1, 0.6, 1.0, 1)
    var colorC = SIMD4<Float>(0.05, 0.0, 0.15, 1)
    var seed: Float = 0
}

// MARK: - Effects

enum EffectKind: String, Codable, CaseIterable, Identifiable {
    case kaleidoscope, tile, slide, rotate, zoom, blur, monochrome, invert, colorCycle
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .colorCycle: return "Color cycle"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    var defaultAmount: Float {
        switch self {
        case .kaleidoscope: return 6
        case .tile: return 2
        case .slide: return 0.2
        case .rotate: return 0.1
        case .zoom: return 1.5
        case .blur: return 0.3
        case .monochrome, .invert: return 1
        case .colorCycle: return 0.2
        }
    }

    var range: ClosedRange<Float> {
        switch self {
        case .kaleidoscope: return 2...16
        case .tile: return 1...8
        case .slide: return -2...2
        case .rotate: return -2...2
        case .zoom: return 0.25...4
        case .blur: return 0...1
        case .monochrome, .invert: return 0...1
        case .colorCycle: return 0...2
        }
    }
}

struct Effect: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: EffectKind
    var amount: Param
    var isEnabled = true

    init(kind: EffectKind) {
        self.kind = kind
        self.amount = Param(kind.defaultAmount)
    }
}

// MARK: - Drawings

enum DrawingAnimation: String, Codable, CaseIterable, Identifiable {
    case none, traceOn, pulse, hueCycle, flicker
    var id: String { rawValue }
}

struct Stroke: Codable, Equatable {
    var points: [SIMD2<Float>]
    var color: SIMD4<Float>
    var width: Float
    var glow: Float = 0.5
}

struct Drawing: Codable, Equatable {
    var strokes: [Stroke] = []
    var animation: DrawingAnimation = .traceOn
    /// Seconds for one animation cycle.
    var period: Float = 4
}

// MARK: - Timeline

struct TimelineClip: Codable, Identifiable, Equatable {
    var id = UUID()
    var sceneID: UUID
    var start: Double
    var duration: Double
}

struct AutomationKeyframe: Codable, Equatable {
    var time: Double
    var value: Float
}

struct AutomationLane: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Which macro (0...3) this lane drives.
    var macroIndex: Int
    var keyframes: [AutomationKeyframe] = []

    func value(at t: Double) -> Float? {
        guard let first = keyframes.first else { return nil }
        if t <= first.time { return first.value }
        for (a, b) in zip(keyframes, keyframes.dropFirst()) where t <= b.time {
            let f = Float((t - a.time) / max(b.time - a.time, 1e-6))
            return a.value + (b.value - a.value) * f
        }
        return keyframes.last?.value
    }
}

struct Timeline: Codable, Equatable {
    var clips: [TimelineClip] = []
    var automation: [AutomationLane] = []
    var audioAssetID: UUID?

    var duration: Double { clips.map { $0.start + $0.duration }.max() ?? 0 }

    /// The clip playing at `t` (later clips win where clips overlap).
    func clip(at t: Double) -> TimelineClip? {
        clips.last { t >= $0.start && t < $0.start + $0.duration }
    }

    mutating func sortClips() { clips.sort { $0.start < $1.start } }
}

enum TransitionStyle: String, Codable, CaseIterable, Identifiable {
    case cut, fade, dissolve
    var id: String { rawValue }
}

struct SceneTransition: Codable, Equatable {
    var style: TransitionStyle = .fade
    var duration: Double = 1.5
}
