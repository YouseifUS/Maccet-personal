import Foundation
import AppKit
import CryptoKit
import Darwin

/// Sparkle trust is read from the already-installed application bundle. No key
/// is accepted from the feed, the archive, or any network source.
public enum SparkleTrustKey {
    /// Returns the base64-decoded Ed25519 public key from `SUPublicEDKey`, if present and valid.
    public static func ed25519PublicKey(at appPath: String) -> Data? {
        let url = URL(fileURLWithPath: appPath).standardizedFileURL.resolvingSymlinksInPath()
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let string = info["SUPublicEDKey"] as? String else { return nil }
        return Data(base64Encoded: string)
    }

    /// Returns a SHA-256 fingerprint of the trusted Ed25519 public key bytes.
    public static func ed25519PublicKeyFingerprint(at appPath: String) -> String? {
        guard let key = ed25519PublicKey(at: appPath) else { return nil }
        return SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }
}

public struct SparkleSignatureVerifier {
    /// Verifies an EdDSA signature over the raw archive bytes using a trusted
    /// public key read from the installed bundle. DSA signatures are not supported.
    public static func verifyEdDSA(archive: Data, signature: String, publicKey: Data) throws {
        guard publicKey.count == 32 else { throw UpdaterError("The installed Sparkle EdDSA public key is invalid.") }
        guard let signatureData = Data(base64Encoded: signature), signatureData.count == 64 else { throw UpdaterError("The Sparkle release signature is malformed.") }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(signatureData, for: archive) else { throw UpdaterError("The downloaded archive does not match the trusted Sparkle signature.") }
    }
}

public protocol SparkleArchiveDownloading {
    func download(_ url: URL, expectedLength: Int?, maximumBytes: Int) async throws -> Data
}

/// Bounded HTTPS download for Sparkle archives. Redirects, credential challenges,
/// unexpected hosts and oversized responses are rejected before the body completes.
public struct SparkleArchiveDownloader: SparkleArchiveDownloading {
    public static let maximumBytes = 512 * 1024 * 1024
    public init() {}
    @_spi(Testing) public static func initialBufferCapacity(expectedLength: Int?, responseLength: Int64, limit: Int) -> Int {
        if let expectedLength { return min(max(expectedLength, 0), max(limit, 0)) }
        return responseLength > 0 ? min(Int(responseLength), max(limit, 0)) : 0
    }
    public func download(_ url: URL, expectedLength: Int?, maximumBytes: Int) async throws -> Data {
        try SparkleFeedLoader.validateURL(url)
        let limit = min(max(maximumBytes, 0), Self.maximumBytes)
        if let expectedLength {
            guard expectedLength > 0, expectedLength <= limit else { throw UpdaterError("Sparkle archive length is outside the supported range.") }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration, delegate: NoSparkleRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("application/zip, application/octet-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == url else {
            throw UpdaterError("Sparkle archive request was redirected or unsuccessful.")
        }
        let length = response.expectedContentLength
        guard length <= Int64(limit) else { throw UpdaterError("Sparkle archive exceeds the bounded size limit.") }
        var data = Data()
        let capacity = Self.initialBufferCapacity(expectedLength: expectedLength, responseLength: length, limit: limit)
        data.reserveCapacity(capacity)
        for try await byte in bytes {
            guard data.count < limit else { throw UpdaterError("Sparkle archive exceeded the bounded size limit while downloading.") }
            data.append(byte)
            if data.count % 65536 == 0 { try Task.checkCancellation() }
        }
        if let expectedLength, data.count != expectedLength { throw UpdaterError("Sparkle archive size does not match the feed declaration.") }
        return data
    }
}

private final class NoSparkleRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

/// Safety inspector for Sparkle ZIP archives. It parses the central directory
/// and rejects symlinks, traversal, absolute paths, unknown compression, sparse
/// layouts and multiple top-level applications before any bytes are extracted.
public enum SparkleArchiveInspector {
    public static let maximumEntries = 10_000

