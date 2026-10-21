import SwiftUI

/// Scene strip along the bottom of the editor. Tap to switch live (with the project's transition).
struct ScenesBar: View {
    @EnvironmentObject var engine: Engine
    @State private var renaming: MapScene?
    @State private var newName = ""

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Transition", selection: $engine.project.transition.style) {
                    ForEach(TransitionStyle.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Duration", selection: $engine.project.transition.duration) {
                    ForEach([0.5, 1.0, 1.5, 2.0, 3.0, 5.0], id: \.self) { Text("\($0, specifier: "%.1f") s").tag($0) }
                }
            } label: {
                Label(engine.project.transition.style.rawValue.capitalized, systemImage: "rectangle.2.swap")
                    .font(.caption)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(engine.project.scenes.enumerated()), id: \.element.id) { i, scene in
                        sceneButton(scene, index: i)
                    }
                    Button { engine.addScene() } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .alert("Rename scene", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let id = renaming?.id, let i = engine.project.sceneIndex(id) { engine.project.scenes[i].name = newName }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func sceneButton(_ scene: MapScene, index: Int) -> some View {
        let active = scene.id == engine.project.activeSceneID
        let incoming = scene.id == engine.transitionTargetID
        return Button { engine.goToScene(scene.id) } label: {
            VStack(spacing: 2) {
                Text(scene.name).font(.subheadline.weight(active ? .bold : .regular)).lineLimit(1)
                Text("\(index + 1)").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(minWidth: 84, minHeight: 44)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(active ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(incoming ? Color.yellow : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename", systemImage: "pencil") { newName = scene.name; renaming = scene }
            Button("Duplicate", systemImage: "plus.square.on.square") { engine.addScene(duplicating: scene) }
            Button("Delete", systemImage: "trash", role: .destructive) { engine.deleteScene(scene.id) }
        }
    }
}
