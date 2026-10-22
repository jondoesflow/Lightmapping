import PhotosUI
import SwiftUI

struct SurfaceInspector: View {
    @EnvironmentObject var engine: Engine
    @State private var addingPreset = false
    @State private var mediaItem: PhotosPickerItem?
    @State private var editingDrawingLayer: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if let surface = engine.selectedSurface {
                    form(surface)
                } else {
                    surfaceList
                }
            }
            .navigationTitle(engine.selectedSurface?.name ?? "Surfaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if engine.selectedSurface != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("All", systemImage: "chevron.left") { engine.selectedSurfaceID = nil }
                    }
                }
            }
        }
        .sheet(isPresented: $addingPreset) {
            PresetBrowser { preset in
                guard let id = engine.selectedSurfaceID else { return }
                engine.updateContent(surfaceID: id) { $0.layers.append(preset.makeLayer()) }
            }
        }
        .sheet(item: Binding(get: { editingDrawingLayer.map(IdentifiedID.init) }, set: { editingDrawingLayer = $0?.id })) { item in
            if let surfaceID = engine.selectedSurfaceID {
                DrawingEditor(surfaceID: surfaceID, layerID: item.id).environmentObject(engine)
            }
        }
    }

    private var surfaceList: some View {
        List {
            if engine.project.surfaces.isEmpty {
                Text("Add a surface with the + button, then drag its corners onto your wall, object or window.")
                    .foregroundStyle(.secondary)
            }
            ForEach(engine.project.surfaces.reversed()) { s in
                Button {
                    engine.selectedSurfaceID = s.id
                } label: {
                    HStack {
                        Image(systemName: s.isVisible ? "eye" : "eye.slash")
                        Text(s.name)
                        Spacer()
                        Text(s.shape.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func form(_ surface: Surface) -> some View {
        let id = surface.id
        let binding = Binding<Surface>(
            get: { engine.project.surfaces.first { $0.id == id } ?? surface },
            set: { new in engine.updateSurface(id) { $0 = new } })
        Form {
            Section("Surface") {
                TextField("Name", text: binding.name)
                Toggle("Visible", isOn: binding.isVisible)
                Toggle("Lock position", isOn: binding.isLocked)
                LabeledContent("Opacity") { Slider(value: binding.opacity, in: 0...1) }
                LabeledContent("Soft edge") { Slider(value: binding.feather, in: 0...0.25) }
                Picker("Warp grid", selection: Binding(
                    get: { surface.mesh.columns },
                    set: { n in engine.updateSurface(id) { $0.mesh = $0.mesh.resampled(columns: n, rows: n) } })) {
                    Text("Corners").tag(2)
                    Text("3 × 3").tag(3)
                    Text("4 × 4").tag(4)
                    Text("5 × 5").tag(5)
                }
                if !surface.cutouts.isEmpty {
                    Button("Clear \(surface.cutouts.count) cutout(s)", role: .destructive) {
                        engine.updateSurface(id) { $0.cutouts = [] }
                    }
                }
                HStack {
                    Button("Forward", systemImage: "square.2.layers.3d.top.filled") { engine.moveSurface(id, by: 1) }
                    Button("Back", systemImage: "square.2.layers.3d.bottom.filled") { engine.moveSurface(id, by: -1) }
                }
                .buttonStyle(.bordered)
                HStack {
                    Button("Duplicate", systemImage: "plus.square.on.square") { engine.duplicateSurface(id) }
                    Button("Delete", systemImage: "trash", role: .destructive) { engine.deleteSurface(id) }
                }
                .buttonStyle(.bordered)
            }

            Section {
                let layers = engine.content(for: id).layers
                ForEach(layers) { layer in
                    NavigationLink {
                        LayerEditor(surfaceID: id, layerID: layer.id, editDrawing: { editingDrawingLayer = layer.id })
                            .environmentObject(engine)
                    } label: {
                        HStack {
                            Image(systemName: icon(for: layer.source))
                            Text(layer.name)
                            Spacer()
                            if !layer.isVisible { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
                        }
                    }
                }
                .onDelete { idx in engine.updateContent(surfaceID: id) { c in
                    let ids = idx.map { layers[$0].id }
                    c.layers.removeAll { ids.contains($0.id) }
                } }
                .onMove { from, to in engine.updateContent(surfaceID: id) { $0.layers.move(fromOffsets: from, toOffset: to) } }

                Menu {
                    Button("Visual library", systemImage: "sparkles") { addingPreset = true }
                    PhotosPicker(selection: $mediaItem, matching: .any(of: [.images, .videos])) {
                        Label("Photo or video", systemImage: "photo.on.rectangle")
                    }
                    Button("Live camera", systemImage: "camera") { addLayer(Layer(name: "Camera", source: .camera(.back)), to: id) }
                    Button("Front camera", systemImage: "camera.rotate") { addLayer(Layer(name: "Front camera", source: .camera(.front)), to: id) }
                    Button("Hand drawing", systemImage: "pencil.and.scribble") {
                        let layer = Layer(name: "Drawing", source: .drawing(Drawing()))
                        addLayer(layer, to: id)
                        editingDrawingLayer = layer.id
                    }
                } label: {
                    Label("Add layer", systemImage: "plus")
                }
            } header: {
                Text("Layers in \(engine.project.activeScene?.name ?? "scene") (top draws last)")
            }
        }
        .onChange(of: mediaItem) { _, item in
            guard let item else { return }
            Task {
                if let media = try? await MediaImporter.load(item) {
                    switch media {
                    case .photo(let assetID, _): addLayer(Layer(name: "Photo", source: .photo(assetID: assetID)), to: id)
                    case .video(let assetID): addLayer(Layer(name: "Video", source: .video(assetID: assetID)), to: id)
                    }
                }
                mediaItem = nil
            }
        }
    }

    private func addLayer(_ layer: Layer, to surfaceID: UUID) {
        engine.updateContent(surfaceID: surfaceID) { $0.layers.append(layer) }
    }

    private func icon(for source: ContentSource) -> String {
        switch source {
        case .generator: return "sparkles"
        case .video: return "film"
        case .photo: return "photo"
        case .camera: return "camera"
        case .drawing: return "pencil.and.scribble"
        }
    }
}

struct IdentifiedID: Identifiable { let id: UUID }

struct LayerEditor: View {
    @EnvironmentObject var engine: Engine
    let surfaceID: UUID
    let layerID: UUID
    let editDrawing: () -> Void

    private var layer: Binding<Layer>? {
        guard engine.content(for: surfaceID).layers.contains(where: { $0.id == layerID }) else { return nil }
        return Binding(
            get: { engine.content(for: surfaceID).layers.first { $0.id == layerID }! },
            set: { new in engine.updateContent(surfaceID: surfaceID) { c in
                if let i = c.layers.firstIndex(where: { $0.id == layerID }) { c.layers[i] = new }
            } })
    }

    var body: some View {
        if let layer {
            Form {
                Section("Layer") {
                    TextField("Name", text: layer.name)
                    Toggle("Visible", isOn: layer.isVisible)
                    ParamControl(title: "Opacity", param: layer.opacity)
                    Picker("Blend", selection: layer.blend) {
                        ForEach(BlendMode.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Fit", selection: layer.fit) {
                        ForEach(FitMode.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }

                sourceSection(layer)

                Section("Crop") {
                    LabeledContent("Left") { Slider(value: layer.crop.x, in: 0...0.95) }
                    LabeledContent("Top") { Slider(value: layer.crop.y, in: 0...0.95) }
                    LabeledContent("Width") { Slider(value: layer.crop.z, in: 0.05...1) }
                    LabeledContent("Height") { Slider(value: layer.crop.w, in: 0.05...1) }
                }

                Section("Effects") {
                    ForEach(layer.wrappedValue.effects) { effect in
                        if let i = layer.wrappedValue.effects.firstIndex(where: { $0.id == effect.id }) {
                            HStack {
                                Toggle("", isOn: layer.effects[i].isEnabled).labelsHidden()
                                ParamControl(title: effect.kind.displayName, param: layer.effects[i].amount, range: effect.kind.range)
                            }
                        }
                    }
                    .onDelete { layer.wrappedValue.effects.remove(atOffsets: $0) }
                    Menu {
                        ForEach(EffectKind.allCases) { kind in
                            Button(kind.displayName) { layer.wrappedValue.effects.append(Effect(kind: kind)) }
                        }
                    } label: { Label("Add effect", systemImage: "plus") }
                }
            }
            .navigationTitle(layer.wrappedValue.name)
        } else {
            Text("Layer removed").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func sourceSection(_ layer: Binding<Layer>) -> some View {
        switch layer.wrappedValue.source {
        case .generator(let kind):
            Section("Visual · \(kind.displayName)") {
                Picker("Pattern", selection: Binding(get: { kind }, set: { layer.wrappedValue.source = .generator($0) })) {
                    ForEach(GeneratorKind.allCases) { Text($0.displayName).tag($0) }
                }
                ParamControl(title: "Speed", param: layer.generator.speed, range: 0...4)
                ParamControl(title: "Scale", param: layer.generator.scale, range: 0.1...4)
                ParamControl(title: "Intensity", param: layer.generator.intensity, range: 0...2)
                ColorControl(title: "Color A", color: layer.generator.colorA)
                ColorControl(title: "Color B", color: layer.generator.colorB)
                ColorControl(title: "Background", color: layer.generator.colorC)
                if kind.isShapeAware {
                    Text("Follows this surface's shape and depth.").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .camera(let pos):
            Section("Camera") {
                Picker("Camera", selection: Binding(get: { pos }, set: { layer.wrappedValue.source = .camera($0) })) {
                    Text("Back").tag(CameraPosition.back)
                    Text("Front").tag(CameraPosition.front)
                }
                .pickerStyle(.segmented)
            }
        case .drawing:
            Section("Drawing") { Button("Edit drawing", systemImage: "pencil", action: editDrawing) }
        case .video, .photo:
            EmptyView()
        }
    }
}