    public struct Entry: Equatable {
        public var name: String
        public var compression: UInt16
        public var compressedSize: UInt64
        public var uncompressedSize: UInt64
        public var externalAttributes: UInt32
        public var isDirectory: Bool
        public var isSymlink: Bool
        public var localHeaderOffset: UInt64
        public var generalPurposeBitFlag: UInt16
    }

    public static func inspect(_ archive: Data, maximumUncompressedBytes: Int) throws -> (entries: [Entry], topLevelApp: String) {
        guard archive.count >= 22 else { throw UpdaterError("Sparkle archive is too small to be a ZIP file.") }
        let (cdOffset, cdSize, entryCount, eocdOffset) = try locateCentralDirectory(archive)
        guard entryCount > 0 else { throw UpdaterError("Sparkle archive contains no entries.") }
        guard entryCount <= maximumEntries else { throw UpdaterError("Sparkle archive contains too many entries.") }
        guard cdOffset + cdSize <= UInt64(eocdOffset), UInt64(eocdOffset) <= UInt64(archive.count) else {
            throw UpdaterError("Sparkle archive central directory is out of bounds.")
        }
        var entries: [Entry] = []
        var offset = Int(cdOffset)
        var totalUncompressed: UInt64 = 0
        var topLevelApps = Set<String>()
        var seenPaths = Set<String>()
        for _ in 0..<entryCount {
            let entry = try readCentralDirectoryEntry(archive, offset: &offset)
            guard entry.compression == 0 || entry.compression == 8 else { throw UpdaterError("Sparkle archive uses an unsupported compression method.") }
            guard entry.generalPurposeBitFlag & 0b1001001 == 0 else {
                throw UpdaterError("Sparkle archive uses an unsupported ZIP feature (encryption or data descriptor).")
            }
            guard entry.name.utf8.count <= 4096 else { throw UpdaterError("Sparkle archive contains an entry name that is too long.") }
            guard entry.name.range(of: #"\A[\x20-\x7E/._-]+\z"#, options: .regularExpression) != nil else {
                throw UpdaterError("Sparkle archive contains a malformed entry name.")
            }
            guard !entry.name.isEmpty else { throw UpdaterError("Sparkle archive contains an entry with no name.") }
            guard !entry.name.hasPrefix("/") && !entry.name.hasPrefix("\\") else { throw UpdaterError("Sparkle archive contains an absolute path.") }
            guard !entry.name.contains("..") && !entry.name.hasPrefix("../") else { throw UpdaterError("Sparkle archive contains a traversal path.") }
            let normalizedName = entry.name.lowercased().precomposedStringWithCanonicalMapping
            guard seenPaths.insert(normalizedName).inserted else { throw UpdaterError("Sparkle archive contains duplicate or case-colliding paths.") }
            guard !entry.isSymlink else { throw UpdaterError("Sparkle archive contains a symlink.") }
            let components = entry.name.split(separator: "/", omittingEmptySubsequences: false)
            guard let top = components.first, top.hasSuffix(".app") else { throw UpdaterError("Sparkle archive entry is outside the expected application bundle.") }
            topLevelApps.insert(String(top))
            totalUncompressed += entry.uncompressedSize
            entries.append(entry)
        }
        guard topLevelApps.count == 1, let appName = topLevelApps.first else {
            throw UpdaterError(topLevelApps.isEmpty ? "Sparkle archive contains no application bundle." : "Sparkle archive contains multiple top-level applications.")
        }
        guard UInt64(offset) == cdOffset + cdSize else { throw UpdaterError("Sparkle archive central directory size is malformed.") }
        guard totalUncompressed <= UInt64(maximumUncompressedBytes) else { throw UpdaterError("Sparkle archive uncompressed size exceeds the limit.") }
        try validateLocalHeaders(archive, entries: entries, centralDirectoryOffset: cdOffset)
        return (entries, appName)
    }

