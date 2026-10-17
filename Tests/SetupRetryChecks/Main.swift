import Foundation
import UpdaterCore

private struct Failed: Error { let message: String }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failed(message: message) }
}
private final class SetupRunner: CommandRunning {
    var failPorts = true
    var toolsMissing = false
    var masVersion = "7.0.0"
    var actions: [String] = []
    var calls = 0
    var macPortsInstallerRequests = 0
    var metadataBrewRequests = 0
    var failMetadataPorts = false
    var beforeSetup: (@MainActor () throws -> Void)?
    func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval?) async throws -> CommandResult {
        calls += 1
        if executable == "/usr/bin/curl", arguments.last?.contains("macports/macports-base") == true {
            macPortsInstallerRequests += 1
            return CommandResult(status: 1, errorOutput: "Controlled optional installer unavailable")
        }
        if executable == "/usr/bin/xcode-select", arguments == ["--print-path"] { return CommandResult(status: toolsMissing ? 1 : 0, output: "/Developer") }
        if executable == "/usr/bin/xcrun" { try await beforeSetup?(); return CommandResult(status: toolsMissing ? 1 : 0, output: "/usr/bin/clang") }
        if executable == "/bin/bash", arguments.count > 1 {
            let action = arguments[1]; actions.append(action)
            return CommandResult(status: (action == "ports-update" && failPorts) || (action == "ports-sync" && failMetadataPorts) ? 1 : 0, errorOutput: "Controlled source failure")
        }
        if arguments.first == "outdated", environment["HOMEBREW_FORCE_API_AUTO_UPDATE"] == "1" { metadataBrewRequests += 1 }
        if arguments == ["--version"] { return CommandResult(output: "Homebrew 7.0.9") }
        if arguments == ["version"] { return CommandResult(output: executable == "/opt/homebrew/bin/mas" ? masVersion : "Version: 2.12.7") }
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
            let startup = session()
            startup.start()
            try expect(startup.settingUp && !startup.maintainingSources, "Readiness detection was marked as active maintenance")
            try await wait(startup)
            try expect(runner.actions.isEmpty, "Opening the app performed source maintenance instead of checking readiness")
            try expect(startup.lastScan != nil && startup.setupItems.allSatisfy { $0.phase == .ready }, "Readiness checks did not preserve application scanning")
            print("PASS Opening the app checks readiness without maintenance")
            let beforeSecondWindow = runner.calls
            startup.start(); try await wait(startup)
            try expect(runner.calls == beforeSecondWindow && startup.setupActionTitle == "Prepare Sources", "Another window repeated startup or offered a retry before preparation")
            print("PASS Another window does not repeat readiness or maintenance")
            let missingRunner = SetupRunner(); missingRunner.toolsMissing = true
            let missing = AppModel(runner: missingRunner, setupLocate: { _ in nil })
            missing.preferences.scanRoots = [applications.path]; missing.preferences.includeSystemApplications = false
            missing.start(); try await wait(missing)
            try expect([0, 1, 3].allSatisfy { missing.setupItems[$0].phase == .unavailable } && missing.setupItems[2].phase == .notRequired && missing.setupNeedsAttention, "Missing launch tools were not reported as unavailable")
            try expect(missingRunner.actions.isEmpty && missing.lastScan != nil && missing.apps.count == 2 && missing.error == nil, "Missing tools started installation or prevented inventory and scanning")
            print("PASS Missing launch tools preserve inventory and require explicit preparation")
            let missingApple = AppModel(runner: missingRunner, setupLocate: { paths[$0] })
            missingApple.preferences.scanRoots = [applications.path]; missingApple.preferences.includeSystemApplications = false
            missingApple.start(); try await wait(missingApple)
            try expect(missingApple.setupItems[0].phase == .unavailable && missingApple.setupItems.dropFirst().allSatisfy { $0.phase == .ready }, "Missing Apple tools hid working sources")
            try expect(missingRunner.actions.isEmpty && missingApple.lastScan != nil, "Apple-tools readiness requested maintenance")
            print("PASS Missing Apple tools do not hide working source tools")
            let model = session()
            runner.beforeSetup = { try expect(model.apps.count == 2, "Preparation ran before inventory was published") }
            model.prepareSources()
            try expect(model.maintainingSources, "Explicit preparation was not marked as active maintenance")
            try await wait(model)
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
            try expect(runner.actions.count == 4 && fresh.setupActionTitle == "Prepare Sources", "A new launch performed maintenance or reused a preparation result")
            fresh.prepareSources(); try await wait(fresh)
            try expect(Array(runner.actions.suffix(3)) == ["brew-update", "ports-update", "mas-update"] && runner.actions.count == 7, "A fresh session reused previous setup success")
            print("PASS A fresh session checks readiness and explicitly requested preparation runs in full")
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
            homebrewOnly.prepareSources(); try await wait(homebrewOnly)
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
            let optionalRunner = SetupRunner()
            let optional = AppModel(runner: optionalRunner, sourcePaths: [:], setupLocate: { $0 == "port" ? nil : paths[$0] })
            optional.preferences.scanRoots = [applications.appendingPathComponent("Direct.app").path]
            optional.preferences.includeSystemApplications = false
            optional.prepareSources(); try await wait(optional)
            try expect(optional.setupItems[2].phase == .notRequired && optionalRunner.macPortsInstallerRequests == 0, "Default preparation requested an unrelated MacPorts installer")
            optional.includeMacPortsInPreparation = true
            optional.prepareSources(); try await wait(optional)
            try expect(optional.setupItems[2].phase == .failed && optionalRunner.macPortsInstallerRequests == 1, "Sources opt-in was not forwarded to preparation")
            optional.includeMacPortsInPreparation = false
            optional.prepareSources(); try await wait(optional)
            try expect(optional.setupItems[2].phase == .notRequired && optionalRunner.macPortsInstallerRequests == 1, "Removing optional opt-in kept retrying its installer")
            print("PASS Optional MacPorts preparation requires the Sources opt-in")
            let storeOnly = session()
            storeOnly.preferences.scanRoots = [applications.appendingPathComponent("Store.app").path]
            let beforeStore = runner.actions.count
            storeOnly.prepareSources(); try await wait(storeOnly)
            try expect(Array(runner.actions.dropFirst(beforeStore)) == ["brew-update", "mas-update"], "Store-only inventory prepared unrelated managers")
            try expect(storeOnly.setupItems[1].dependencyFor == .appStore && storeOnly.setupItems[2].phase == .notRequired, "Store helper dependency was not distinguished")
            print("PASS Store-only inventory prepares only its helper route")
            let directOnly = session()
            directOnly.preferences.scanRoots = [applications.appendingPathComponent("Direct.app").path]
            let beforeDirect = runner.actions.count
            directOnly.prepareSources(); try await wait(directOnly)
            try expect(Array(runner.actions.dropFirst(beforeDirect)) == ["brew-update", "ports-update"] && directOnly.setupItems[3].phase == .notRequired, "Non-store inventory prepared mas")
            print("PASS Non-store inventory skips the App Store helper")
            directOnly.sources = [SourceHealth(source: .appStore, message: "Not needed", checkRequired: false)]
            directOnly.invalidateInventory()
            try expect(directOnly.sources[0].checkRequired == nil && directOnly.sourceChecksNeedAttention && directOnly.lastScan == nil, "Changed scan settings retained a stale unnecessary-source decision")
            print("PASS Changed scan settings invalidate skipped source checks")
            runner.failPorts = true
            let changedHelper = session()
            changedHelper.prepareSources(); try await wait(changedHelper)
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
            let metadataRunner = SetupRunner(); metadataRunner.failMetadataPorts = true
            let metadata = AppModel(runner: metadataRunner, sourcePaths: [.homebrew: paths["brew"]!, .appStore: paths["mas"]!], setupLocate: { paths[$0] })
            metadata.preferences.scanRoots = [applications.path]; metadata.preferences.includeSystemApplications = false
            metadata.refreshSourceMetadata()
            try expect(metadata.refreshingMetadata && metadata.busy && metadata.preventsQuit && !metadata.maintainingSources, "Metadata intent was not independently active")
            try await wait(metadata)
            try expect(!metadata.preventsQuit && !metadata.setupWasPrepared && metadata.setupActionTitle == "Prepare Sources", "Metadata refresh was counted as tool preparation")
            try expect(metadata.metadataRefreshItems[0].phase == .ready && metadata.metadataRefreshItems[1].phase == .failed && metadata.metadataNeedsAttention, "Partial metadata failure was lost")
            try expect(metadata.lastMetadataRefreshAttempt != nil && metadata.lastScan != nil && metadataRunner.metadataBrewRequests == 1, "Metadata results or following app scan were missing")
            try expect(metadataRunner.actions == ["ports-sync"], "Metadata-only intent broadened into tool maintenance")
            metadataRunner.failMetadataPorts = false
            metadata.refreshSourceMetadata(); try await wait(metadata)
            try expect(!metadata.metadataNeedsAttention && metadata.metadataRefreshItems[1].phase == .ready && metadataRunner.metadataBrewRequests == 2, "Metadata retry retained stale failures")
            try expect(metadataRunner.actions == ["ports-sync", "ports-sync"] && metadata.setupItems.allSatisfy { $0.phase == .waiting }, "Metadata refresh overwrote independent preparation evidence")
            print("PASS Metadata scope, partial failure and retry remain independent from tool preparation")
            print("\n17 setup orchestration checks passed; 0 failed.")
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1)
        }
    }
}
