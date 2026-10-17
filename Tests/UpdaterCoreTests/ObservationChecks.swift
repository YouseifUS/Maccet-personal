import Foundation
import UpdaterCore

final class ObservingFixtureRunner: CommandRunning {
    var observations: [ProcessObservation] = []
    var observedCommands: [String] = []
    var calls: [String] = []
    var handler: (String, [String]) throws -> CommandResult = { _, _ in CommandResult() }
    func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval?) async throws -> CommandResult {
        calls.append(executable); return try handler(executable, arguments)
    }
    func runObserved(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval?, onObservation: @escaping (ProcessObservation) async -> Void) async throws -> CommandResult {
        observedCommands.append(executable)
        for observation in observations { await onObservation(observation) }
        return try await run(executable, arguments, environment: environment, timeout: timeout)
    }
}

actor ObservationsRecorder {
    var values: [ProcessObservation] = []
    func receive(_ value: ProcessObservation) { values.append(value) }
    func snapshot() -> [ProcessObservation] { values }
}
