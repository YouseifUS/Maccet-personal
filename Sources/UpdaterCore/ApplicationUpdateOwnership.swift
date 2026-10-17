import Foundation
import CryptoKit
import Darwin

/// A kernel-held advisory lock shared by Maccet instances for this user.
/// Lock files stay in place: unlinking on release could create two lock inodes.
final class ApplicationUpdateOwnership {
    private var descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { release() }
    func release() {
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
    }
    static func acquire(for path: String) throws -> ApplicationUpdateOwnership? {
        let root = "/private/tmp/maccet-update-locks-\(getuid())"
        guard mkdir(root, 0o700) == 0 || errno == EEXIST else { throw failure }
        let directory = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw failure }
        defer { close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid(), directoryInfo.st_mode & 0o077 == 0 else { throw failure }
        let canonical = ToolLocator.canonicalPath(path)
        let key = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let descriptor = openat(directory, key, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure }
        var retained = false
        defer { if !retained { close(descriptor) } }
        var file = stat()
        var location = stat()
        guard fstat(descriptor, &file) == 0, file.st_mode & S_IFMT == S_IFREG,
              file.st_uid == getuid(), file.st_mode & 0o077 == 0, file.st_nlink == 1,
              fstatat(directory, key, &location, AT_SYMLINK_NOFOLLOW) == 0,
              location.st_dev == file.st_dev, location.st_ino == file.st_ino else { throw failure }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return nil }
            throw failure
        }
        retained = true
        return ApplicationUpdateOwnership(descriptor: descriptor)
    }
    private static var failure: UpdaterError {
        UpdaterError("Exclusive update ownership could not be established. No installation was started. Close other Maccet instances and review a new plan.")
    }
}
