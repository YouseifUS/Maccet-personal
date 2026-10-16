import Foundation
import UpdaterCore

private struct Failed: Error { let message: String }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failed(message: message) }
}
private final class SetupRunner: CommandRunning {
    var failPorts = true
    var actions: [String] = []
    func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval?) async throws -> CommandResult {
        if executable == "/usr/bin/xcrun" { return CommandResult(output: "/usr/bin/clang") }
        if executable == "/bin/bash", arguments.count > 1 {
            let action = arguments[1]; actions.append(action)
            return CommandResult(status: action == "ports-update" && failPorts ? 1 : 0, errorOutput: "Controlled source failure")
        }
        if arguments == ["--version"] { return CommandResult(output: "Homebrew 7.0.9") }
        if arguments == ["version"] { return CommandResult(output: "7.0.0") }
        if arguments == ["list", "--formula", "--versions", "mas"] { return CommandResult(output: "mas 7.0.0") }
        if arguments.first == "info" || arguments.first == "outdated" && arguments.contains("--cask") {
            return CommandResult(output: #"{"casks":[]}"#)
        }
        if arguments == ["list", "--json"] || arguments.first == "outdated" || arguments == ["-q", "outdated"] { return CommandResult() }
        throw Failed(message: "Unexpected command in controlled setup fixture")
    }
}

@main private struct SetupRetryChecks {
    @MainActor static func wait(_ model: AppModel) async throws {
        for _ in 0..<300 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failed(message: "Setup did not finish")
    }
    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maccet-setup-retry-" + UUID().uuidString)
        let previousData = ProcessInfo.processInfo.environment["UNIFIED_UPDATER_DATA_DIR"]
        setenv("UNIFIED_UPDATER_DATA_DIR", root.path, 1)
        defer {
            try? FileManager.default.removeItem(at: root)
            if let previousData { setenv("UNIFIED_UPDATER_DATA_DIR", previousData, 1) }
            else { unsetenv("UNIFIED_UPDATER_DATA_DIR") }
        }
        do {
            let runner = SetupRunner()
            let paths = ["brew": "/opt/homebrew/bin/brew", "port": "/opt/local/bin/port", "mas": "/opt/homebrew/bin/mas"]
            func session() -> AppModel {
                let model = AppModel(runner: runner, setupLocate: { paths[$0] })
                model.preferences.scanRoots = []; model.preferences.includeSystemApplications = false
                return model
            }
            let model = session()
            model.start(); try await wait(model)
            try expect(model.setupItems[1].phase == .ready && model.setupItems[2].phase == .failed && model.setupItems[3].phase == .ready, "Partial setup result was lost")
            print("PASS Partial source failure remains visible")

            runner.failPorts = false
            model.prepareSources()
            try expect(model.setupItems[1].phase == .ready && model.setupItems[3].phase == .ready, "Ready tools reset while retry started")
            try await wait(model)
            try expect(model.setupItems.allSatisfy { $0.phase == .ready }, "Retry did not recover failed setup")
            try expect(runner.actions == ["brew-update", "ports-update", "mas-update", "ports-update"], "GUI retry repeated successful maintenance")
            try expect(model.lastScan != nil, "Retry did not finish with a source scan")
            print("PASS GUI retry prepares only the failed source and rescans")

            let fresh = session()
            fresh.start(); try await wait(fresh)
            try expect(Array(runner.actions.suffix(3)) == ["brew-update", "ports-update", "mas-update"] && runner.actions.count == 7, "A fresh session reused previous setup success")
            print("PASS A fresh session runs full preparation")
            print("\n3 setup orchestration checks passed; 0 failed.")
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1)
        }
    }
}
