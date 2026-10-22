import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Slider for a `Param` with a modulation menu (audio, LFO, envelope, macro, MIDI, tracking).
struct ParamControl: View {
    @EnvironmentObject var engine: Engine
    let title: String
    @Binding var param: Param
    var range: ClosedRange<Float> = 0...1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: "%.2f", param.base)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                modulationMenu
            }
            Slider(value: $param.base, in: range)
            if let mod = param.modulation {
                HStack {
                    Image(systemName: "waveform.path").foregroundStyle(.pink)
                    Text(mod.source.displayName).font(.caption)
                    Slider(value: Binding(get: { mod.depth }, set: { param.modulation?.depth = $0 }),
                           in: -(range.upperBound - range.lowerBound)...(range.upperBound - range.lowerBound))
                }
            }
        }
    }

    private var modulationMenu: some View {
        Menu {
            if param.modulation != nil {
                Button("Remove modulation", systemImage: "xmark", role: .destructive) { param.modulation = nil }
            }
            Button("MIDI learn (move a knob)", systemImage: "pianokeys") {
                let span = range.upperBound - range.lowerBound
                engine.learnMIDI { source in param.modulation = Modulation(source: source, depth: span) }
            }
            Section("Modulate with") {
                ForEach(ModSource.pickerSources, id: \.self) { src in
                    Button(src.displayName) {
                        param.modulation = Modulation(source: src, depth: (range.upperBound - range.lowerBound) * 0.5)
                        if src.needsTracking { engine.trackingEnabled = true }
                        if src.needsAudio { engine.audioInputEnabled = true }
                    }
                }
            }
        } label: {
            Image(systemName: param.modulation == nil ? "dial.low" : "dial.high.fill")
                .foregroundStyle(param.modulation == nil ? Color.secondary : Color.pink)
        }
    }
}

extension ModSource {
    var needsTracking: Bool { [.handX, .handY, .pinch, .faceX, .faceY, .mouthOpen].contains(self) }
    var needsAudio: Bool { [.audioLevel, .audioBass, .audioMid, .audioHigh].contains(self) }
}

struct ColorControl: View {
    let title: String
    @Binding var color: SIMD4<Float>

    var body: some View {
        ColorPicker(title, selection: Binding(
            get: { Color(red: Double(color.x), green: Double(color.y), blue: Double(color.z), opacity: Double(color.w)) },
            set: { c in
                let ui = UIColor(c)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                ui.getRed(&r, green: &g, blue: &b, alpha: &a)
                color = SIMD4(Float(r), Float(g), Float(b), Float(a))
            }))
    }
}

struct LevelMeter: View {
    let label: String
    let value: Float
    var tint: Color = .green

    var body: some View {
        HStack {
            Text(label).font(.caption).frame(width: 64, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(tint).frame(width: g.size.width * CGFloat(max(0, min(1, value))))
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - Media import

struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieFile(url: copy)
        }
    }
}

enum ImportedMedia {
    case photo(UUID, Data)
    case video(UUID)
}

enum MediaImporter {
    /// Copies a picked photo or video into the project's asset store.
    static func load(_ item: PhotosPickerItem) async throws -> ImportedMedia? {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            guard let movie = try await item.loadTransferable(type: MovieFile.self) else { return nil }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            return .video(try ProjectStore.shared.importAsset(from: movie.url))
        }
        guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return nil }
        // Normalise orientation and format by re-encoding as PNG.
        let id = try ProjectStore.shared.importImage(image.normalizedOrientation())
        return .photo(id, data)
    }
}

extension UIImage {
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        return UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = scale; return f }())
            .image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
