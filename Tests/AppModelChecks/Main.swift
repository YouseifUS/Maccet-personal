import Foundation
import AppKit
import UpdaterCore

private struct Failed: Error { let message: String }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failed(message: message) }
}
private final class ControlledRunner: CommandRunning {
    struct Call { let executable: String; let arguments: [String] }
    var calls: [Call] = []
    var handler: (Call) throws -> CommandResult = { _ in throw Failed(message: "Unexpected command") }
    func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval?) async throws -> CommandResult {
        let call = Call(executable: executable, arguments: arguments); calls.append(call)
        return try handler(call)
    }
}
@MainActor private final class Session {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("maccet-model-check-" + UUID().uuidString)
    let runner = ControlledRunner()
    let executable: String
    var model: AppModel!
    var installs: [String] = []
    var fail: Set<String> = []
    var cancelAfterFirst = false
    var keys: [String] = ["one", "two", "three"]
    init() throws {
        // A harmless fixed executable identity is used only for path checks; the injected runner never launches it.
        executable = "/usr/bin/true"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        setenv("UNIFIED_UPDATER_DATA_DIR", root.appendingPathComponent("Data").path, 1)
        for key in keys { try write(key, version: "1.0") }
        model = AppModel(runner: runner, sourcePaths: [.homebrew: executable, .appStore: executable])
        model.preferences.scanRoots = [root.appendingPathComponent("Applications").path]
        model.preferences.includeSystemApplications = false
        runner.handler = { [unowned self] call in
            if call.executable == "/usr/bin/xcrun" { return CommandResult(output: "/usr/bin/clang") }
            if call.executable == "/usr/bin/xcode-select", call.arguments == ["--print-path"] { return CommandResult(output: "/Developer") }
            if call.executable == "/usr/bin/curl" { return CommandResult(output: #"{"assets":[]}"#) }
            if call.executable == "/bin/bash" { return CommandResult() }
            if call.arguments == ["--version"] { return CommandResult(output: "Homebrew 7.0.9") }
            if call.arguments == ["version"] { return CommandResult(output: "7.0.0") }
            if call.arguments == ["list", "--formula", "--versions", "mas"] { return CommandResult(output: "mas 7.0.0") }
            if call.arguments == ["list", "--json"] || call.arguments.first == "outdated" && !call.arguments.contains("--cask") { return CommandResult() }
            if call.arguments.first == "info" {
                if self.model.settingUp { throw Failed(message: "Inventory scan ran while preparation was active") }
                return CommandResult(output: try self.brewJSON())
            }
            if call.arguments.first == "outdated" { return CommandResult(output: try self.outdatedJSON()) }
            if call.arguments.first == "upgrade", let key = call.arguments.last {
                if call.arguments.contains("--dry-run") { return CommandResult(output: "Would update only " + key) }
                self.installs.append(key)
                if self.cancelAfterFirst { self.model.cancelRequested = true }
                if self.fail.contains(key) { return CommandResult(status: 1, errorOutput: "Controlled installation failure") }
                try self.write(key, version: "2.0"); return CommandResult()
            }
            if call.arguments == ["-q", "outdated"] { return CommandResult() }
            if call.arguments.first == "-N", let path = call.arguments.last { return CommandResult(output: path + " is not provided by a MacPorts port.") }
            throw Failed(message: "Unexpected command: \(call.executable) \(call.arguments)")
        }
    }
    func write(_ key: String, version: String) throws {
        let folder = root.appendingPathComponent("Applications/\(key).app/Contents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.maccet.model." + root.lastPathComponent + "." + key, "CFBundleName": key, "CFBundleShortVersionString": version, "CFBundleVersion": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: folder.appendingPathComponent("Info.plist"), options: .atomic)
    }
    func brewJSON() throws -> String {
        let values: [[String: Any]] = keys.map { ["token": $0, "sha256": String(repeating: "a", count: 64), "version": "2.0", "installed": "1.0", "artifacts": [["app": [$0 + ".app"], "target": root.appendingPathComponent("Applications/\($0).app").path]]] }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["casks": values]), as: UTF8.self)
    }
    func outdatedJSON() throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["casks": keys.map { ["name": $0] }]), as: UTF8.self)
    }
    func candidates() throws -> [AppRecord] {
        HomebrewAdapter.apply(casks: try HomebrewAdapter.parseCasks(brewJSON()), outdated: Set(keys), to: AppInventory().discover(roots: model.preferences.scanRoots).apps, executable: executable)
    }
    func wait() async throws {
        for _ in 0..<300 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failed(message: "UI model did not finish")
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@main private struct AppModelChecks {
    @MainActor static func main() async {
        var passed = 0; var failures = 0
        func check(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        await check("Launch checks prerequisites before scans, guards repeated appearance and preserves source failures") {
            let s = try Session(); defer { s.clean() }
            s.model.start(); s.model.start()
            try expect(s.model.settingUp && s.model.busy && s.model.apps.isEmpty, "Launch did not enter protected preparation")
            try await s.wait()
            try expect(s.runner.calls.first?.executable == "/usr/bin/xcode-select" && s.runner.calls.first?.arguments == ["--print-path"], "Application scan ran before readiness checks")
            try expect(s.runner.calls.filter { $0.executable == "/usr/bin/xcode-select" }.count == 1, "Repeated appearance reran readiness checks")
            try expect(s.runner.calls.contains { $0.arguments.first == "info" }, "Automatic source scan did not run")
            try expect(s.model.lastScan != nil && s.model.apps.count == 3, "Automatic scan did not finish")
            try expect(s.installs.isEmpty, "Opening the app updated inventory applications")
        }
        await check("Failed Apple tool preparation stays visible while read-only inventory remains usable") {
            let s = try Session(); defer { s.clean() }
            let normal = s.runner.handler
            s.runner.handler = { call in
                if call.executable == "/usr/bin/xcrun" || call.executable == "/usr/bin/xcode-select" && call.arguments == ["--print-path"] { return CommandResult(status: 1, errorOutput: "Controlled missing developer tools") }
                if call.executable == "/usr/bin/xcode-select" { return CommandResult() }
                return try normal(call)
            }
            s.model.start(); try await s.wait()
            try expect(s.model.setupNeedsAttention && s.model.setupItems[0].phase == .unavailable && s.model.setupItems[1].phase == .ready && s.model.setupItems[2].phase == .notRequired && s.model.setupItems[3].phase == .notRequired, "Unavailable prerequisites or working sources were misreported")
            try expect(s.model.apps.count == 3 && s.model.lastScan != nil, "Available inventory was hidden by setup failure")
            try expect(s.installs.isEmpty, "Preparation failure triggered an application install")
        }
        await check("Queue continues independent failures and records verified results and cleanup") {
            let s = try Session(); defer { s.clean() }; s.fail = ["three"]
            let candidates = try s.candidates()
            s.model.review = candidates.map { PlannedUpdate(app: $0, preview: "Controlled reviewed plan") }
            s.model.startUpdates(requestQuit: false)
            try await s.wait()
            try expect(s.installs == ["one", "three", "two"], "Queue did not attempt every independent app once")
            try expect(s.model.history.filter { $0.state == .succeeded }.count == 2 && s.model.history.filter { $0.state == .failed }.count == 1, "Mixed outcomes were lost")
            let operations = s.model.cacheRoot.appendingPathComponent("Operations")
            let retained = try FileManager.default.contentsOfDirectory(atPath: operations.path)
            try expect(retained.count == 3, "Cleanup removed attempt containers despite the descriptor-bound retention policy")
            let persisted = try s.model.store.load([ActivityRecord].self, file: "history.json")
            try expect(persisted.count == 3 && !persisted.contains { $0.state.isActive }, "Final queue history was not saved")
        }
        await check("Cancel Remaining allows an active install to verify and cancels later apps") {
            let s = try Session(); defer { s.clean() }; s.cancelAfterFirst = true
            s.model.review = try s.candidates().map { PlannedUpdate(app: $0, preview: "Controlled reviewed plan") }
            s.model.startUpdates(requestQuit: false)
            try await s.wait()
            try expect(s.installs.count == 1, "Remaining apps reached installation")
            try expect(s.model.history.filter { $0.state == .succeeded }.count == 1 && s.model.history.filter { $0.state == .canceled }.count == 2, "Active install was not verified independently of remaining cancellation")
        }
        await check("Store filters, selection and missing-source attention remain truthful") {
            let s = try Session(); defer { s.clean() }
            var apps = try s.candidates(); apps[0].hasStoreReceipt = true; apps[0].source = .appStore
            s.model.apps = apps; s.model.sourceFilter = .homebrew; s.model.screen = .appStore
            try expect(s.model.filteredApps.count == 1 && s.model.filteredApps[0].hasStoreReceipt, "Hidden filter hid store inventory")
            s.model.selected.insert(apps[0].id); s.model.toggleIgnored(apps[0])
            try expect(s.model.filteredApps.isEmpty && s.model.selected.isEmpty, "Ignored app remained selected or visible")
            s.model.sources = [SourceHealth(source: .macPorts, message: "Not installed")]
            try expect(s.model.sourceChecksNeedAttention, "Missing source did not show attention")
            s.model.preferences.disabledSources.insert(.macPorts)
            try expect(!s.model.sourceChecksNeedAttention, "Intentionally disabled checks were called a failure")
        }
        print("\n\(passed) UI orchestration checks passed; \(failures) failed.")
        if failures != 0 { exit(1) }
    }
}
