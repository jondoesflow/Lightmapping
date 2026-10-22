import simd

// Field order and types must match the structs in Shaders.metal exactly.

struct GeneratorUniforms {
    var colorA: SIMD4<Float>
    var colorB: SIMD4<Float>
    var colorC: SIMD4<Float>
    var resolution: SIMD2<Float>
    var time: Float
    var speed: Float
    var scale: Float
    var intensity: Float
    var audioLevel: Float
    var audioBass: Float
    var audioMid: Float
    var audioHigh: Float
    var seed: Float
    var kind: Int32
    var hasMask: Float
    var hasDepth: Float
}

struct LayerUniforms {
    var crop = SIMD4<Float>(0, 0, 1, 1)
    var srcSize = SIMD2<Float>(1, 1)
    var dstSize = SIMD2<Float>(1, 1)
    var kaleido: Float = 0
    var tile: Float = 0
    var slideX: Float = 0
    var slideY: Float = 0
    var rotate: Float = 0
    var zoom: Float = 1
    var blur: Float = 0
    var mono: Float = 0
    var invert: Float = 0
    var hueShift: Float = 0
    var opacity: Float = 1
    var time: Float = 0
    var fit: Int32 = 0
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

struct SurfaceUniforms {
    var tint = SIMD4<Float>(1, 1, 1, 1)
    var opacity: Float = 1
    var feather: Float = 0
    var hasMask: Float = 0
    var pad: Float = 0
}

struct TransitionUniforms {
    var progress: Float
    var style: Int32
    var time: Float
    var pad: Float = 0
}

extension LayerUniforms {
    /// Collapse a layer's effect stack into the fixed-function effect uniforms.
    mutating func apply(_ effects: [Effect], ctx: ModulationContext) {
        for e in effects where e.isEnabled {
            let v = e.amount.value(ctx)
            switch e.kind {
            case .kaleidoscope: kaleido = max(kaleido, v)
            case .tile: tile = max(tile, v)
            case .slide: slideX += v
            case .rotate: rotate += v
            case .zoom: zoom *= max(v, 0.01)
            case .blur: blur = max(blur, v)
            case .monochrome: mono = max(mono, v)
            case .invert: invert = max(invert, v)
            case .colorCycle: hueShift += v
            }
        }
    }
}
