import Foundation

/// A separate cache per update prevents cleanup from touching another attempt's
/// downloads, including failed attempts. No shared Homebrew cleanup is invoked.
public struct OwnedUpdateCache {
    public let folder: URL
    private let root: URL
    private let identity: UUID
    private struct Marker: Codable, Equatable { var id: UUID; var owner: String }
    public init(root: URL, id: UUID = UUID()) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.identity = id
        folder = self.root.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !fm.fileExists(atPath: folder.path) else { throw UpdaterError("Update cache already exists. Existing artifacts were retained.") }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Marker(id: id, owner: "UnifiedUpdater-0.1.0")).write(to: folder.appendingPathComponent(".owner.json"), options: .atomic)
    }
    public func removeAfterVerification(verified: Bool) throws {
        guard verified else { throw UpdaterError("Cleanup requires a verified update.") }
        guard folder.deletingLastPathComponent().path == root.path,
              folder.lastPathComponent == identity.uuidString,
              folder.standardizedFileURL.resolvingSymlinksInPath().path == folder.path,
              !(try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false) else {
            throw UpdaterError("The update cache location changed. Cleanup was blocked.")
        }
        let marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: folder.appendingPathComponent(".owner.json")))
        guard marker == Marker(id: identity, owner: "UnifiedUpdater-0.1.0") else { throw UpdaterError("Cache ownership could not be verified.") }
        try FileManager.default.removeItem(at: folder)
    }
}