    private static func locateCentralDirectory(_ archive: Data) throws -> (offset: UInt64, size: UInt64, entries: UInt16, eocdOffset: Int) {
        // Search backwards from the end for the EOCD signature.
        let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let minSize = 22
        let searchStart = max(minSize, archive.count) - minSize
        for start in (0...searchStart).reversed() {
            guard Array(archive[start..<(start + 4)]) == eocdSignature else { continue }
            let diskNumber = UInt16(littleEndian: archive, start + 4)
            let cdDisk = UInt16(littleEndian: archive, start + 6)
            let entriesOnDisk = UInt16(littleEndian: archive, start + 8)
            let totalEntries = UInt16(littleEndian: archive, start + 10)
            let size = UInt32(littleEndian: archive, start + 12)
            let offset = UInt32(littleEndian: archive, start + 16)
            let commentLength = UInt16(littleEndian: archive, start + 20)
            guard diskNumber == 0, cdDisk == 0, entriesOnDisk == totalEntries,
                  start + 22 + Int(commentLength) == archive.count,
                  size > 0, totalEntries > 0 else { continue }
            return (UInt64(offset), UInt64(size), totalEntries, start)
        }
        throw UpdaterError("Sparkle archive has no readable central directory.")
    }

    private static func readCentralDirectoryEntry(_ archive: Data, offset: inout Int) throws -> Entry {
        let signature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        guard offset + 46 <= archive.count, Array(archive[offset..<(offset + 4)]) == signature else {
            throw UpdaterError("Sparkle archive central directory entry is malformed.")
        }
        let versionMadeBy = UInt16(littleEndian: archive, offset + 4)
        let versionNeeded = UInt16(littleEndian: archive, offset + 6)
        let generalPurposeBitFlag = UInt16(littleEndian: archive, offset + 8)
        let compression = UInt16(littleEndian: archive, offset + 10)
        let compressedSize = UInt32(littleEndian: archive, offset + 20)
        let uncompressedSize = UInt32(littleEndian: archive, offset + 24)
        let nameLength = Int(UInt16(littleEndian: archive, offset + 28))
        let extraLength = Int(UInt16(littleEndian: archive, offset + 30))
        let commentLength = Int(UInt16(littleEndian: archive, offset + 32))
        let localHeaderOffset = UInt32(littleEndian: archive, offset + 42)
        let externalAttributes = UInt32(littleEndian: archive, offset + 38)
        let total = 46 + nameLength + extraLength + commentLength
        guard offset + total <= archive.count else { throw UpdaterError("Sparkle archive central directory entry is truncated.") }
        let name = String(decoding: archive[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
        // Reject ZIP64 and other extended formats by version or extra-field signature.
        guard versionNeeded < 45 else { throw UpdaterError("Sparkle archive uses an unsupported ZIP64 format.") }
        if extraLength > 0 {
            let extraStart = offset + 46 + nameLength
            let extra = archive[extraStart..<(extraStart + extraLength)]
            guard !extra.containsZIP64Header() else { throw UpdaterError("Sparkle archive contains a ZIP64 extra field.") }
        }
        // Treat archives created by tools that record version made by Unix as valid;
        // the external-file-attributes interpretation below is conservative.
        _ = versionMadeBy
        let mode = (externalAttributes >> 16) & 0o170000
        let isSymlink = mode == 0o120000
        let isDirectory = name.hasSuffix("/") || mode == 0o040000
        let entry = Entry(name: name, compression: compression, compressedSize: UInt64(compressedSize),
                          uncompressedSize: UInt64(uncompressedSize), externalAttributes: externalAttributes,
                          isDirectory: isDirectory, isSymlink: isSymlink, localHeaderOffset: UInt64(localHeaderOffset),
                          generalPurposeBitFlag: generalPurposeBitFlag)
        offset += total
        return entry
    }

    private static func validateLocalHeaders(_ archive: Data, entries: [Entry], centralDirectoryOffset: UInt64) throws {
        // Ensure local headers do not overlap the central directory and that each
        // header matches its central-directory record. This prevents ambiguous or
        // tampered layouts from exploiting the signed archive.
        guard !entries.isEmpty else { return }
        let sorted = entries.sorted { $0.localHeaderOffset < $1.localHeaderOffset }
        var previousEnd: UInt64 = 0
        for entry in sorted {
            let start = Int(entry.localHeaderOffset)
            guard start >= 0, start + 30 <= archive.count else {
                throw UpdaterError("Sparkle archive local header is out of bounds.")
            }
            guard Array(archive[start..<(start + 4)]) == [0x50, 0x4B, 0x03, 0x04] else {
                throw UpdaterError("Sparkle archive local header signature is missing.")
            }
            let localFlag = UInt16(littleEndian: archive, start + 6)
            let localCompression = UInt16(littleEndian: archive, start + 8)
            let localCompressed = UInt32(littleEndian: archive, start + 18)
            let localUncompressed = UInt32(littleEndian: archive, start + 22)
            let localNameLength = Int(UInt16(littleEndian: archive, start + 26))
            let localExtraLength = Int(UInt16(littleEndian: archive, start + 28))
            guard localFlag & 0b1001001 == 0 else { throw UpdaterError("Sparkle archive local header uses an unsupported feature.") }
            guard localCompression == entry.compression else { throw UpdaterError("Sparkle archive local/compression method mismatch.") }
            guard UInt64(localCompressed) == entry.compressedSize,
                  UInt64(localUncompressed) == entry.uncompressedSize else {
                throw UpdaterError("Sparkle archive local/compressed size mismatch.")
            }
            guard start + 30 + localNameLength + localExtraLength <= archive.count else {
                throw UpdaterError("Sparkle archive local header name is truncated.")
            }
            if localExtraLength > 0 {
                let extraStart = start + 30 + localNameLength
                let extra = archive[extraStart..<(extraStart + localExtraLength)]
                guard !extra.containsZIP64Header() else { throw UpdaterError("Sparkle archive contains a malformed or unsupported local ZIP extra field.") }
            }
            let localName = String(decoding: archive[(start + 30)..<(start + 30 + localNameLength)], as: UTF8.self)
            guard localName == entry.name else { throw UpdaterError("Sparkle archive local/central-directory name mismatch.") }
            let dataStart = UInt64(start + 30 + localNameLength + localExtraLength)
            let dataEnd = dataStart + entry.compressedSize
            guard dataEnd <= UInt64(archive.count) else { throw UpdaterError("Sparkle archive entry data is out of bounds.") }
            guard dataEnd <= centralDirectoryOffset else { throw UpdaterError("Sparkle archive entry data overlaps the central directory.") }
            guard entry.localHeaderOffset >= previousEnd || previousEnd == 0 else {
                throw UpdaterError("Sparkle archive local headers overlap.")
            }
            previousEnd = dataEnd
        }
    }
}

private extension Data {
    func containsZIP64Header() -> Bool {
        // Extra-field header id 0x0001 is ZIP64; scan 4-byte (id+size) chunks.
        var index = 0
        while index + 4 <= count {
            let id = UInt16(littleEndian: self, index)
            let size = UInt16(littleEndian: self, index + 2)
            guard index + 4 + Int(size) <= count else { return true } // Malformed extra field is unsafe.
            if id == 0x0001 { return true }
            index += 4 + Int(size)
        }
        return index != count
    }
}

private extension UInt16 {
    init(littleEndian data: Data, _ offset: Int) {
        self = data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
    }
}
private extension UInt32 {
    init(littleEndian data: Data, _ offset: Int) {
        self = data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var value: UInt32 = 0
            for index in 0..<4 { value |= UInt32(bytes[offset + index]) << (index * 8) }
            return value
        }
    }
}

/// Extracts a validated Sparkle ZIP archive using the system `unzip` tool. The
/// archive is first inspected; any rejected layout prevents extraction.
public enum SparkleArchiveExtractor {
    public static func extract(_ archive: Data, to directory: URL, maximumUncompressedBytes: Int = 512 * 1024 * 1024) throws -> URL {
        let (_, appName) = try SparkleArchiveInspector.inspect(archive, maximumUncompressedBytes: maximumUncompressedBytes)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archiveURL = directory.appendingPathComponent("download.zip")
        try archive.write(to: archiveURL, options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // Arguments are passed as an array; no shell interpolation is possible.
        process.arguments = ["-q", "-o", "-d", directory.path, archiveURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        try fm.removeItem(at: archiveURL)
        guard process.terminationStatus == 0 else { throw UpdaterError("Sparkle archive extraction failed.") }
        let appURL = directory.appendingPathComponent(appName)
        guard fm.fileExists(atPath: appURL.path) else { throw UpdaterError("Sparkle archive did not extract the expected application bundle.") }
        try rejectSymlinks(in: appURL)
        return appURL
    }

    private static func rejectSymlinks(in url: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return }
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true { throw UpdaterError("Sparkle archive extracted an unexpected symlink.") }
        }
    }
}

/// A validated Sparkle installation plan. The public key is not stored here;
/// it is read from the installed bundle at execution time. The fingerprint and
/// reviewed channel evidence bind the route to the trusted key and review.
public struct SparkleInstallPlan {
    public let app: AppRecord
    public let feedURL: URL
    public let archiveURL: URL
    public let archiveLength: Int?
    public let edSignature: String
    public let targetVersion: String
    public let targetBuild: String
    public let channel: String?
    public let channelReview: DiscoveryChannelReview?
    public let publicKeyFingerprint: String
    public let installedCanonicalPath: String
    let reviewedSignature: CodeSignatureEvidence
    public init(app: AppRecord, release: SparkleSelectedRelease, publicKeyFingerprint: String, channelReview: DiscoveryChannelReview?) throws {
        self.app = app
        guard let feed = app.sparkleFeed, let feedURL = URL(string: feed),
              let archiveURL = URL(string: release.archiveURL) else {
            throw UpdaterError("Sparkle install route has an invalid URL.")
        }
        self.feedURL = feedURL; self.archiveURL = archiveURL
        self.archiveLength = release.archiveLength
        self.edSignature = release.edSignature ?? ""
        self.targetVersion = release.version; self.targetBuild = release.build
        self.channel = release.channel
        self.channelReview = channelReview
        self.publicKeyFingerprint = publicKeyFingerprint
        self.installedCanonicalPath = ToolLocator.canonicalPath(app.path)
        self.reviewedSignature = CodeSignatureEvidence.capture(at: app.path)
    }
}

public protocol SparkleInstalling {
    func install(_ plan: SparkleInstallPlan, cacheRoot: URL) async throws -> AppRecord
}

/// Default Sparkle installer: download, verify signature, extract, replace,
/// verify. All file moves are within the same parent directory to allow atomic
/// rename. The original bundle is preserved until verification succeeds.
public struct SparkleInstaller: SparkleInstalling {
    private let downloader: any SparkleArchiveDownloading
    private let maximumArchiveBytes: Int
    private let maximumUncompressedBytes: Int
    private let isRunning: (AppRecord) async -> Bool
    /// Test-only hook invoked after the installed app has been moved to backup
    /// and before the staged update is swapped into place. Throwing here must
    /// leave the original app restored.
    private let mutationBoundaryHook: (() async throws -> Void)?
    public init(downloader: any SparkleArchiveDownloading = SparkleArchiveDownloader(), maximumArchiveBytes: Int = SparkleArchiveDownloader.maximumBytes, maximumUncompressedBytes: Int = 512 * 1024 * 1024, isRunning: @escaping (AppRecord) async -> Bool = Self.isRunning, mutationBoundaryHook: (() async throws -> Void)? = nil) {
        self.downloader = downloader; self.maximumArchiveBytes = maximumArchiveBytes; self.maximumUncompressedBytes = maximumUncompressedBytes; self.isRunning = isRunning; self.mutationBoundaryHook = mutationBoundaryHook
    }
    public func install(_ plan: SparkleInstallPlan, cacheRoot: URL) async throws -> AppRecord {
        try await revalidateInstalledIdentity(plan)
        let publicKey = try trustedPublicKey(plan)
        let cache = try OwnedUpdateCache(root: cacheRoot)
        defer { try? cache.removeAfterVerification(verified: false) }
        let archive = try await downloader.download(plan.archiveURL, expectedLength: plan.archiveLength, maximumBytes: maximumArchiveBytes)
        try SparkleSignatureVerifier.verifyEdDSA(archive: archive, signature: plan.edSignature, publicKey: publicKey)
        let extracted = try SparkleArchiveExtractor.extract(archive, to: cache.folder.appendingPathComponent("Extracted"), maximumUncompressedBytes: maximumUncompressedBytes)
        try await validateExtractedUpdate(extracted, plan: plan)
        // Re-read the installed application at the last possible boundary before mutation.
        try await revalidateInstalledIdentity(plan)
        guard !(await isRunning(plan.app)) else {
            throw UpdaterError("The application started running before replacement. Close it and review a new update plan.")
        }
        let installedURL = URL(fileURLWithPath: plan.app.path).standardizedFileURL.resolvingSymlinksInPath()
        let parent = installedURL.deletingLastPathComponent()
        let stagedName = try reserveBackupURL(in: parent, appName: installedURL.lastPathComponent, suffix: ".maccet-staged")
        let backupName = try reserveBackupURL(in: parent, appName: installedURL.lastPathComponent, suffix: ".maccet-backup")
        let stagedURL = parent.appendingPathComponent(stagedName)
        let backupURL = parent.appendingPathComponent(backupName)
        let fm = FileManager.default
        // Copy the extracted bundle into the installed app's parent directory so that
        // the final swap is a same-parent atomic rename, even when the cache root and
        // the application live on different volumes.
        do {
            try fm.copyItem(at: extracted, to: stagedURL)
        } catch {
            try? fm.removeItem(at: stagedURL)
            throw error
        }
        do {
            try await validateExtractedUpdate(stagedURL, plan: plan)
        } catch {
            try? fm.removeItem(at: stagedURL)
            throw error
        }
        // Revalidate trust and installed identity after staging, immediately before mutation.
        try await revalidateInstalledIdentity(plan)
        // Final running-app check immediately before the swap.
        guard !(await isRunning(plan.app)) else {
            try? fm.removeItem(at: stagedURL)
            throw UpdaterError("The application started running before replacement. Close it and review a new update plan.")
        }
        try fm.moveItem(at: installedURL, to: backupURL)
        do {
            try await mutationBoundaryHook?()
            try fm.moveItem(at: stagedURL, to: installedURL)
        } catch {
            restore(backup: backupURL, to: installedURL)
            try? fm.removeItem(at: stagedURL)
            throw UpdaterError("Could not replace the application with the Sparkle update.")
        }
        do {
            let updated = try AppInventory().read(installedURL.path)
            try await validateInstalledUpdate(updated, plan: plan)
            try plan.reviewedSignature.validate(at: installedURL.path)
            try fm.removeItem(at: backupURL)
            return updated
        } catch {
            try? fm.removeItem(at: installedURL)
            restore(backup: backupURL, to: installedURL)
            throw error
        }
    }

