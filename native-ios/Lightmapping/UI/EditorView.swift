import PhotosUI
import SwiftUI

struct EditorView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var model: AppModel

    @State private var tool: CanvasTool = .select
    @State private var showInspector = false
    @State private var sheet: Sheet?
    @State private var textPrompt = false
    @State private var newText = "HELLO"
    @State private var shapePhoto: PhotosPickerItem?
    @State private var shapeMode: ShapeMode = .silhouette
    @State private var showShapePicker = false
    @State private var busy: String?
    @State private var errorMessage: String?

    enum Sheet: String, Identifiable { case perform, timeline, export, settings; var id: String { rawValue } }
    enum ShapeMode { case silhouette, depth }

    var body: some View {
        ZStack {
            MappingCanvas(tool: $tool)
            VStack(spacing: 0) {
                topBar
                Spacer()
                if tool != .select { drawingHint }
                ScenesBar()
            }
            if let busy {
                ProgressView(busy).padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .inspector(isPresented: $showInspector) {
            SurfaceInspector()
                .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .onChange(of: engine.selectedSurfaceID) { _, id in if id != nil { showInspector = true } }
        .sheet(item: $sheet) { s in
            Group {
                switch s {
                case .perform: PerformView()
                case .timeline: TimelineEditor()
                case .export: ExportView()
                case .settings: SettingsView()
                }
            }
            .environmentObject(engine)
        }
        .alert("Text surface", isPresented: $textPrompt) {
            TextField("Text", text: $newText)
            Button("Add") { engine.addSurface(.text(newText, fontName: "Futura-CondensedExtraBold")) }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showShapePicker, selection: $shapePhoto, matching: .images)
        .onChange(of: shapePhoto) { _, item in
            guard let item else { return }
            Task { await makeShape(from: item) }
            shapePhoto = nil
        }
        .alert("Couldn't create shape", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(errorMessage ?? "") }
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { model.close() } label: { Image(systemName: "square.grid.2x2") }
            Text(engine.project.name).font(.headline).lineLimit(1)
            if engine.externalDisplayConnected {
                Label("Projector", systemImage: "tv.inset.filled").font(.caption).foregroundStyle(.green)
            }
            Spacer()
            addMenu
            if engine.selectedSurface != nil {
                Button { tool = .drawCutout } label: { Image(systemName: "scissors") }
            }
            Button { engine.showOutlines.toggle() } label: {
                Image(systemName: engine.showOutlines ? "square.dashed.inset.filled" : "square.dashed")
            }
            Button { sheet = .perform } label: { Image(systemName: "play.square.stack") }
            Button { sheet = .timeline } label: { Image(systemName: "timeline.selection") }
            Button { sheet = .export } label: { Image(systemName: "square.and.arrow.up") }
            Button { sheet = .settings } label: { Image(systemName: "slider.horizontal.3") }
            Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
        }
        .font(.title3)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var addMenu: some View {
        Menu {
            Button("Square", systemImage: "square") { engine.addSurface(.quad) }
            Button("Circle", systemImage: "circle") { engine.addSurface(.circle) }
            Button("Text", systemImage: "textformat") { textPrompt = true }
            Button("Box / cube", systemImage: "cube") { engine.addBox() }
            Button("Draw outline", systemImage: "scribble") { tool = .drawOutline }
            Divider()
            Button("Silhouette from photo", systemImage: "person.crop.rectangle") { shapeMode = .silhouette; showShapePicker = true }
            Button("Depth shape from photo", systemImage: "cube.transparent") { shapeMode = .depth; showShapePicker = true }
        } label: {
            Image(systemName: "plus.circle.fill")
        }
    }

    private var drawingHint: some View {
        HStack {
            Text(tool == .drawOutline ? "Trace the outline of your object" : "Draw the area to cut out of the selected surface")
            Button("Cancel") { tool = .select }.buttonStyle(.bordered)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 8)
    }

    private func makeShape(from item: PhotosPickerItem) async {
        busy = shapeMode == .depth ? "Estimating depth…" : "Finding subject…"
        defer { busy = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let wantDepth = shapeMode == .depth
            let result = try await Task.detached { try await ShapeExtractor.extract(from: data, wantDepth: wantDepth) }.value
            let maskID = try ProjectStore.shared.importImage(result.mask)
            let h: Float = 0.6
            let w = h * result.aspect / engine.project.outputAspect
            let mesh = WarpMesh.rect(center: SIMD2(0.5, 0.5), size: SIMD2(w, h))
            if let depth = result.depth, wantDepth {
                let depthID = try ProjectStore.shared.importImage(depth)
                let preset = PresetLibrary.all.first { $0.id == "shape.depth.contours" }
                engine.addSurface(.depth(maskAssetID: maskID, depthAssetID: depthID), name: "Depth shape", mesh: mesh, preset: preset)
            } else {
                let preset = PresetLibrary.all.first { $0.id == "neon.edge.blue" }
                engine.addSurface(.silhouette(maskAssetID: maskID), name: "Silhouette", mesh: mesh, preset: preset)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
