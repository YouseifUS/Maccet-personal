import Foundation
@_spi(Testing) import UpdaterCore

final class FixtureFeedLoader: SparkleFeedLoading {
    var requested: [URL] = []
    var bytes: Data
    init(_ text: String) { bytes = Data(text.utf8) }
    func load(_ url: URL) async throws -> Data { requested.append(url); return bytes }
}

final class FixtureFeedProtocol: URLProtocol {
    static var responseStatus = 200
    static var responseHeaders = ["Content-Type": "application/rss+xml"]
    static var responseData = Data("<rss/>".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseStatus, httpVersion: "HTTP/1.1", headerFields: Self.responseHeaders)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func appcast(_ items: String) -> Data {
    Data(("<rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel>" + items + "</channel></rss>").utf8)
}
func feedItem(_ build: String = "20", version: String = "2.0", rules: String = "") -> String {
    "<item><sparkle:version>\(build)</sparkle:version><sparkle:shortVersionString>\(version)</sparkle:shortVersionString>\(rules)<enclosure url=\"https://downloads.example.com/app.zip\"/></item>"
}
func feedItemSigned(_ build: String = "20", version: String = "2.0", edSignature: String = "", dsaOnly: Bool = false, length: Int? = nil, url: String = "https://downloads.example.com/app.zip", installationType: String? = nil, channel: String? = nil, rules: String = "") -> String {
    var enclosure = "<enclosure url=\"\(url)\""
    if let length { enclosure += " length=\"\(length)\"" }
    if let installationType { enclosure += " sparkle:installationType=\"\(installationType)\"" }
    if !edSignature.isEmpty { enclosure += " sparkle:edSignature=\"\(edSignature)\"" }
    if dsaOnly { enclosure += " sparkle:dsaSignature=\"YWJj\"" }
    enclosure += "/>"
    var channelTag = ""
    if let channel { channelTag = "<sparkle:channel>\(channel)</sparkle:channel>" }
    return "<item>\(channelTag)<sparkle:version>\(build)</sparkle:version><sparkle:shortVersionString>\(version)</sparkle:shortVersionString>\(rules)\(enclosure)</item>"
}

private func crc32(_ data: Data) -> UInt32 {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var crc = UInt32(i)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
        }
        table[i] = crc
    }
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
        crc = table[Int(UInt8(crc & 0xFF) ^ byte)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFFFFFF
}

/// Builds a minimal stored (uncompressed) ZIP containing one `.app` bundle.
func storedZIP(appName: String, files: [String: Data]) -> Data {
    var archive = Data()
    var centralDirectory = Data()
    var offset: UInt32 = 0
    let now: UInt16 = 0
    for (name, data) in files {
        let size = UInt32(data.count)
        let checksum = crc32(data)
        let nameData = Data(name.utf8)
        // Local file header: 30 bytes fixed + name + extra.
        let localHeader: [UInt8] = [
            0x50, 0x4B, 0x03, 0x04, // signature
            0x0A, 0x00, // version needed
            0x00, 0x00, // flags
            0x00, 0x00, // compression (stored)
            UInt8(now & 0xFF), UInt8(now >> 8), // mod time
            UInt8(now & 0xFF), UInt8(now >> 8)  // mod date
        ]
        archive.append(contentsOf: localHeader)
        archive.append(littleEndian: checksum) // crc-32
        archive.append(littleEndian: size) // compressed size
        archive.append(littleEndian: size) // uncompressed size
        archive.append(littleEndian: UInt16(nameData.count))
        archive.append(littleEndian: UInt16(0)) // extra length
        archive.append(nameData)
        archive.append(data)
        // Central directory entry: 46 bytes fixed + name + extra + comment.
        let cdFixed: [UInt8] = [
            0x50, 0x4B, 0x01, 0x02, // signature
            0x03, 0x00, // version made by
            0x0A, 0x00, // version needed
            0x00, 0x00, // flags
            0x00, 0x00, // compression
            UInt8(now & 0xFF), UInt8(now >> 8), // mod time
            UInt8(now & 0xFF), UInt8(now >> 8)  // mod date
        ]
        centralDirectory.append(contentsOf: cdFixed)
        centralDirectory.append(littleEndian: checksum) // crc-32
        centralDirectory.append(littleEndian: size) // compressed size
        centralDirectory.append(littleEndian: size) // uncompressed size
        centralDirectory.append(littleEndian: UInt16(nameData.count))
        centralDirectory.append(littleEndian: UInt16(0)) // extra length
        centralDirectory.append(littleEndian: UInt16(0)) // comment length
        centralDirectory.append(littleEndian: UInt16(0)) // disk number start
        centralDirectory.append(littleEndian: UInt16(0)) // internal file attributes
        let mode: UInt32 = name.hasSuffix("/") ? 0o040755 : 0o100755
        centralDirectory.append(littleEndian: mode << 16) // external file attributes
        centralDirectory.append(littleEndian: offset) // relative offset
        centralDirectory.append(nameData)
        offset += UInt32(localHeader.count + 16 + nameData.count + data.count)
    }
    let cdStart = UInt32(archive.count)
    archive.append(centralDirectory)
    let eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00]
    archive.append(contentsOf: eocd)
    archive.append(littleEndian: UInt16(files.count))
    archive.append(littleEndian: UInt16(files.count))
    archive.append(littleEndian: UInt32(centralDirectory.count))
    archive.append(littleEndian: cdStart)
    archive.append(littleEndian: UInt16(0))
    return archive
}

