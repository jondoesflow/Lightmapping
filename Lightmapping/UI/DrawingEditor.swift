import SwiftUI

/// Draw by hand, then pick how the drawing animates on the surface.
struct DrawingEditor: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    let surfaceID: UUID
    let layerID: UUID

    @State private var drawing = Drawing()
    @State private var current: [SIMD2<Float>] = []
    @State private var color = Color.cyan
    @State private var width: Float = 10
    @State private var glow: Float = 0.6

    var body: some View {
        NavigationStack {
            VStack {
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    TimelineView(.animation) { tl in
                        Canvas { ctx, size in
                            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                            ctx.withCGContext { cg in
                                cg.scaleBy(x: size.width, y: size.height)
                                var preview = drawing
                                if current.count > 1 { preview.strokes.append(stroke(current)) }
                                // Same unit-space widths as the 1024px projection texture.
                                DrawingRenderer.draw(preview, in: cg, time: tl.date.timeIntervalSinceReferenceDate,
                                                     pixelScale: CGFloat(DrawingRenderer.size))
                            }
                        }
                    }
                    .frame(width: side, height: side)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            current.append(SIMD2(Float(v.location.x / side), Float(v.location.y / side)))
                        }
                        .onEnded { _ in
                            if current.count > 1 {
                                drawing.strokes.append(stroke(Polygon.simplify(current, tolerance: 0.0015)))
                            }
                            current = []
                        })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Form {
                    ColorPicker("Color", selection: $color)
                    LabeledContent("Width") { Slider(value: $width, in: 2...40) }
                    LabeledContent("Glow") { Slider(value: $glow, in: 0...1) }
                    Picker("Animation", selection: $drawing.animation) {
                        ForEach(DrawingAnimation.allCases) { Text($0.rawValue).tag($0) }
                    }
                    LabeledContent("Cycle (s)") { Slider(value: $drawing.period, in: 0.5...12) }
                }
                .frame(maxHeight: 280)
            }
            .navigationTitle("Drawing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    HStack {
                        Button("Undo", systemImage: "arrow.uturn.backward") { _ = drawing.strokes.popLast() }
                        Button("Clear", systemImage: "trash") { drawing.strokes = [] }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save(); dismiss() } }
            }
        }
        .onAppear(perform: load)
    }

    private func stroke(_ pts: [SIMD2<Float>]) -> Stroke {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        // Width is in pixels of the 1024px drawing texture.
        return Stroke(points: pts, color: SIMD4(Float(r), Float(g), Float(b), Float(a)), width: width * 2, glow: glow)
    }

    private func load() {
        if let layer = engine.content(for: surfaceID).layers.first(where: { $0.id == layerID }),
           case .drawing(let d) = layer.source {
            drawing = d
        }
    }

    private func save() {
        engine.updateContent(surfaceID: surfaceID) { c in
            if let i = c.layers.firstIndex(where: { $0.id == layerID }) { c.layers[i].source = .drawing(drawing) }
        }
    }
}
