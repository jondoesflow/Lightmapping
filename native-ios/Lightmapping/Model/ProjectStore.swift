import Foundation
import UIKit

/// Saves projects as JSON and keeps imported media (videos, photos, masks, depth maps,
/// audio) in an asset folder referenced by UUID.
final class ProjectStore {
    static let shared = ProjectStore()

    let root: URL
    let projectsDir: URL
    let assetsDir: URL
    let exportsDir: URL
    let receivedDir: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(root: URL? = nil) {
        let fm = FileManager.default
        self.root = root ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        projectsDir = self.root.appendingPathComponent("Projects", isDirectory: true)
        assetsDir = self.root.appendingPathComponent("Assets", isDirectory: true)
        exportsDir = self.root.appendingPathComponent("Exports", isDirectory: true)
        receivedDir = self.root.appendingPathComponent("Received Shows", isDirectory: true)
        for dir in [projectsDir, assetsDir, exportsDir, receivedDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: Projects

    func listProjects() -> [Project] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Project.self, from: Data(contentsOf: $0)) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func save(_ project: Project) throws {
        var p = project
        p.modifiedAt = Date()
        let data = try encoder.encode(p)
        try data.write(to: projectsDir.appendingPathComponent("\(p.id.uuidString).json"), options: .atomic)
    }

    func delete(_ project: Project) {
        try? FileManager.default.removeItem(at: projectsDir.appendingPathComponent("\(project.id.uuidString).json"))
    }

    // MARK: Assets

    func assetURL(_ id: UUID) -> URL? {
        let urls = (try? FileManager.default.contentsOfDirectory(at: assetsDir, includingPropertiesForKeys: nil)) ?? []
        return urls.first { $0.deletingPathExtension().lastPathComponent == id.uuidString }
    }

    /// Copies a file into the asset store and returns its new ID.
    func importAsset(from url: URL) throws -> UUID {
        let id = UUID()
        let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
        let dest = assetsDir.appendingPathComponent("\(id.uuidString).\(ext)")
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: url, to: dest)
        return id
    }

    func importImage(_ image: UIImage) throws -> UUID {
        let id = UUID()
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: assetsDir.appendingPathComponent("\(id.uuidString).png"))
        return id
    }

    func importData(_ data: Data, ext: String) throws -> UUID {
        let id = UUID()
        try data.write(to: assetsDir.appendingPathComponent("\(id.uuidString).\(ext)"))
        return id
    }

    func image(_ id: UUID) -> UIImage? {
        assetURL(id).flatMap { UIImage(contentsOfFile: $0.path) }
    }
}