    private func trustedPublicKey(_ plan: SparkleInstallPlan) throws -> Data {
        guard let publicKey = SparkleTrustKey.ed25519PublicKey(at: plan.app.path),
              let fingerprint = SparkleTrustKey.ed25519PublicKeyFingerprint(at: plan.app.path),
              fingerprint == plan.publicKeyFingerprint else {
            throw UpdaterError("The installed Sparkle EdDSA trust key changed after review.")
        }
        return publicKey
    }

    private func revalidateInstalledIdentity(_ plan: SparkleInstallPlan) async throws {
        let fresh = try AppInventory().read(plan.app.path)
        guard fresh.path == plan.app.path,
              fresh.bundleID == plan.app.bundleID,
              fresh.version == plan.app.version,
              fresh.build == plan.app.build,
              fresh.hasStoreReceipt == plan.app.hasStoreReceipt else {
            throw UpdaterError("The installed application changed after review. Rescan before installing.")
        }
        guard ToolLocator.canonicalPath(plan.app.path) == plan.installedCanonicalPath else {
            throw UpdaterError("The installed application path changed after review. Rescan before installing.")
        }
        guard !(pathIsSymlink(plan.app.path)) else {
            throw UpdaterError("The installed application path is a symlink. Rescan before installing.")
        }
        _ = try trustedPublicKey(plan)
        try plan.reviewedSignature.validate(at: plan.app.path)
    }

