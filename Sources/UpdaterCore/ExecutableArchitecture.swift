import Foundation
import Darwin

public enum ExecutableArchitecture {
    public static func read(appPath: String) throws -> Set<CatalogArchitecture> {
        let root = URL(fileURLWithPath: appPath)
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        guard let name = info?["CFBundleExecutable"] as? String, !name.isEmpty, name != ".", name != "..", !name.contains("/"), name.utf8.count <= 255 else { throw UpdaterError("No constrained application executable was found.") }
        let path = root.appendingPathComponent("Contents/MacOS/" + name).path
        guard ToolLocator.canonicalPath(path).hasPrefix(ToolLocator.canonicalPath(appPath) + "/Contents/MacOS/") else { throw UpdaterError("The application executable resolves outside its bundle.") }
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw UpdaterError("The application executable cannot be read safely.") }
        defer { close(descriptor) }
        var infoBuffer = stat()
        guard fstat(descriptor, &infoBuffer) == 0, infoBuffer.st_mode & S_IFMT == S_IFREG,
              let bytes = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: 4096) else { throw UpdaterError("The executable is not a readable regular file.") }
        return try parse(bytes)
    }
    @_spi(Testing) public static func parse(_ bytes: Data) throws -> Set<CatalogArchitecture> {
        let bytes = Array(bytes.prefix(4096))
        func word(_ offset: Int, little: Bool = false) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= bytes.count else { throw UpdaterError("Truncated Mach-O architecture header.") }
            let slice = Array(bytes[offset..<(offset + 4)])
            let ordered = little ? slice.reversed().map { $0 } : slice
            return ordered.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        func architecture(_ cpu: UInt32) -> CatalogArchitecture? {
            cpu == 0x0100000c ? .arm64 : cpu == 0x01000007 ? .x86_64 : nil
        }
        let magic = try word(0)
        if magic == 0xcffaedfe || magic == 0xfeedfacf {
            guard let arch = architecture(try word(4, little: magic == 0xcffaedfe)) else { throw UpdaterError("Unsupported executable architecture.") }
            return [arch]
        }
        let little = magic == 0xbebafeca || magic == 0xbfbafeca
        let fat64 = magic == 0xcafebabf || magic == 0xbfbafeca
        guard [0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) else { throw UpdaterError("Unsupported Mach-O format.") }
        let count = Int(try word(4, little: little))
        guard (1...16).contains(count), bytes.count >= 8 + count * (fat64 ? 32 : 20) else { throw UpdaterError("Unsupported universal executable header.") }
        var result = Set<CatalogArchitecture>()
        for index in 0..<count {
            if let arch = architecture(try word(8 + index * (fat64 ? 32 : 20), little: little)) { result.insert(arch) }
        }
        guard !result.isEmpty else { throw UpdaterError("No supported executable architecture.") }
        return result
    }
}