private extension Data {
    mutating func append(littleEndian value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }
    mutating func append(littleEndian value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }
    func uint32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(self[$1 + offset]) << (UInt32($1) * 8)) }
    }
    mutating func setUInt16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8(value >> 8)
    }
    mutating func setUInt32(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
        self[offset + 2] = UInt8((value >> 16) & 0xFF)
        self[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}

/// Returns the offset of the first local file header, which is always 0 for storedZIP archives.
private func localHeaderOffset(in archive: Data) -> Int { 0 }

/// Builds a stored ZIP with mismatched local/central-directory names.
func zipWithMismatchedLocalName(appName: String, files: [String: Data]) -> Data {
    var archive = storedZIP(appName: appName, files: files)
    // The local header name starts at offset 30. Change the first byte to mismatch the CD.
    if archive.count > 31 { archive[30] = archive[30] == 0x45 ? 0x58 : 0x45 }
    return archive
}

/// Builds a stored ZIP whose local header sets the encryption bit.
func zipWithEncryptedFlag(appName: String, files: [String: Data]) -> Data {
    var archive = storedZIP(appName: appName, files: files)
    // General purpose bit flag is at local header offset 6.
    if archive.count > 7 { archive.setUInt16(0x0001, at: 6) }
    return archive
}

/// Builds a stored ZIP whose central directory declares version-needed >= 45 (ZIP64).
func zipWithZIP64Version(appName: String, files: [String: Data]) -> Data {
    var archive = storedZIP(appName: appName, files: files)
    // Locate the first central-directory entry (after the file data, before EOCD).
    let eocdOffset = archive.count - 22
    guard eocdOffset > 0, archive[eocdOffset] == 0x50, archive[eocdOffset + 1] == 0x4B else { return archive }
    let cdStart = Int(archive.uint32(at: eocdOffset + 16))
    guard cdStart + 46 <= eocdOffset else { return archive }
    // Version needed by file is at CD entry offset 6.
    archive.setUInt16(45, at: cdStart + 6)
    return archive
}

/// Builds a stored ZIP with a ZIP64 extra field in the central directory.
func zipWithZIP64Extra(appName: String, files: [String: Data]) -> Data {
    var archive = storedZIP(appName: appName, files: files)
    let eocdOffset = archive.count - 22
    guard eocdOffset > 0, archive[eocdOffset] == 0x50, archive[eocdOffset + 1] == 0x4B else { return archive }
    let cdStart = Int(archive.uint32(at: eocdOffset + 16))
    guard cdStart + 46 <= eocdOffset else { return archive }
    let nameLength = Int(archive.uint16(at: cdStart + 28))
    let extraLength = Int(archive.uint16(at: cdStart + 30))
    guard extraLength == 0 else { return archive }
    // Insert ZIP64 extra field (id 0x0001, size 8, 64-bit uncompressed size) after the name.
    let extra: [UInt8] = [0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    let insertAt = cdStart + 46 + nameLength
    archive.insert(contentsOf: extra, at: insertAt)
    archive.setUInt16(UInt16(extra.count), at: cdStart + 30)
    // Adjust central directory size in EOCD.
    let cdSize = archive.uint32(at: eocdOffset + 12)
    archive.setUInt32(cdSize + UInt32(extra.count), at: eocdOffset + 12)
    return archive
}

/// Builds a stored ZIP with an entry name containing a control character.
func zipWithMalformedName(appName: String, files: [String: Data]) -> Data {
    // The local and central names are at fixed offsets for single-entry archives.
    // Simpler: rebuild with a bad name.
    let badFiles = files.reduce(into: [String: Data]()) { result, pair in
        result["Example.app\u{00}" + pair.key] = pair.value
    }
    return storedZIP(appName: appName, files: badFiles)
}

/// Builds a stored ZIP with too many entries for the inspector limit.
func zipWithTooManyEntries(appName: String) -> Data {
    var files: [String: Data] = [:]
    for index in 0..<12_000 {
        files["Example.app/Contents/Resources/\(index).txt"] = Data("x".utf8)
    }
    return storedZIP(appName: appName, files: files)
}

/// Builds a stored ZIP whose EOCD declares a larger central-directory size than exists.
func zipWithOversizedCentralDirectory(appName: String, files: [String: Data]) -> Data {
    var archive = storedZIP(appName: appName, files: files)
    let eocdOffset = archive.count - 22
    guard archive[eocdOffset] == 0x50, archive[eocdOffset + 1] == 0x4B else { return archive }
    let cdSize = archive.uint32(at: eocdOffset + 12)
    archive.setUInt32(cdSize + 100, at: eocdOffset + 12)
    return archive
}

/// Builds a stored ZIP whose EOCD declares a smaller central-directory size than exists.
func zipWithUndersizedCentralDirectory(appName: String, files: [String: Data]) -> Data {
    var archive = storedZIP(appName: appName, files: files)
    let eocdOffset = archive.count - 22
    guard archive[eocdOffset] == 0x50, archive[eocdOffset + 1] == 0x4B else { return archive }
    let cdSize = archive.uint32(at: eocdOffset + 12)
    guard cdSize > 50 else { return archive }
    archive.setUInt32(cdSize - 50, at: eocdOffset + 12)
    return archive
}

/// Builds a stored ZIP whose central-directory extra field claims a size larger than the extra length.
func zipWithMalformedExtraField(appName: String, files: [String: Data]) -> Data {
    var archive = storedZIP(appName: appName, files: files)
    let eocdOffset = archive.count - 22
    guard eocdOffset > 0, archive[eocdOffset] == 0x50, archive[eocdOffset + 1] == 0x4B else { return archive }
    let cdStart = Int(archive.uint32(at: eocdOffset + 16))
    guard cdStart + 46 <= eocdOffset else { return archive }
    let nameLength = Int(archive.uint16(at: cdStart + 28))
    let extraLength = Int(archive.uint16(at: cdStart + 30))
    guard extraLength == 0 else { return archive }
    // Insert a 4-byte extra-field header that claims a size larger than what follows.
    let extra: [UInt8] = [0x02, 0x00, 0xFF, 0x00]
    let insertAt = cdStart + 46 + nameLength
    archive.insert(contentsOf: extra, at: insertAt)
    archive.setUInt16(UInt16(extra.count), at: cdStart + 30)
    let cdSize = archive.uint32(at: eocdOffset + 12)
    archive.setUInt32(cdSize + UInt32(extra.count), at: eocdOffset + 12)
    return archive
}