    private func validateExtractedUpdate(_ url: URL, plan: SparkleInstallPlan) async throws {
        let fresh = try AppInventory().read(url.path)
        guard fresh.bundleID == plan.app.bundleID else { throw UpdaterError("The update bundle identity does not match the installed application.") }
        guard ReleaseComparison.compare(fresh.version, plan.targetVersion) == .orderedSame,
              ReleaseComparison.compare(fresh.build, plan.targetBuild) == .orderedSame else {
            throw UpdaterError("The extracted Sparkle update does not match the reviewed target version or build.")
        }
        let architectures = try ExecutableArchitecture.read(appPath: url.path)
        guard architectures.contains(plan.app.architecture) else { throw UpdaterError("The extracted Sparkle update does not support the reviewed architecture.") }
        try plan.reviewedSignature.validate(at: url.path)
    }

    private func validateInstalledUpdate(_ app: AppRecord, plan: SparkleInstallPlan) async throws {
        guard app.path == plan.app.path,
              app.bundleID == plan.app.bundleID,
              app.hasStoreReceipt == plan.app.hasStoreReceipt else {
            throw UpdaterError("The installed Sparkle update did not match the reviewed target.")
        }
        guard ReleaseComparison.compare(app.version, plan.targetVersion) == .orderedSame,
              ReleaseComparison.compare(app.build, plan.targetBuild) == .orderedSame else {
            throw UpdaterError("The installed Sparkle update did not match the reviewed target.")
        }
    }

