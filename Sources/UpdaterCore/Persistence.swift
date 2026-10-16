import Foundation

public struct LocalStore {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func load<T: Decodable>(_ type: T.Type, file: String) throws -> T {
        let data = try Data(contentsOf: root.appendingPathComponent(file))
        return try JSONDecoder().decode(type, from: data)
    }
    public func save<T: Encodable>(_ value: T, file: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: root.appendingPathComponent(file), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(file).path)
    }
    public func recover(_ history: [ActivityRecord]) -> [ActivityRecord] {
        history.map { old in
            var record = old
            if record.state.isActive {
                record.state = .interrupted
                record.message = "The app closed before this operation was recorded as complete. Rescan to inspect the installed version before retrying."
                record.cleanupMessage = "No automatic cleanup or retry was started during recovery."
            }
            return record
        }
    }
}
