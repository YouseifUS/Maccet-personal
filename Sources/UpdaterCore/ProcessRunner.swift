import Foundation
import Darwin

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
    func runObserved(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval?,
                     onObservation: @escaping (ProcessObservation) async -> Void) async throws -> CommandResult
}
public extension CommandRunning {
    func runObserved(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval?,
                     onObservation: @escaping (ProcessObservation) async -> Void) async throws -> CommandResult {
        await onObservation(ProcessObservation(processID: nil, elapsedSeconds: 0, silentSeconds: 0, stdoutBytes: 0, stderrBytes: 0, isRunning: true))
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let result = try await run(executable, arguments, environment: environment, timeout: timeout)
            await onObservation(ProcessObservation(processID: nil, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, silentSeconds: 0, stdoutBytes: 0, stderrBytes: 0, isRunning: false))
            return result
        } catch {
            await onObservation(ProcessObservation(processID: nil, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, silentSeconds: 0, stdoutBytes: 0, stderrBytes: 0, isRunning: false))
            throw error
        }
    }
}

/// Each stream is drained independently; only its first 16 MiB are retained.
/// No raw output is written to disk. After the owned child exits, inherited
/// writers may keep draining into discard until EOF without blocking the result.
private final class BoundedProcessOutput {
    struct Snapshot { var data: Data; var exceeded: Bool; var failed: Bool }
    let pipe = Pipe()
    private let queue = DispatchQueue(label: "maccet.process-output." + UUID().uuidString)
    private var source: DispatchSourceRead?
    private var data = Data()
    private var receivedBytes: UInt64 = 0
    var observedBytes: UInt64 { queue.sync { receivedBytes } }
    private var exceeded = false
    private var failed = false
    private var storing = true
    private var ended = false
    private let limit = 16 * 1024 * 1024
    // Darwin FIONREAD = _IOR('f', 127, int); this C macro is not imported by Swift.
    private let bytesAvailableRequest: UInt = 0x4004667f

    init() throws {
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw UpdaterError("Could not create bounded process output capture. The command was not started.")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        self.source = source
        source.setCancelHandler { [handle = pipe.fileHandleForReading] in try? handle.close() }
        source.setEventHandler { [self] in drain() }
        source.resume()
    }
    func closeWriter() { try? pipe.fileHandleForWriting.close() }
    func finish() -> Snapshot {
        queue.sync {
            // Snapshot the finite bytes buffered when the owned child exits.
            // A descendant can keep writing without extending this final drain.
            if !ended {
                var available: Int32 = 0
                if ioctl(pipe.fileHandleForReading.fileDescriptor, bytesAvailableRequest, &available) == 0 {
                    drain(byteBudget: max(0, Int(available)))
                } else { failed = true }
            }
            storing = false
            let snapshot = Snapshot(data: data, exceeded: exceeded, failed: failed)
            data = Data()
            return snapshot
        }
    }
    private func drain(byteBudget: Int = 2 * 1024 * 1024) {
        guard !ended else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        // Bound callback work so a continuously writing descendant cannot starve
        // finish(), which separately reads the kernel-buffered byte count.
        var remainingBudget = byteBudget
        while remainingBudget > 0 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(pipe.fileHandleForReading.fileDescriptor, $0.baseAddress, min($0.count, remainingBudget)) }
            if count > 0 {
                receivedBytes += UInt64(count)
                remainingBudget -= count
                if storing {
                    let remaining = limit - data.count
                    if count > remaining { exceeded = true }
                    data.append(contentsOf: buffer.prefix(min(count, remaining)))
                }
            } else if count == 0 {
                end(); return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                failed = true; end(); return
            }
        }
    }
    private func end() {
        ended = true
        source?.cancel()
        source?.setEventHandler {}
    }
}