    public static func isRunning(_ app: AppRecord) async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { running in
                running.bundleIdentifier == app.bundleID
                    || running.bundleURL.map { ToolLocator.canonicalPath($0.path) == ToolLocator.canonicalPath(app.path) } == true
            }
        }
    }
}

/// Reserves a unique sibling path that does not yet exist, without following symlinks.
/// If a lookalike file or directory already exists, a new UUID is appended and the
/// process repeats so nothing pre-existing is touched.
private func reserveBackupURL(in parent: URL, appName: String, suffix: String) throws -> String {
    var attempts = 0
    while attempts < 10 {
        let unique = attempts == 0 ? "" : "-\(UUID().uuidString)"
        let candidate = appName + suffix + unique
        if !fileExistsNotFollowingSymlinks(at: parent.appendingPathComponent(candidate).path) {
            return candidate
        }
        attempts += 1
    }
    throw UpdaterError("Could not reserve a unique sibling path for the installed application.")
}

/// Returns whether any file system object exists at the path, without following symlinks.
private func fileExistsNotFollowingSymlinks(at path: String) -> Bool {
    var status = stat()
    guard lstat(path, &status) == 0 else { return false }
    return true
}

private func pathIsSymlink(_ path: String) -> Bool {
    var status = stat()
    guard lstat(path, &status) == 0 else { return false }
    return (status.st_mode & S_IFMT) == S_IFLNK
}

private func restore(backup: URL, to installedURL: URL) {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: installedURL.path) else { return }
    try? fm.moveItem(at: backup, to: installedURL)
}

fileprivate extension AppRecord {
    var architecture: CatalogArchitecture {
        #if arch(arm64)
        return .arm64
        #else
        return .x86_64
        #endif
    }
}
