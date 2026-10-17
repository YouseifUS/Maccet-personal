import Foundation

/// Evidence about the owned command only. Output is not download/install progress,
/// and silence cannot establish whether an authorization callback or installer stalled.
public struct ProcessObservation: Codable, Equatable {
    public var processID: Int32?
    public var elapsedSeconds: TimeInterval
    public var silentSeconds: TimeInterval
    public var stdoutBytes: UInt64
    public var stderrBytes: UInt64
    public var isRunning: Bool
    public var date = Date()
    public init(processID: Int32?, elapsedSeconds: TimeInterval, silentSeconds: TimeInterval,
                stdoutBytes: UInt64, stderrBytes: UInt64, isRunning: Bool) {
        self.processID = processID; self.elapsedSeconds = elapsedSeconds; self.silentSeconds = silentSeconds
        self.stdoutBytes = stdoutBytes; self.stderrBytes = stderrBytes; self.isRunning = isRunning
    }
    public var needsAttention: Bool { isRunning && processID != nil && silentSeconds >= 120 }
    public var message: String {
        if processID == nil { return isRunning ? "The command is running; this runner cannot provide live process evidence." : "The command returned; no live process observations were available. Installed metadata still requires verification." }
        if !isRunning { return "The owned command exited after \(Int(elapsedSeconds)) seconds. Installed metadata still requires verification." }
        if needsAttention {
            return "Needs attention: the owned command is still running, with no output observed for \(Int(silentSeconds)) seconds. Check macOS authorization or App Store. Silence does not prove a stall; installation has not been stopped."
        }
        return "The owned command is running (\(Int(elapsedSeconds)) seconds); last output \(Int(silentSeconds)) seconds ago. Output activity does not establish installation progress."
    }
}

public struct AssistedVerification: Codable, Equatable {
    public var verified: Bool
    public var date = Date()
    public var message: String
    public init(verified: Bool, message: String) { self.verified = verified; self.message = message }
}

actor OperationObservationHistory {
    var last: ProcessObservation?
    var attention: String?
    func receive(_ observation: ProcessObservation) {
        last = observation
        if observation.needsAttention { attention = observation.message }
    }
    func snapshot() -> (ProcessObservation?, String?) { (last, attention) }
}

/// The background process loop publishes small, output-free snapshots. The async
/// observer delivers them serially and is joined before the command returns.
final class OwnedProcessMonitor {
    private let lock = NSLock()
    private var current: ProcessObservation?
    private var started = ProcessInfo.processInfo.systemUptime
    private var lastOutput = ProcessInfo.processInfo.systemUptime
    private var previous: (UInt64, UInt64) = (0, 0)
    func update(processID: Int32, stdout: UInt64, stderr: UInt64, isRunning: Bool) {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if current == nil { started = now; lastOutput = now }
        if stdout != previous.0 || stderr != previous.1 { lastOutput = now }
        previous = (stdout, stderr)
        current = ProcessObservation(processID: processID, elapsedSeconds: max(0, now - started), silentSeconds: max(0, now - lastOutput), stdoutBytes: stdout, stderrBytes: stderr, isRunning: isRunning)
    }
    func snapshot() -> ProcessObservation? { lock.lock(); defer { lock.unlock() }; return current }
}
