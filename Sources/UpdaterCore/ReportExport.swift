import Foundation
import Darwin

public enum ReportExport {
    public static func data(apps: [AppRecord], sources: [SourceHealth], history: [ActivityRecord], lastScan: Date?) throws -> Data {
        struct Report: Encodable {
            var version = "0.1.1"
            var generatedAt = Date()
            var lastScan: Date?
            var apps: [AppRecord]
            var sources: [SourceHealth]
            var history: [ActivityRecord]
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Report(lastScan: lastScan, apps: apps, sources: sources, history: history))
        // Redact string values, never serialized JSON syntax. A URL/token in a
        // diagnostic must not consume closing quotes and corrupt the report.
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: sanitized(object), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
    public static func write(_ data: Data, to url: URL) throws {
        guard url.isFileURL else { throw UpdaterError("Choose a local file destination for the report.") }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".maccet-report-" + UUID().uuidString + ".tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw UpdaterError("Could not create a private report file. The destination was not changed.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var published = false
        defer {
            try? handle.close()
            if !published { unlink(temporary.path) }
        }
        // Restrictive process masks may remove owner bits. Set the intended
        // private mode on the opened inode before writing any report contents.
        guard fchmod(descriptor, 0o600) == 0 else { throw UpdaterError("Could not set private report permissions. The destination was not changed.") }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        // Same-directory rename atomically publishes the new private inode,
        // replacing a selected file/link without inheriting its old permissions.
        guard rename(temporary.path, url.path) == 0 else { throw UpdaterError("Could not publish the report. The previous destination was retained.") }
        published = true
    }
    private static func sanitized(_ value: Any) -> Any {
        if let text = value as? String { return Diagnostics.redact(text) }
        if let array = value as? [Any] { return array.map(sanitized) }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues(sanitized) }
        return value
    }
}