public final class ProcessRunner: CommandRunning {
    private var observationInterval: UInt64 = 1_000_000_000
    public init() {}
    @_spi(Testing) public init(observationInterval: UInt64) { self.observationInterval = max(1_000_000, observationInterval) }
    public func runObserved(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval?,
                            onObservation: @escaping (ProcessObservation) async -> Void) async throws -> CommandResult {
        let monitor = OwnedProcessMonitor()
        let interval = observationInterval
        let observer = Task {
            while !Task.isCancelled {
                if let snapshot = monitor.snapshot() { await onObservation(snapshot) }
                do { try await Task.sleep(nanoseconds: interval) } catch { break }
            }
        }
        do {
            let result = try await runCaptured(executable, arguments, environment: environment, timeout: timeout, monitor: monitor)
            observer.cancel(); await observer.value
            if let snapshot = monitor.snapshot() { await onObservation(snapshot) }
            return result
        } catch {
            observer.cancel(); await observer.value
            if let snapshot = monitor.snapshot() { await onObservation(snapshot) }
            throw error
        }
    }
    public func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:], timeout: TimeInterval? = 120) async throws -> CommandResult {
        try await runCaptured(executable, arguments, environment: environment, timeout: timeout, monitor: nil)
    }
    private func runCaptured(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval?, monitor: OwnedProcessMonitor?) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let out = try BoundedProcessOutput()
                    defer { out.closeWriter(); _ = out.finish() }
                    let err = try BoundedProcessOutput()
                    defer { err.closeWriter(); _ = err.finish() }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    var env = ProcessInfo.processInfo.environment
                    environment.forEach { env[$0] = $1 }
                    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/opt/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
                    process.environment = env
                    process.standardOutput = out.pipe.fileHandleForWriting
                    process.standardError = err.pipe.fileHandleForWriting
                    process.standardInput = FileHandle.nullDevice
                    try process.run()
                    out.closeWriter(); err.closeWriter()
                    let deadline = timeout.map { Date().addingTimeInterval($0) }
                    var timedOut = false
                    while process.isRunning {
                        monitor?.update(processID: process.processIdentifier, stdout: out.observedBytes, stderr: err.observedBytes, isRunning: true)
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
                    monitor?.update(processID: process.processIdentifier, stdout: out.observedBytes, stderr: err.observedBytes, isRunning: false)
                    if timedOut { throw UpdaterError("The source did not respond before the check timed out. Try again or open the source directly.") }
                    let stdout = out.finish()
                    let stderr = err.finish()
                    monitor?.update(processID: process.processIdentifier, stdout: out.observedBytes, stderr: err.observedBytes, isRunning: false)
                    guard !stdout.failed && !stderr.failed else { throw UpdaterError("Process output could not be captured completely; this result was not parsed.") }
                    guard !stdout.exceeded && !stderr.exceeded else {
                        let context = stderr.data.isEmpty ? stdout.data : stderr.data
                        let diagnostic = Diagnostics.redact(String(decoding: context.prefix(3500), as: UTF8.self)).replacingOccurrences(of: "\0", with: "").prefixString(1000)
                        throw UpdaterError("The command finished with exit status \(process.terminationStatus), but output exceeded 16 MiB per stream; this result was not parsed. Rescan before retrying.\n" + diagnostic)
                    }
                    continuation.resume(returning: CommandResult(status: process.terminationStatus, output: String(decoding: stdout.data, as: UTF8.self), errorOutput: String(decoding: stderr.data, as: UTF8.self)))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

public enum Diagnostics {
    public static func redact(_ text: String) -> String {
        var value = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        // Sanitize values before serialization. Keep URL separators and ordinary
        // query fields so redacted diagnostics still identify the failing source.
        let rules: [(String, String)] = [
            (#"(?i)(https?://)[^\s/@]+@"#, "$1[REDACTED]@"),
            (#"(?i)([?&](?:(?:access|refresh|id)[_-]?token|api[_-]?key|x-(?:amz|goog)-(?:signature|credential|security-token)|sig|(?:token|key|secret|password|signature|auth)[^=\s&]*)=)[^&\s#\"'<>]+"#, "$1[REDACTED]"),
            (#"(?i)(bearer\s+)[A-Za-z0-9._~+/-]+=*"#, "$1[REDACTED]")
        ]
        for (pattern, replacement) in rules {
            value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return value
    }
}

extension String {
    func prefixString(_ count: Int) -> String { String(prefix(count)) }
}
