import Foundation

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
    private static func sanitized(_ value: Any) -> Any {
        if let text = value as? String { return Diagnostics.redact(text) }
        if let array = value as? [Any] { return array.map(sanitized) }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues(sanitized) }
        return value
    }
}
