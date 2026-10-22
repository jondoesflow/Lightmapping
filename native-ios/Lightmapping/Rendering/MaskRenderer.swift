import CoreGraphics
import Metal
import MetalKit
import UIKit

/// Rasterises a surface's shape (circle, text, silhouette, outline...) and cutouts into an
/// 8-bit mask texture in surface UV space. Results are cached until the shape changes.
final class MaskRenderer {
    private let device: MTLDevice
    private let loader: MTKTextureLoader

    private struct Key: Equatable {
        var shape: SurfaceShape
        var cutouts: [[SIMD2<Float>]]
        var size: SIMD2<Int>
    }
    private var masks: [UUID: (key: Key, texture: MTLTexture?, used: Date)] = [:]
    private var depthMaps: [UUID: (texture: MTLTexture, used: Date)] = [:]

    init(device: MTLDevice) {
        self.device = device
        self.loader = MTKTextureLoader(device: device)
    }

    /// Returns nil when the surface needs no mask (a plain quad without cutouts).
    func mask(for surface: Surface, size: SIMD2<Int>) -> MTLTexture? {
        // Masks don't need full content resolution.
        let maskSize = SIMD2(min(size.x, 1024), min(size.y, 1024))
        let key = Key(shape: surface.shape, cutouts: surface.cutouts, size: maskSize)
        if let cached = masks[surface.id], cached.key == key {
            masks[surface.id]?.used = Date()
            return cached.texture
        }
        let tex = render(key)
        masks[surface.id] = (key, tex, Date())
        return tex
    }

    func depth(for surface: Surface) -> MTLTexture? {
        guard case .depth(_, let depthID) = surface.shape else { return nil }
        if let c = depthMaps[depthID] {
            depthMaps[depthID]?.used = Date()
            return c.texture
        }
        guard let url = ProjectStore.shared.assetURL(depthID),
              let tex = try? loader.newTexture(URL: url, options: [.SRGB: false, .textureStorageMode: MTLStorageMode.private.rawValue])
        else { return nil }
        depthMaps[depthID] = (tex, Date())
        return tex
    }

    func evict(olderThan date: Date) {
        masks = masks.filter { $0.value.used > date }
        depthMaps = depthMaps.filter { $0.value.used > date }
    }

    private func render(_ key: Key) -> MTLTexture? {
        let needsShape: Bool
        switch key.shape {
        case .quad, .boxFace: needsShape = false
        default: needsShape = true
        }
        if !needsShape && key.cutouts.isEmpty { return nil }

        let w = key.size.x, h = key.size.y
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        // Work in y-down unit space so drawing matches surface UVs.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(w), y: -CGFloat(h))
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(unit)
        ctx.setFillColor(gray: 1, alpha: 1)

        switch key.shape {
        case .quad, .boxFace:
            ctx.fill(unit)
        case .circle:
            ctx.fillEllipse(in: unit)
        case .freehand(let pts):
            fillPolygon(ctx, pts)
        case .text(let string, let fontName):
            drawText(ctx, string: string, fontName: fontName, w: w, h: h)
        case .silhouette(let maskID), .depth(let maskID, _):
            if let img = ProjectStore.shared.image(maskID)?.cgImage {
                // CGContext.draw expects a y-up rect; undo our flip locally.
                ctx.saveGState()
                ctx.translateBy(x: 0, y: 1)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: unit)
                ctx.restoreGState()
            }
        }

        ctx.setFillColor(gray: 0, alpha: 1)
        for cut in key.cutouts { fillPolygon(ctx, cut) }

        guard let data = ctx.data else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        return tex
    }

    private func fillPolygon(_ ctx: CGContext, _ pts: [SIMD2<Float>]) {
        guard pts.count >= 3 else { return }
        ctx.beginPath()
        ctx.move(to: CGPoint(x: CGFloat(pts[0].x), y: CGFloat(pts[0].y)))
        for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))) }
        ctx.closePath()
        ctx.fillPath()
    }

    private func drawText(_ ctx: CGContext, string: String, fontName: String, w: Int, h: Int) {
        // Text is laid out in pixel space; reset the unit scale but keep the y-down flip.
        ctx.saveGState()
        ctx.scaleBy(x: 1 / CGFloat(w), y: 1 / CGFloat(h))
        UIGraphicsPushContext(ctx)
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        var size = CGFloat(h)
        var attrs: [NSAttributedString.Key: Any] = [:]
        // Shrink until the string fits the surface.
        while size > 6 {
            let font = UIFont(name: fontName, size: size) ?? .systemFont(ofSize: size, weight: .black)
            attrs = [.font: font, .foregroundColor: UIColor.white]
            let bounds = (string as NSString).boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                                                           options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
            if bounds.width <= rect.width && bounds.height <= rect.height { break }
            size *= 0.92
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        attrs[.paragraphStyle] = para
        let bounds = (string as NSString).boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                                                       options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
        let drawRect = CGRect(x: 0, y: (rect.height - bounds.height) / 2, width: rect.width, height: bounds.height)
        (string as NSString).draw(with: drawRect, options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
        UIGraphicsPopContext()
        ctx.restoreGState()
    }
}
