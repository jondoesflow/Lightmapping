import CoreGraphics
import Metal
import simd
import UIKit

/// Renders an animated hand drawing to a texture. Strokes are in unit space (0...1, y down).
final class DrawingRenderer {
    static let size = 1024

    private let device: MTLDevice
    private var texture: MTLTexture?
    private let context: CGContext

    init(device: MTLDevice) {
        self.device = device
        let s = DrawingRenderer.size
        context = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    }

    func render(_ drawing: Drawing, time: Double) -> MTLTexture? {
        let s = DrawingRenderer.size
        if texture == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: s, height: s, mipmapped: false)
            d.usage = .shaderRead
            texture = device.makeTexture(descriptor: d)
        }
        guard let texture else { return nil }

        let ctx = context
        ctx.saveGState()
        ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
        ctx.translateBy(x: 0, y: CGFloat(s))
        ctx.scaleBy(x: CGFloat(s), y: -CGFloat(s))
        Self.draw(drawing, in: ctx, time: time, pixelScale: CGFloat(s))
        ctx.restoreGState()

        if let data = ctx.data {
            texture.replace(region: MTLRegionMake2D(0, 0, s, s), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        }
        return texture
    }

    /// Shared with the drawing editor so the preview matches the projection.
    static func draw(_ drawing: Drawing, in ctx: CGContext, time: Double, pixelScale: CGFloat) {
        let phase = drawing.period > 0 ? CGFloat((time / Double(drawing.period)).truncatingRemainder(dividingBy: 1)) : 1
        let totalLength = drawing.strokes.reduce(CGFloat(0)) { $0 + length($1.points) }
        var reveal = totalLength
        if drawing.animation == .traceOn {
            // Draw on over 70% of the cycle, hold, then restart.
            reveal = totalLength * min(1, phase / 0.7)
        }

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        var consumed: CGFloat = 0
        for (i, stroke) in drawing.strokes.enumerated() {
            guard stroke.points.count > 1 else { continue }
            var color = UIColor(red: CGFloat(stroke.color.x), green: CGFloat(stroke.color.y), blue: CGFloat(stroke.color.z), alpha: CGFloat(stroke.color.w))
            var widthScale: CGFloat = 1
            switch drawing.animation {
            case .pulse:
                widthScale = 1 + 0.5 * sin(phase * 2 * .pi + CGFloat(i))
            case .hueCycle:
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                color = UIColor(hue: (h + phase).truncatingRemainder(dividingBy: 1), saturation: max(s, 0.6), brightness: b, alpha: a)
            case .flicker:
                let n = sin(Double(time) * 37 + Double(i) * 11) * sin(Double(time) * 23)
                color = color.withAlphaComponent(n > 0.85 ? 0.2 : 1)
            case .none, .traceOn:
                break
            }

            let path = CGMutablePath()
            path.move(to: cg(stroke.points[0]))
            var remaining = reveal - consumed
            var last = stroke.points[0]
            for p in stroke.points.dropFirst() {
                let seg = CGFloat(simd_distance(p, last))
                if remaining <= 0 { break }
                if seg > remaining {
                    let f = Float(remaining / seg)
                    path.addLine(to: cg(last + (p - last) * f))
                    remaining = 0
                    break
                }
                path.addLine(to: cg(p))
                remaining -= seg
                last = p
            }
            consumed += length(stroke.points)

            let w = CGFloat(stroke.width) * widthScale / pixelScale
            if stroke.glow > 0 {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: CGFloat(stroke.glow) * 30, color: color.cgColor)
                ctx.addPath(path)
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(w)
                ctx.strokePath()
                ctx.restoreGState()
            }
            ctx.addPath(path)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(w)
            ctx.strokePath()
        }
    }

    private static func length(_ pts: [SIMD2<Float>]) -> CGFloat {
        CGFloat(zip(pts, pts.dropFirst()).reduce(Float(0)) { $0 + simd_distance($1.0, $1.1) })
    }

    private static func cg(_ p: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)) }
}
