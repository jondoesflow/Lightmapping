import SwiftUI

struct PresetBrowser: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (VisualPreset) -> Void
    @State private var category: PresetCategory = .vj

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(PresetCategory.allCases) { c in
                            Button(c.rawValue) { category = c }
                                .buttonStyle(.bordered)
                                .tint(c == category ? .accentColor : .gray)
                        }
                    }
                    .padding()
                }
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(PresetLibrary.presets(in: category)) { p in
                            Button {
                                onPick(p)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    swatch(p).frame(height: 80).clipShape(RoundedRectangle(cornerRadius: 10))
                                    Text(p.name).font(.subheadline).lineLimit(1)
                                    Text(p.kind.displayName).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Visual library (\(PresetLibrary.all.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func swatch(_ p: VisualPreset) -> some View {
        func c(_ v: SIMD4<Float>) -> Color { Color(red: Double(v.x), green: Double(v.y), blue: Double(v.z)) }
        return ZStack {
            LinearGradient(colors: [c(p.colors.2), c(p.colors.0), c(p.colors.1)], startPoint: .bottomLeading, endPoint: .topTrailing)
            if p.audioReactive { Image(systemName: "waveform").foregroundStyle(.white.opacity(0.8)) }
            if p.kind.isShapeAware { Image(systemName: "square.on.circle").foregroundStyle(.white.opacity(0.8)) }
        }
    }
}
