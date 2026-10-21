import MetalKit
import SwiftUI

struct MetalPreview: UIViewRepresentable {
    let engine: Engine

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        v.backgroundColor = .black
        engine.attach(v)
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    static func dismantleUIView(_ uiView: MTKView, coordinator: ()) {
        Task { @MainActor in AppModel.shared.engine?.detach(uiView) }
    }
}

enum CanvasTool: Equatable {
    case select
    /// Draw a closed outline that becomes a new surface.
    case drawOutline
    /// Draw a cutout polygon on the selected surface.
    case drawCutout
}

/// Live output preview with touch handles for every warp control point.
struct MappingCanvas: View {
    @EnvironmentObject var engine: Engine
    @Binding var tool: CanvasTool

    @State private var dragStart: WarpMesh?
    @State private var gestureStart: WarpMesh?
    @State private var stroke: [CGPoint] = []
    @State private var linkedCorners: [(surface: UUID, index: Int)] = []

    var body: some View {
        GeometryReader { geo in
            let rect = outputRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.black
                MetalPreview(engine: engine)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)

                if engine.showOutlines {
                    outlines(rect)
                }
                if tool == .select, let surface = engine.selectedSurface, !surface.isLocked {
                    handles(surface, rect)
                }
                if tool != .select {
                    drawingLayer(rect)
                }
            }
            .contentShape(Rectangle())
            .gesture(surfaceGesture(rect))
            .simultaneousGesture(pinchRotate(rect))
        }
        .ignoresSafeArea()
    }

    private func outputRect(in size: CGSize) -> CGRect {
        let aspect = CGFloat(engine.project.outputAspect)
        var w = size.width, h = size.width / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func toView(_ p: SIMD2<Float>, _ r: CGRect) -> CGPoint {
        CGPoint(x: r.minX + CGFloat(p.x) * r.width, y: r.minY + CGFloat(p.y) * r.height)
    }

    private func toOutput(_ p: CGPoint, _ r: CGRect) -> SIMD2<Float> {
        SIMD2(Float((p.x - r.minX) / r.width), Float((p.y - r.minY) / r.height))
    }

    // MARK: Overlays

    private func outlines(_ rect: CGRect) -> some View {
        ZStack {
            ForEach(engine.project.surfaces) { s in
                Path { path in
                    let pts = s.mesh.outline().map { toView($0, rect) }
                    path.addLines(pts)
                    path.closeSubpath()
                }
                .stroke(s.id == engine.selectedSurfaceID ? Color.yellow : Color.cyan.opacity(0.5),
                        style: StrokeStyle(lineWidth: s.id == engine.selectedSurfaceID ? 2 : 1, dash: s.isVisible ? [] : [4, 4]))
            }
        }
        .allowsHitTesting(false)
    }

    private func handles(_ surface: Surface, _ rect: CGRect) -> some View {
        ZStack {
            ForEach(Array(surface.mesh.points.enumerated()), id: \.offset) { i, p in
                let isCorner = isCornerIndex(i, mesh: surface.mesh)
                Circle()
                    .fill(isCorner ? Color.yellow : Color.orange)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                    .frame(width: isCorner ? 26 : 20, height: isCorner ? 26 : 20)
                    .padding(14) // bigger touch target than the dot
                    .contentShape(Circle())
                    .position(toView(p, rect))
                    .gesture(handleDrag(surface.id, index: i, rect: rect))
            }
            // Centre handle moves the whole surface.
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.yellow))
                .position(toView(surface.mesh.centroid, rect))
                .gesture(moveDrag(surface.id, rect: rect))
        }
    }

    private func isCornerIndex(_ i: Int, mesh: WarpMesh) -> Bool {
        let c = i % mesh.columns, r = i / mesh.columns
        return (c == 0 || c == mesh.columns - 1) && (r == 0 || r == mesh.rows - 1)
    }

    // MARK: Gestures

    private func handleDrag(_ id: UUID, index: Int, rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragStart == nil, let mesh = engine.selectedSurface?.mesh {
                    dragStart = mesh
                    linkedCorners = coincidentCorners(of: id, at: mesh.points[index])
                }
                guard let start = dragStart else { return }
                // Relative to where the finger started, so the dot doesn't jump under the finger.
                let d = SIMD2(Float(v.translation.width / rect.width), Float(v.translation.height / rect.height))
                let p = start.points[index] + d
                engine.updateSurface(id) { $0.mesh.points[index] = p }
                for link in linkedCorners {
                    engine.updateSurface(link.surface) { $0.mesh.points[link.index] = p }
                }
            }
            .onEnded { _ in dragStart = nil; linkedCorners = [] }
    }

    /// Box faces share corners: dragging one drags the matching corner on sibling faces.
    private func coincidentCorners(of id: UUID, at point: SIMD2<Float>) -> [(surface: UUID, index: Int)] {
        guard let group = engine.project.surfaces.first(where: { $0.id == id })?.groupID else { return [] }
        var links: [(UUID, Int)] = []
        for sibling in engine.project.surfaces where sibling.groupID == group && sibling.id != id {
            for (i, q) in sibling.mesh.points.enumerated() where simd_distance(q, point) < 0.004 {
                links.append((sibling.id, i))
            }
        }
        return links
    }

    private func moveDrag(_ id: UUID, rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragStart == nil { dragStart = engine.selectedSurface?.mesh }
                guard let start = dragStart else { return }
                let d = SIMD2(Float(v.translation.width / rect.width), Float(v.translation.height / rect.height))
                engine.updateSurface(id) { s in
                    s.mesh = start
                    s.mesh.translate(by: d)
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Tap selects the top-most surface under the finger.
    private func surfaceGesture(_ rect: CGRect) -> some Gesture {
        SpatialTapGesture()
            .onEnded { v in
                guard tool == .select else { return }
                let p = toOutput(v.location, rect)
                let hit = engine.project.surfaces.reversed().first { $0.mesh.contains(p) }
                engine.selectedSurfaceID = hit?.id
            }
    }

    private func pinchRotate(_ rect: CGRect) -> some Gesture {
        SimultaneousGesture(MagnifyGesture(), RotateGesture())
            .onChanged { v in
                guard tool == .select, let surface = engine.selectedSurface, !surface.isLocked else { return }
                if gestureStart == nil { gestureStart = surface.mesh }
                guard var mesh = gestureStart else { return }
                let c = mesh.centroid
                if let m = v.first?.magnification { mesh.scale(by: Float(m), around: c) }
                if let r = v.second?.rotation {
                    mesh.rotate(by: Float(r.radians), around: c, aspect: engine.project.outputAspect)
                }
                engine.updateSurface(surface.id) { $0.mesh = mesh }
            }
            .onEnded { _ in gestureStart = nil }
    }

    // MARK: Freehand drawing

    private func drawingLayer(_ rect: CGRect) -> some View {
        ZStack {
            Color.white.opacity(0.001)
            Path { p in
                guard let first = stroke.first else { return }
                p.move(to: first)
                p.addLines(stroke)
            }
            .stroke(tool == .drawCutout ? Color.red : Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in stroke.append(v.location) }
                .onEnded { _ in
                    finishStroke(rect)
                    stroke = []
                }
        )
    }

    private func finishStroke(_ rect: CGRect) {
        let pts = Polygon.simplify(stroke.map { toOutput($0, rect) }, tolerance: 0.002)
        guard pts.count >= 3 else { return }
        switch tool {
        case .drawOutline:
            // New surface: bounding quad plus the outline as a mask in its UV space.
            let b = Polygon.bounds(pts)
            let size = simd_max(b.max - b.min, SIMD2(repeating: 0.01))
            let uv = pts.map { ($0 - b.min) / size }
            let mesh = WarpMesh.rect(center: (b.min + b.max) / 2, size: size)
            engine.addSurface(.freehand(uv), name: "Outline \(engine.project.surfaces.count + 1)", mesh: mesh)
        case .drawCutout:
            guard let surface = engine.selectedSurface else { return }
            // Invert the warp so the cutout sticks to the surface when it's re-mapped later.
            let uv = pts.map { inverseMap(surface.mesh, $0) }
            engine.updateSurface(surface.id) { $0.cutouts.append(uv) }
        case .select:
            break
        }
        tool = .select
    }

    /// Output point -> surface UV. Exact for corner pins, iterative for curved meshes.
    private func inverseMap(_ mesh: WarpMesh, _ p: SIMD2<Float>) -> SIMD2<Float> {
        let c = mesh.corners
        var uv = Homography.squareToQuad(c.tl, c.tr, c.br, c.bl).inverse.apply(p)
        if mesh.columns > 2 || mesh.rows > 2 {
            // Newton-style refinement against the curved patch using a numeric Jacobian.
            for _ in 0..<8 {
                let f = mesh.map(uv) - p
                let e: Float = 1e-3
                let dx = (mesh.map(uv + SIMD2(e, 0)) - mesh.map(uv)) / e
                let dy = (mesh.map(uv + SIMD2(0, e)) - mesh.map(uv)) / e
                let det = dx.x * dy.y - dx.y * dy.x
                guard abs(det) > 1e-8 else { break }
                uv -= SIMD2((f.x * dy.y - f.y * dy.x) / det, (dx.x * f.y - dx.y * f.x) / det)
            }
        }
        return uv
    }
}
