import Metal
import MetalKit
import simd

/// Everything needed to draw one output frame. Built by the live engine or the exporter.
struct FrameState {
    var project: Project
    var scene: MapScene
    /// Scene being transitioned to, with progress 0...1.
    var incoming: (scene: MapScene, progress: Float, style: TransitionStyle)?
    var ctx: ModulationContext
    var showOutlines = false
    var selectedSurfaceID: UUID?
}

/// Provides textures for non-generator content (video, photo, camera, drawing).
protocol SourceTextureProvider: AnyObject {
    func texture(for source: ContentSource, layerID: UUID, ctx: ModulationContext) -> MTLTexture?
}

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pixelFormat: MTLPixelFormat = .bgra8Unorm
    weak var sources: SourceTextureProvider?

    private(set) var outputSize = SIMD2<Int>(1920, 1080)
    /// The finished frame. Views and the exporter read this.
    private(set) var outputTexture: MTLTexture!
    private var sceneTextureA: MTLTexture!
    private var sceneTextureB: MTLTexture!

    private var generatorPipeline: MTLRenderPipelineState!
    private var layerPipelines: [BlendMode: MTLRenderPipelineState] = [:]
    private var surfacePipeline: MTLRenderPipelineState!
    private var linePipeline: MTLRenderPipelineState!
    private var transitionPipeline: MTLRenderPipelineState!
    private(set) var blitPipeline: MTLRenderPipelineState!

    private let maskRenderer: MaskRenderer
    private var whiteTexture: MTLTexture!

    private struct CachedTexture { var texture: MTLTexture; var lastUsed: Int }
    private struct CachedMesh { var mesh: WarpMesh; var buffer: MTLBuffer; var count: Int; var lastUsed: Int }
    private var contentTextures: [String: CachedTexture] = [:]
    private var generatorTextures: [UUID: CachedTexture] = [:]
    private var meshBuffers: [UUID: CachedMesh] = [:]
    private var frameIndex = 0

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.maskRenderer = MaskRenderer(device: device)
        do { try buildPipelines() } catch {
            print("Pipeline error: \(error)")
            return nil
        }
        whiteTexture = makeTexture(width: 1, height: 1, shared: true) // CPU-written, so not .private
        let white: [UInt8] = [255, 255, 255, 255]
        whiteTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: white, bytesPerRow: 4)
        setOutputSize(outputSize)
    }

    private func buildPipelines() throws {
        guard let lib = device.makeDefaultLibrary() else { throw RendererError.noLibrary }
        func pipeline(_ v: String, _ f: String, blend: BlendMode?) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = pixelFormat
            if let blend {
                ca.isBlendingEnabled = true
                ca.rgbBlendOperation = .add
                ca.alphaBlendOperation = .add
                ca.sourceAlphaBlendFactor = .one
                ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                switch blend {
                case .normal:
                    ca.sourceRGBBlendFactor = .one
                    ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                case .add:
                    ca.sourceRGBBlendFactor = .one
                    ca.destinationRGBBlendFactor = .one
                case .screen:
                    ca.sourceRGBBlendFactor = .one
                    ca.destinationRGBBlendFactor = .oneMinusSourceColor
                case .multiply:
                    ca.sourceRGBBlendFactor = .destinationColor
                    ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                }
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        generatorPipeline = try pipeline("fullscreenVertex", "generatorFragment", blend: nil)
        for mode in BlendMode.allCases {
            layerPipelines[mode] = try pipeline("fullscreenVertex", "layerFragment", blend: mode)
        }
        surfacePipeline = try pipeline("surfaceVertex", "surfaceFragment", blend: .normal)
        linePipeline = try pipeline("lineVertex", "lineFragment", blend: .normal)
        transitionPipeline = try pipeline("fullscreenVertex", "transitionFragment", blend: nil)
        blitPipeline = try pipeline("fullscreenVertex", "blitFragment", blend: nil)
    }

    enum RendererError: Error { case noLibrary }

    func setOutputSize(_ size: SIMD2<Int>) {
        let s = SIMD2(max(size.x, 16), max(size.y, 16))
        if outputTexture != nil && s == outputSize { return }
        outputSize = s
        outputTexture = makeTexture(width: s.x, height: s.y, shared: true)
        sceneTextureA = makeTexture(width: s.x, height: s.y)
        sceneTextureB = makeTexture(width: s.x, height: s.y)
    }

    func makeTexture(width: Int, height: Int, shared: Bool = false) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = shared ? .shared : .private
        return device.makeTexture(descriptor: d)!
    }

    // MARK: Frame

    /// Encode a full frame into `commandBuffer`, writing to `target` (defaults to `outputTexture`).
    func encodeFrame(_ state: FrameState, into commandBuffer: MTLCommandBuffer, target: MTLTexture? = nil) {
        frameIndex += 1
        let target = target ?? outputTexture!

        if let incoming = state.incoming, incoming.style != .cut {
            renderScene(state.scene, state: state, into: sceneTextureA, commandBuffer: commandBuffer)
            renderScene(incoming.scene, state: state, into: sceneTextureB, commandBuffer: commandBuffer)
            let pass = passDescriptor(target, clear: true)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                var u = TransitionUniforms(progress: incoming.progress, style: incoming.style == .dissolve ? 2 : 1, time: Float(state.ctx.time))
                enc.setRenderPipelineState(transitionPipeline)
                enc.setFragmentBytes(&u, length: MemoryLayout<TransitionUniforms>.stride, index: 0)
                enc.setFragmentTexture(sceneTextureA, index: 0)
                enc.setFragmentTexture(sceneTextureB, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        } else {
            let scene = state.incoming?.scene ?? state.scene
            renderScene(scene, state: state, into: target, commandBuffer: commandBuffer)
        }

        if state.showOutlines {
            drawOutlines(state, into: target, commandBuffer: commandBuffer)
        }
        evictStale()
    }

    private func renderScene(_ scene: MapScene, state: FrameState, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let project = state.project
        var drawList: [(Surface, MTLTexture, MTLTexture?)] = []

        for surface in project.surfaces where surface.isVisible {
            let content = scene.content(for: surface.id)
            let layers = content.layers.filter { $0.isVisible }
            guard !layers.isEmpty else { continue }

            let size = contentSize(for: surface)
            let mask = maskRenderer.mask(for: surface, size: size)
            let depth = maskRenderer.depth(for: surface)

            // 1. Generators render to their own textures.
            var layerSources: [(Layer, MTLTexture)] = []
            for layer in layers {
                switch layer.source {
                case .generator(let kind):
                    let tex = generatorTexture(layer.id, size: size)
                    renderGenerator(kind, layer: layer, size: size, mask: mask, depth: depth, ctx: state.ctx, into: tex, commandBuffer: commandBuffer)
                    layerSources.append((layer, tex))
                default:
                    if let tex = sources?.texture(for: layer.source, layerID: layer.id, ctx: state.ctx) {
                        layerSources.append((layer, tex))
                    }
                }
            }
            guard !layerSources.isEmpty else { continue }

            // 2. Composite the layer stack into the surface's content texture.
            let contentTex = contentTexture("\(scene.id)-\(surface.id)", size: size)
            let pass = passDescriptor(contentTex, clear: true)
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            for (layer, src) in layerSources {
                var u = LayerUniforms()
                u.crop = layer.crop
                u.srcSize = SIMD2(Float(src.width), Float(src.height))
                u.dstSize = SIMD2(Float(size.x), Float(size.y))
                u.opacity = layer.opacity.value(state.ctx)
                u.time = Float(state.ctx.time)
                u.fit = layer.fit == .fill ? 0 : (layer.fit == .fit ? 1 : 2)
                u.apply(layer.effects, ctx: state.ctx)
                enc.setRenderPipelineState(layerPipelines[layer.blend]!)
                enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
                enc.setFragmentTexture(src, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.endEncoding()
            drawList.append((surface, contentTex, mask))
        }

        // 3. Warp every surface onto the output.
        let pass = passDescriptor(target, clear: true)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(surfacePipeline)
        for (surface, content, mask) in drawList {
            let mesh = meshBuffer(for: surface)
            var u = SurfaceUniforms(tint: scene.tint, opacity: surface.opacity, feather: surface.feather, hasMask: mask == nil ? 0 : 1)
            enc.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<SurfaceUniforms>.stride, index: 0)
            enc.setFragmentTexture(content, index: 0)
            enc.setFragmentTexture(mask ?? whiteTexture, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.count)
        }
        enc.endEncoding()
    }

    private func renderGenerator(_ kind: GeneratorKind, layer: Layer, size: SIMD2<Int>, mask: MTLTexture?, depth: MTLTexture?,
                                 ctx: ModulationContext, into tex: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let g = layer.generator
        var u = GeneratorUniforms(
            colorA: g.colorA, colorB: g.colorB, colorC: g.colorC,
            resolution: SIMD2(Float(size.x), Float(size.y)),
            time: Float(ctx.time.truncatingRemainder(dividingBy: 3600)),
            speed: g.speed.value(ctx), scale: g.scale.value(ctx), intensity: g.intensity.value(ctx),
            audioLevel: ctx.audio.level, audioBass: ctx.audio.bass, audioMid: ctx.audio.mid, audioHigh: ctx.audio.high,
            seed: g.seed, kind: Int32(kind.rawValue),
            hasMask: mask == nil ? 0 : 1, hasDepth: depth == nil ? 0 : 1)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor(tex, clear: false, dontCare: true)) else { return }
        enc.setRenderPipelineState(generatorPipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<GeneratorUniforms>.stride, index: 0)
        enc.setFragmentTexture(mask ?? whiteTexture, index: 0)
        enc.setFragmentTexture(depth ?? whiteTexture, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func drawOutlines(_ state: FrameState, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = passDescriptor(target, clear: false)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(linePipeline)
        for surface in state.project.surfaces where surface.isVisible {
            let selected = surface.id == state.selectedSurfaceID
            var pts: [SIMD2<Float>] = []
            let outline = surface.mesh.outline()
            for i in 0..<outline.count { pts += [outline[i], outline[(i + 1) % outline.count]] }
            if selected {
                // Interior grid lines help line up with physical edges.
                let n = 8
                for k in 1..<n {
                    let f = Float(k) / Float(n)
                    for i in 0..<16 {
                        let a = Float(i) / 16, b = Float(i + 1) / 16
                        pts += [surface.mesh.map(SIMD2(a, f)), surface.mesh.map(SIMD2(b, f))]
                        pts += [surface.mesh.map(SIMD2(f, a)), surface.mesh.map(SIMD2(f, b))]
                    }
                }
            }
            var color: SIMD4<Float> = selected ? SIMD4(1, 0.8, 0, 1) : SIMD4(0.3, 0.8, 1, 0.8)
            pts.withUnsafeBytes { raw in
                guard let buf = device.makeBuffer(bytes: raw.baseAddress!, length: raw.count) else { return }
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: pts.count)
            }
        }
        enc.endEncoding()
    }

    /// Draw `texture` aspect-fit into a view's drawable.
    func present(_ texture: MTLTexture, to view: MTKView, commandBuffer: MTLCommandBuffer) {
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else { return }
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let vw = Double(drawable.texture.width), vh = Double(drawable.texture.height)
        let ta = Double(texture.width) / Double(texture.height)
        var w = vw, h = vw / ta
        if h > vh { h = vh; w = vh * ta }
        enc.setViewport(MTLViewport(originX: (vw - w) / 2, originY: (vh - h) / 2, width: w, height: h, znear: 0, zfar: 1))
        enc.setRenderPipelineState(blitPipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        commandBuffer.present(drawable)
    }

    // MARK: Caches

    func contentSize(for surface: Surface) -> SIMD2<Int> {
        let b = surface.mesh.bounds
        let w = max((b.max.x - b.min.x) * Float(outputSize.x), 1)
        let h = max((b.max.y - b.min.y) * Float(outputSize.y), 1)
        let longEdge = Float(surface.contentResolution)
        let s = longEdge / max(w, h)
        // Round to 32px steps so dragging handles doesn't reallocate every frame.
        func q(_ v: Float) -> Int { max(64, Int((v * s / 32).rounded()) * 32) }
        return SIMD2(q(w), q(h))
    }

    private func contentTexture(_ key: String, size: SIMD2<Int>) -> MTLTexture {
        if let c = contentTextures[key], c.texture.width == size.x, c.texture.height == size.y {
            contentTextures[key]?.lastUsed = frameIndex
            return c.texture
        }
        let t = makeTexture(width: size.x, height: size.y)
        contentTextures[key] = CachedTexture(texture: t, lastUsed: frameIndex)
        return t
    }

    private func generatorTexture(_ id: UUID, size: SIMD2<Int>) -> MTLTexture {
        if let c = generatorTextures[id], c.texture.width == size.x, c.texture.height == size.y {
            generatorTextures[id]?.lastUsed = frameIndex
            return c.texture
        }
        let t = makeTexture(width: size.x, height: size.y)
        generatorTextures[id] = CachedTexture(texture: t, lastUsed: frameIndex)
        return t
    }

    private func meshBuffer(for surface: Surface) -> CachedMesh {
        if var c = meshBuffers[surface.id], c.mesh == surface.mesh {
            c.lastUsed = frameIndex
            meshBuffers[surface.id] = c
            return c
        }
        let verts = surface.mesh.tessellate(subdivisions: surface.mesh.columns == 2 ? 24 : 40)
            .map { SIMD4<Float>($0.position.x, $0.position.y, $0.uv.x, $0.uv.y) }
        let buf = verts.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        let c = CachedMesh(mesh: surface.mesh, buffer: buf, count: verts.count, lastUsed: frameIndex)
        meshBuffers[surface.id] = c
        return c
    }

    private func evictStale() {
        guard frameIndex % 120 == 0 else { return }
        let cutoff = frameIndex - 240
        contentTextures = contentTextures.filter { $0.value.lastUsed > cutoff }
        generatorTextures = generatorTextures.filter { $0.value.lastUsed > cutoff }
        meshBuffers = meshBuffers.filter { $0.value.lastUsed > cutoff }
        maskRenderer.evict(olderThan: Date().addingTimeInterval(-30))
    }

    private func passDescriptor(_ tex: MTLTexture, clear: Bool, dontCare: Bool = false) -> MTLRenderPassDescriptor {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = tex
        d.colorAttachments[0].loadAction = dontCare ? .dontCare : (clear ? .clear : .load)
        d.colorAttachments[0].storeAction = .store
        d.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        return d
    }
}
