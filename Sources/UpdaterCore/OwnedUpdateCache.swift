import Foundation
import Darwin

/// A separate cache per update prevents cleanup from touching another attempt's
/// downloads, including failed attempts. No shared Homebrew cleanup is invoked.
public struct OwnedUpdateCache {
    public let folder: URL
    private let root: URL
    private let identity: UUID
    // A copied marker must not authorize deleting a replacement directory.
    private let rootDirectory: DirectoryIdentity
    private let operationDirectory: DirectoryIdentity
    private struct Marker: Codable, Equatable { var id: UUID; var owner: String }
    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ url: URL) throws {
            var attributes = stat()
            guard lstat(url.path, &attributes) == 0,
                  attributes.st_mode & S_IFMT == S_IFDIR else {
                throw UpdaterError("The update cache directory could not be verified. Cleanup was blocked.")
            }
            device = attributes.st_dev
            inode = attributes.st_ino
        }
        init(descriptor: Int32) throws {
            var attributes = stat()
            guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR else {
                throw UpdaterError("The update cache directory could not be verified. Cleanup was blocked.")
            }
            device = attributes.st_dev; inode = attributes.st_ino
        }
    }
    public init(root: URL, id: UUID = UUID()) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.identity = id
        rootDirectory = try DirectoryIdentity(self.root)
        folder = self.root.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !fm.fileExists(atPath: folder.path) else { throw UpdaterError("Update cache already exists. Existing artifacts were retained.") }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        operationDirectory = try DirectoryIdentity(folder)
        try JSONEncoder().encode(Marker(id: id, owner: "UnifiedUpdater-0.1.0")).write(to: folder.appendingPathComponent(".owner.json"), options: .atomic)
    }
    public func removeAfterVerification(verified: Bool) throws {
        try removeAfterVerification(verified: verified, afterValidation: {})
    }
    // The testing SPI lets fixture checks replace names at the exact point
    // where the former path-based removal could address a different directory.
    @_spi(Testing) public func removeAfterVerification(verified: Bool, afterValidation: () throws -> Void) throws {
        guard verified else { throw UpdaterError("Cleanup requires a verified update.") }
        guard folder.deletingLastPathComponent().path == root.path,
              folder.lastPathComponent == identity.uuidString,
              folder.standardizedFileURL.resolvingSymlinksInPath().path == folder.path else { throw Self.changed }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Self.changed }
        defer { close(rootFD) }
        guard try DirectoryIdentity(descriptor: rootFD) == rootDirectory else { throw Self.changed }
        let attemptFD = openat(rootFD, identity.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard attemptFD >= 0 else { throw Self.changed }
        defer { close(attemptFD) }
        guard try DirectoryIdentity(descriptor: attemptFD) == operationDirectory else { throw Self.changed }
        let markerFD = openat(attemptFD, ".owner.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard markerFD >= 0 else { throw Self.changed }
        defer { close(markerFD) }
        var markerInfo = stat()
        guard fstat(markerFD, &markerInfo) == 0, markerInfo.st_mode & S_IFMT == S_IFREG,
              markerInfo.st_size > 0, markerInfo.st_size <= 4096 else { throw Self.changed }
        let markerData = try FileHandle(fileDescriptor: markerFD, closeOnDealloc: false).read(upToCount: 4097) ?? Data()
        guard markerData.count <= 4096,
              try JSONDecoder().decode(Marker.self, from: markerData) == Marker(id: identity, owner: "UnifiedUpdater-0.1.0") else {
            throw UpdaterError("Cache ownership could not be verified.")
        }
        try afterValidation()
        try Self.removeFiles(from: attemptFD, device: operationDirectory.device, keepMarker: true)
    }
    private static var changed: UpdaterError {
        UpdaterError("The update cache location or contents changed. Cleanup was blocked.")
    }
    private static func removeFiles(from descriptor: Int32, device: dev_t, keepMarker: Bool) throws {
        let scanFD = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard scanFD >= 0 else { throw changed }
        guard let directory = fdopendir(scanFD) else { close(scanFD); throw changed }
        defer { closedir(directory) }
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw changed }
                return
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || (keepMarker && name == ".owner.json") { continue }
            var observed = stat()
            guard fstatat(descriptor, name, &observed, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw changed
            }
            if observed.st_mode & S_IFMT == S_IFDIR {
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw changed }
                defer { close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR,
                      opened.st_dev == device, opened.st_dev == observed.st_dev,
                      opened.st_ino == observed.st_ino else { throw changed }
                try removeFiles(from: child, device: device, keepMarker: false)
            } else {
                // unlinkat removes this entry within the held parent directory;
                // it never follows a symlink to its target.
                guard unlinkat(descriptor, name, 0) == 0 || errno == ENOENT else { throw changed }
            }
        }
        // Directory entries and the root ownership marker are deliberately kept.
        // POSIX has no atomic inode-conditional rmdir; a later pathname rmdir
        // would reintroduce the replacement race even after an identity check.
    }
}
