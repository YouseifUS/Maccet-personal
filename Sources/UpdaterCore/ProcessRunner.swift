import Foundation

public struct CommandResult {
    public var status: Int32
    public var output: String
    public var errorOutput: String
    public init(status: Int32 = 0, output: String = "", errorOutput: String = "") {
        self.status = status; self.output = output; self.errorOutput = errorOutput
    }
    public func checked() throws -> String {
        guard status == 0 else {
            throw UpdaterError(Diagnostics.redact(errorOutput.isEmpty ? output : errorOutput).prefixString(3500))
        }
        return output
    }
}

public protocol CommandRunning {
    func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval?) async throws -> CommandResult
}

public final class ProcessRunner: CommandRunning {
    public init() {}
    public func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:], timeout: TimeInterval? = 120) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Files avoid pipe deadlocks when both output streams are busy.
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("unified-updater-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: folder) }
                    let out = folder.appendingPathComponent("stdout")
                    let err = folder.appendingPathComponent("stderr")
                    FileManager.default.createFile(atPath: out.path, contents: nil)
                    FileManager.default.createFile(atPath: err.path, contents: nil)
                    let outHandle = try FileHandle(forWritingTo: out)
                    let errHandle = try FileHandle(forWritingTo: err)
                    defer { try? outHandle.close(); try? errHandle.close() }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    var env = ProcessInfo.processInfo.environment
                    environment.forEach { env[$0] = $1 }
                    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/opt/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
                    process.environment = env
                    process.standardOutput = outHandle; process.standardError = errHandle
                    process.standardInput = FileHandle.nullDevice
                    try process.run()
                    let deadline = timeout.map { Date().addingTimeInterval($0) }
                    var timedOut = false
                    while process.isRunning {
                        if let deadline, Date() > deadline {
                            timedOut = true
                            process.terminate()
                            Thread.sleep(forTimeInterval: 0.2)
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                            break
                        }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    process.waitUntilExit()
                    if timedOut { throw UpdaterError("The source did not respond before the check timed out. Try again or open the source directly.") }
                    let stdout = try Self.readBounded(out)
                    let stderr = try Self.readBounded(err)
                    continuation.resume(returning: CommandResult(status: process.terminationStatus, output: stdout, errorOutput: stderr))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func readBounded(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16 * 1024 * 1024) ?? Data()
        guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else {
            throw UpdaterError("The source output exceeded the supported size; this result was not parsed.")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum Diagnostics {
    public static func redact(_ text: String) -> String {
        var value = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        for pattern in [#"(?i)(https?://)[^\s/@]+:[^\s/@]+@"#, #"(?i)([?&](?:token|key|secret|password|signature|auth)[^=\s]*=)[^&\s]+"#, #"(?i)(bearer\s+)[A-Za-z0-9._-]+"#] {
            value = value.replacingOccurrences(of: pattern, with: "$1[REDACTED]", options: .regularExpression)
        }
        return value
    }
}

extension String {
    func prefixString(_ count: Int) -> String { String(prefix(count)) }
}
