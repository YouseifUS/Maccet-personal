import Foundation
import UpdaterCore

private struct Failed: Error { let message: String }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failed(message: message) }
}
private final class SetupRunner: CommandRunning {
    var failPorts = true
    var masVersion = "7.0.0"
    var actions: [String] = []
    var calls = 0
    var beforeSetup: (@MainActor () throws -> Void)?
    func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval?) async throws -> CommandResult {
        calls += 1
        if executable == "/usr/bin/xcrun" { try await beforeSetup?(); return CommandResult(output: "/usr/bin/clang") }
        if executable == "/bin/bash", arguments.count > 1 {
            let action = arguments[1]; actions.append(action)
            return CommandResult(status: action == "ports-update" && failPorts ? 1 : 0, errorOutput: "Controlled source failure")
        }
        if arguments == ["--version"] { return CommandResult(output: "Homebrew 7.0.9") }
        if arguments == ["version"] { return CommandResult(output: executable == "/opt/homebrew/bin/mas" ? masVersion : "7.0.0") }
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
            let applications = root.appendingPathComponent("Applications")
            for name in ["Direct", "Store"] {
                let contents = applications.appendingPathComponent(name + ".app/Contents")
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                let info = ["CFBundleIdentifier": "test.maccet.setup." + name, "CFBundleName": name, "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
                if name == "Store" {
                    try FileManager.default.createDirectory(at: contents.appendingPathComponent("_MASReceipt"), withIntermediateDirectories: false)
                    try Data().write(to: contents.appendingPathComponent("_MASReceipt/receipt"))
                }
            }
            let runner = SetupRunner()
            let paths = ["brew": "/opt/homebrew/bin/brew", "port": "/opt/local/bin/port", "mas": "/opt/homebrew/bin/mas"]
            func session() -> AppModel {
                let model = AppModel(runner: runner, setupLocate: { paths[$0] })
                model.preferences.scanRoots = [applications.path]; model.preferences.includeSystemApplications = false
                return model
            }
            let model = session()
            runner.beforeSetup = { try expect(model.apps.count == 2, "Preparation ran before inventory was published") }
            model.start(); try await wait(model)
            runner.beforeSetup = nil
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
            let disabled = session()
            disabled.preferences.disabledSources = Set(UpdateSource.allCases)
            let callsBefore = runner.calls
            disabled.start(); try await wait(disabled)
            try expect(runner.calls == callsBefore, "Disabled sources still triggered preparation commands")
            try expect(!disabled.setupNeedsAttention && disabled.lastScan != nil, "Disabled setup prevented inventory or required attention")
            print("PASS Disabling every source skips setup commands and preserves inventory")
            let homebrewOnly = session()
            homebrewOnly.preferences.disabledSources = [.macPorts, .appStore]
            let actionsBefore = runner.actions.count
            homebrewOnly.start(); try await wait(homebrewOnly)
            try expect(runner.actions.count == actionsBefore + 1 && runner.actions.last == "brew-update", "Single-source settings were not passed to preparation")
            try expect(homebrewOnly.setupItems[2].phase == .disabled && homebrewOnly.setupItems[3].phase == .disabled && !homebrewOnly.setupNeedsAttention, "Disabled steps were presented as failures")
            print("PASS GUI setup prepares only the enabled source")
            let empty = session()
            empty.preferences.scanRoots = []
            let beforeEmpty = runner.actions.count
            let callsBeforeEmpty = runner.calls
            empty.start(); try await wait(empty)
            try expect(runner.actions.count == beforeEmpty, "An empty inventory still triggered tool maintenance")
            try expect(runner.calls == callsBeforeEmpty, "An empty inventory still triggered update-source checks")
            try expect(empty.setupItems.allSatisfy { $0.phase == .notRequired } && empty.lastScan != nil, "An empty inventory did not finish without setup")
            try expect(empty.sources.allSatisfy { $0.checkRequired == false } && !empty.sourceChecksNeedAttention, "An unnecessary source appeared as missing or failed")
            print("PASS Empty inventories do not trigger source preparation")
            let storeOnly = session()
            storeOnly.preferences.scanRoots = [applications.appendingPathComponent("Store.app").path]
            let beforeStore = runner.actions.count
            storeOnly.start(); try await wait(storeOnly)
            try expect(Array(runner.actions.dropFirst(beforeStore)) == ["brew-update", "mas-update"], "Store-only inventory prepared unrelated managers")
            try expect(storeOnly.setupItems[1].dependencyFor == .appStore && storeOnly.setupItems[2].phase == .notRequired, "Store helper dependency was not distinguished")
            print("PASS Store-only inventory prepares only its helper route")
            let directOnly = session()
            directOnly.preferences.scanRoots = [applications.appendingPathComponent("Direct.app").path]
            let beforeDirect = runner.actions.count
            directOnly.start(); try await wait(directOnly)
            try expect(Array(runner.actions.dropFirst(beforeDirect)) == ["brew-update", "ports-update"] && directOnly.setupItems[3].phase == .notRequired, "Non-store inventory prepared mas")
            print("PASS Non-store inventory skips the App Store helper")
            directOnly.sources = [SourceHealth(source: .appStore, message: "Not needed", checkRequired: false)]
            directOnly.invalidateInventory()
            try expect(directOnly.sources[0].checkRequired == nil && directOnly.sourceChecksNeedAttention && directOnly.lastScan == nil, "Changed scan settings retained a stale unnecessary-source decision")
            print("PASS Changed scan settings invalidate skipped source checks")
            runner.failPorts = true
            let changedHelper = session()
            changedHelper.start(); try await wait(changedHelper)
            runner.failPorts = false; runner.masVersion = "6.0.0"
            let beforeHelperRetry = runner.actions.count
            changedHelper.prepareSources(); try await wait(changedHelper)
            try expect(changedHelper.setupItems[3].phase == .failed && changedHelper.setupNeedsAttention, "GUI reused an incompatible helper's ready result")
            try expect(changedHelper.setupItems[3].message.contains("mas 7 or later") && Array(runner.actions.dropFirst(beforeHelperRetry)) == ["ports-update", "mas-update"], "GUI did not repair the stale helper independently")
            print("PASS GUI retry invalidates a previously ready incompatible helper")
            runner.masVersion = "7.1.0"
            let beforeRecovery = runner.actions.count
            changedHelper.prepareSources(); try await wait(changedHelper)
            try expect(!changedHelper.setupNeedsAttention && changedHelper.setupItems[3].version == "7.1.0", "GUI retained stale readiness after helper recovery")
            try expect(Array(runner.actions.dropFirst(beforeRecovery)) == ["mas-update"] && changedHelper.lastScan != nil, "Helper recovery repeated successful manager maintenance")
            print("PASS GUI helper recovery clears attention without repeating healthy managers")
            print("\n11 setup orchestration checks passed; 0 failed.")
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1)
        }
    }
}
