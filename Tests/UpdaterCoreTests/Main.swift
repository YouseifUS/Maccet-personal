import Foundation
import UpdaterCore

private struct CheckFailure: Error, CustomStringConvertible { var description: String }
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String = "Expectation failed", file: StaticString = #filePath, line: UInt = #line) throws {
    if try !condition() { throw CheckFailure(description: "\(message) (\(file):\(line))") }
}
private func expectThrows(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw CheckFailure(description: "Expected operation to throw")
}
private final class FakeRunner: CommandRunning {
    struct Call { var executable: String; var args: [String]; var environment: [String: String] }
    var calls: [Call] = []
    var handler: (Call) throws -> CommandResult
    init(handler: @escaping (Call) throws -> CommandResult) { self.handler = handler }
    func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval?) async throws -> CommandResult {
        let call = Call(executable: executable, args: arguments, environment: environment)
        calls.append(call); return try handler(call)
    }
}
private struct Fixture {
    let root: URL
    let appURL: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-check-" + UUID().uuidString)
        appURL = root.appendingPathComponent("Example.app")
        try write(version: "1.0", build: "10")
    }
    func write(version: String, build: String) throws {
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.unified-updater." + root.lastPathComponent, "CFBundleName": "Example", "CFBundleShortVersionString": version, "CFBundleVersion": build]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func app() throws -> AppRecord { try AppInventory().read(appURL.path) }
    func brewJSON(target: String = "2.0") throws -> String {
        let json: [String: Any] = ["casks": [["token": "example", "version": target, "installed": "1.0", "artifacts": [["app": ["Example.app"], "target": appURL.path]], "auto_updates": true]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }
    func candidate() throws -> AppRecord {
        HomebrewAdapter.apply(casks: try HomebrewAdapter.parseCasks(brewJSON()), outdated: ["example"], to: [try app()], executable: "/usr/bin/true")[0]
    }
    func runner(install: @escaping () throws -> Void = {}) throws -> FakeRunner {
        let inventory = try brewJSON()
        return FakeRunner { call in
            if call.args.first == "info" { return CommandResult(output: inventory) }
            if call.args.first == "outdated" { return CommandResult(output: #"{"casks":[{"name":"example","installed_versions":["1.0"],"current_version":"2.0"}]}"#) }
            if call.args.first == "upgrade" {
                if call.args.contains("--dry-run") { return CommandResult(output: "Would upgrade example to 2.0") }
                try install(); return CommandResult()
            }
            if call.args == ["--version"] { return CommandResult(output: "Homebrew 7.0.9") }
            throw UpdaterError("Unexpected command: \(call.args)")
        }
    }
}

@main
private enum Checks {
    static func main() async {
        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ action: () async throws -> Void) async {
            do { try await action(); passed += 1; print("PASS \(name)") }
            catch { failures.append("\(name): \(error)"); print("FAIL \(name): \(error)") }
        }
        await check("Numeric versions normalize trailing zeros and compare multi-digit components") {
            try expect(ReleaseComparison.compare("1.0", "1") == .orderedSame)
            try expect(ReleaseComparison.compare("2.10", "2.9") == .orderedDescending)
            try expect(ReleaseComparison.compare("1.0-beta", "1.0") == nil)
        }
        await check("Bundle scan excludes nested helpers and deduplicates overlapping roots") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let helper = fixture.appURL.appendingPathComponent("Contents/Helpers/Inner.app/Contents")
            try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture.appURL.appendingPathComponent("Contents/Info.plist"), to: helper.appendingPathComponent("Info.plist"))
            let result = AppInventory().discover(roots: [fixture.root.path, fixture.root.path])
            try expect(result.apps.count == 1)
        }
        await check("Unreadable bundle identity is reported instead of fabricated") {
            let fixture = try Fixture(); defer { fixture.clean() }
            try Data("broken".utf8).write(to: fixture.appURL.appendingPathComponent("Contents/Info.plist"))
            let result = AppInventory().discover(roots: [fixture.root.path])
            try expect(result.apps.isEmpty && !result.warnings.isEmpty)
        }
        await check("Separate copies with the same bundle ID remain distinct") {
            let fixture = try Fixture(); defer { fixture.clean() }
            try FileManager.default.copyItem(at: fixture.appURL, to: fixture.root.appendingPathComponent("Copy.app"))
            let apps = AppInventory().discover(roots: [fixture.root.path]).apps
            try expect(apps.count == 2 && apps[0].id != apps[1].id && apps[0].bundleID == apps[1].bundleID)
        }
        await check("System folders are excluded") {
            let result = AppInventory().discover(roots: ["/System/Applications"])
            try expect(result.apps.isEmpty && !result.warnings.isEmpty)
        }
        await check("Homebrew installed output is parsed and self-updating casks are checked") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let candidate = try fixture.candidate()
            try expect(candidate.state == .updateAvailable && candidate.automatic && candidate.packageID == "example")
        }
        await check("A catalog name alone cannot claim an application") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var casks = try HomebrewAdapter.parseCasks(fixture.brewJSON())
            casks[0].targets = ["/Different/Example.app"]
            let result = HomebrewAdapter.apply(casks: casks, outdated: ["example"], to: [try fixture.app()], executable: "/usr/bin/true")
            try expect(result[0].source == nil && result[0].state == .unchecked)
        }
        await check("Homebrew cannot replace an App Store edition") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var app = try fixture.app(); app.hasStoreReceipt = true
            let result = HomebrewAdapter.apply(casks: try HomebrewAdapter.parseCasks(fixture.brewJSON()), outdated: ["example"], to: [app], executable: "/usr/bin/true")
            try expect(result[0].source == nil)
        }
        await check("Multiple installed casks claiming one location block updates") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let casks = try HomebrewAdapter.parseCasks(fixture.brewJSON())
            let result = HomebrewAdapter.apply(casks: casks + casks, outdated: ["example"], to: [try fixture.app()], executable: "/usr/bin/true")
            try expect(result[0].state == .ambiguous && !result[0].automatic)
        }
        await check("A self-updated app matching the catalog is current despite a stale receipt") {
            let fixture = try Fixture(); defer { fixture.clean() }
            try fixture.write(version: "2.0", build: "20")
            let result = try fixture.candidate()
            try expect(result.state == .current && result.targetVersion == nil)
        }
        await check("A newer installed app is never offered a downgrade") {
            let fixture = try Fixture(); defer { fixture.clean() }
            try fixture.write(version: "3.0", build: "30")
            try expect(try fixture.candidate().state == .newerInstalled)
        }
        await check("Non-numeric vendor versions require a manual verifier") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let casks = try HomebrewAdapter.parseCasks(fixture.brewJSON(target: "2.0.stable_01"))
            let app = HomebrewAdapter.apply(casks: casks, outdated: ["example"], to: [try fixture.app()], executable: "/usr/bin/true")[0]
            try expect(app.state == .manual && !app.automatic)
        }
        await check("Invalid source identifiers and malformed output are rejected") {
            try expectThrows { try ToolLocator.validatePackageID("--force") }
            try expectThrows { try ToolLocator.validatePackageID("abc; touch /tmp/file") }
            try expectThrows { try ToolLocator.validateStoreID("123;whoami") }
            try expectThrows { _ = try HomebrewAdapter.parseOutdated("not JSON") }
            try expectThrows { _ = try AppStoreAdapter.parseOutdated("warning: something changed") }
        }
        await check("mas JSON preserves exact store identity, bundle ID, and normalized path") {
            let apps = try AppStoreAdapter.parseInstalled(#"{"adamID":123456789,"bundleID":"com.example.app","path":"/System/Volumes/Data/Applications/Example.app"}"#)
            try expect(apps.count == 1 && apps[0].id == "123456789" && apps[0].path == "/Applications/Example.app")
            let updates = try AppStoreAdapter.parseOutdated(" 123456789  Example App  (1.0 -> 2.0)\n")
            try expect(updates[0].target == "2.0")
        }
        await check("Store matching requires receipt, path, and bundle identity") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var app = try fixture.app(); app.hasStoreReceipt = true
            let json = "{\"adamID\":123456789,\"bundleID\":\"wrong.bundle\",\"path\":\"\(app.path)\"}"
            let matches = try AppStoreAdapter.parseInstalled(json)
            let result = AppStoreAdapter.apply(installed: matches, updates: [], to: [app], executable: "/usr/bin/true")
            try expect(result[0].state == .unchecked)
        }
        await check("Duplicate store copies block automatic installation") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var app = try fixture.app(); app.hasStoreReceipt = true
            var copy = app; copy.path += "-copy"
            let json = "{\"adamID\":123456789,\"bundleID\":\"\(app.bundleID)\",\"path\":\"\(app.path)\"}"
            let result = AppStoreAdapter.apply(installed: try AppStoreAdapter.parseInstalled(json), updates: [], to: [app, copy], executable: "/usr/bin/true")
            try expect(result[0].state == .ambiguous)
        }
        await check("Ignored paths and skipped releases are excluded from Update All") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let app = try fixture.candidate(); var prefs = Preferences()
            try expect(prefs.isEligible(app))
            prefs.ignoredPaths.insert(app.id); try expect(!prefs.isEligible(app))
            prefs.ignoredPaths = []; prefs.skippedReleases[app.id] = app.releaseIdentity
            try expect(!prefs.isEligible(app))
        }
        await check("Source failures leave store apps failed, never current") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let receipt = fixture.appURL.appendingPathComponent("Contents/_MASReceipt")
            try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
            try Data().write(to: receipt.appendingPathComponent("receipt"))
            let runner = FakeRunner { call in call.args == ["version"] ? CommandResult(output: "7.0.0") : CommandResult(status: 1, errorOutput: "Network unavailable") }
            var prefs = Preferences(); prefs.scanRoots = [fixture.root.path]; prefs.includeSystemApplications = false
            let result = await ScanService(runner: runner, sourcePaths: [.appStore: "/usr/bin/true"]).scan(preferences: prefs)
            try expect(result.apps[0].state == .failed && result.checkedCount == 0)
            try expect(result.sources.first { $0.source == .appStore }?.error != nil)
        }
        await check("Verification rejects unchanged versions and identity replacement") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let before = try fixture.candidate(); var after = before
            try expect(!UpdateEngine.verify(before: before, after: after))
            after.version = "2.0"; try expect(UpdateEngine.verify(before: before, after: after))
            after.bundleID = "wrong.bundle"; try expect(!UpdateEngine.verify(before: before, after: after))
        }
        await check("Combined release and build targets must both match") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var before = try fixture.candidate(); before.targetVersion = "2.0,20"
            var after = before; after.version = "2.0"; after.build = "19"
            try expect(!UpdateEngine.verify(before: before, after: after))
            after.build = "20"; try expect(UpdateEngine.verify(before: before, after: after))
            before.targetVersion = "2.0"; before.targetBuild = "21"
            try expect(!UpdateEngine.verify(before: before, after: after))
        }
        await check("Reviewed updates execute only the named cask and clean only after verification") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let app = try fixture.candidate()
            let runner = try fixture.runner { try fixture.write(version: "2.0", build: "20") }
            let engine = UpdateEngine(runner: runner, cacheRoot: fixture.root.appendingPathComponent("Cache"), sourcePaths: [.homebrew: "/usr/bin/true"])
            let plans = try await engine.prepare([app, app], preferences: Preferences())
            try expect(plans.count == 1)
            let result = await engine.execute(plans[0], cleanup: true) { _, _ in }
            try expect(result.state == .succeeded, result.message)
            let installs = runner.calls.filter { $0.args.first == "upgrade" && !$0.args.contains("--dry-run") }
            try expect(installs.count == 1 && installs[0].args.last == "example")
            try expect(installs[0].args.contains("--no-quit") && installs[0].args.contains("--skip-cask-deps"))
            let operations = fixture.root.appendingPathComponent("Cache/Operations")
            try expect(try FileManager.default.contentsOfDirectory(atPath: operations.path).isEmpty)
            try expect(!runner.calls.contains { $0.args.first == "cleanup" })
        }
        await check("Command success without an installed change retains artifacts and fails verification") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let runner = try fixture.runner()
            let engine = UpdateEngine(runner: runner, cacheRoot: fixture.root.appendingPathComponent("Cache"), sourcePaths: [.homebrew: "/usr/bin/true"])
            let result = await engine.execute(PlannedUpdate(app: try fixture.candidate(), preview: ""), cleanup: true) { _, _ in }
            try expect(result.state == .failed && result.message.contains("could not be verified"))
            let operations = fixture.root.appendingPathComponent("Cache/Operations")
            try expect(try FileManager.default.contentsOfDirectory(atPath: operations.path).count == 1)
        }
        await check("A changed installed version blocks a stale plan before installation") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let app = try fixture.candidate(); let runner = try fixture.runner()
            try fixture.write(version: "1.5", build: "15")
            let engine = UpdateEngine(runner: runner, sourcePaths: [.homebrew: "/usr/bin/true"])
            let result = await engine.execute(PlannedUpdate(app: app, preview: ""), cleanup: true) { _, _ in }
            try expect(result.state == .failed && !runner.calls.contains { $0.args.first == "upgrade" })
        }
        await check("Cleanup requires verified status and a matching ownership marker") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let cache = try OwnedUpdateCache(root: fixture.root.appendingPathComponent("Operations"))
            try expectThrows { try cache.removeAfterVerification(verified: false) }
            try Data("wrong marker".utf8).write(to: cache.folder.appendingPathComponent(".owner.json"))
            try expectThrows { try cache.removeAfterVerification(verified: true) }
            try expect(FileManager.default.fileExists(atPath: cache.folder.path))
        }
        await check("Cleanup does not follow nested links or remove sibling failed attempts") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let root = fixture.root.appendingPathComponent("Operations")
            let success = try OwnedUpdateCache(root: root); let failed = try OwnedUpdateCache(root: root)
            let external = fixture.root.appendingPathComponent("Keep.txt"); try Data("keep".utf8).write(to: external)
            try FileManager.default.createSymbolicLink(at: success.folder.appendingPathComponent("external"), withDestinationURL: external)
            try success.removeAfterVerification(verified: true)
            try expect(FileManager.default.fileExists(atPath: external.path) && FileManager.default.fileExists(atPath: failed.folder.path))
        }
        await check("Recovery marks active operations interrupted without retry or cleanup") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let store = LocalStore(root: fixture.root.appendingPathComponent("Store"))
            let original = ActivityRecord(app: try fixture.candidate(), state: .installing, message: "Working")
            try store.save([original], file: "history.json")
            let result = store.recover(try store.load([ActivityRecord].self, file: "history.json"))
            try expect(result[0].state == .interrupted)
        }
        await check("Diagnostics redact home locations and credential-bearing URLs") {
            let value = Diagnostics.redact(NSHomeDirectory() + "/file https://user:secret@example.com/feed?token=secret&x=1 Bearer abc.def")
            try expect(!value.contains("secret") && !value.contains(NSHomeDirectory()) && !value.contains("abc.def"))
        }
        await check("Report export redacts values without corrupting JSON") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var app = try fixture.app()
            app.sparkleFeed = "https://user:secret@example.com/feed?token=secret"
            app.detail = "Failure: https://example.com/?key=secret"
            let data = try ReportExport.data(apps: [app], sources: [], history: [], lastScan: nil)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            try expect(json?["apps"] != nil)
            try expect(!String(decoding: data, as: UTF8.self).contains("secret"))
        }
        await check("Cleanup rejects an operation folder replaced by an external symlink") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let cache = try OwnedUpdateCache(root: fixture.root.appendingPathComponent("Operations"))
            let keep = fixture.root.appendingPathComponent("Keep")
            try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
            try FileManager.default.removeItem(at: cache.folder)
            try FileManager.default.createSymbolicLink(at: cache.folder, withDestinationURL: keep)
            try expectThrows { try cache.removeAfterVerification(verified: true) }
            try expect(FileManager.default.fileExists(atPath: keep.path))
        }
        await check("An installation failure retains the isolated operation cache") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let runner = try fixture.runner { throw UpdaterError("Installer failed") }
            let engine = UpdateEngine(runner: runner, cacheRoot: fixture.root.appendingPathComponent("Cache"), sourcePaths: [.homebrew: "/usr/bin/true"])
            let result = await engine.execute(PlannedUpdate(app: try fixture.candidate(), preview: ""), cleanup: true) { _, _ in }
            try expect(result.state == .failed && result.message == "Installer failed")
            try expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("Cache/Operations").path).count == 1)
        }
        await check("A failed history-stage callback prevents installation") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let runner = try fixture.runner()
            let engine = UpdateEngine(runner: runner, sourcePaths: [.homebrew: "/usr/bin/true"])
            let result = await engine.execute(PlannedUpdate(app: try fixture.candidate(), preview: ""), cleanup: true) { _, _ in throw UpdaterError("History could not be saved") }
            try expect(result.state == .failed && runner.calls.isEmpty)
        }
        await check("A changed target in isolated source metadata blocks installation") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let runner = try fixture.runner()
            let original = runner.handler
            runner.handler = { call in
                if call.args.first == "info", call.environment["HOMEBREW_CACHE"]?.contains("Operations") == true {
                    return CommandResult(output: try fixture.brewJSON(target: "3.0"))
                }
                return try original(call)
            }
            let engine = UpdateEngine(runner: runner, cacheRoot: fixture.root.appendingPathComponent("Cache"), sourcePaths: [.homebrew: "/usr/bin/true"])
            let result = await engine.execute(PlannedUpdate(app: try fixture.candidate(), preview: ""), cleanup: true) { _, _ in }
            try expect(result.state == .failed && !runner.calls.contains { $0.args.first == "upgrade" })
        }
        await check("Canceling at the install boundary prevents mutations and records cancellation") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let runner = try fixture.runner()
            let engine = UpdateEngine(runner: runner, cacheRoot: fixture.root.appendingPathComponent("Cache"), sourcePaths: [.homebrew: "/usr/bin/true"])
            let result = await engine.execute(PlannedUpdate(app: try fixture.candidate(), preview: ""), cleanup: true) { state, _ in
                if state == .installing { throw CancellationError() }
            }
            try expect(result.state == .canceled && !runner.calls.contains { $0.args.first == "upgrade" })
        }
        await check("Cleanup failure preserves the verified update's successful result") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let cacheRoot = fixture.root.appendingPathComponent("Cache")
            let runner = try fixture.runner {
                try fixture.write(version: "2.0", build: "20")
                let folders = try FileManager.default.contentsOfDirectory(at: cacheRoot.appendingPathComponent("Operations"), includingPropertiesForKeys: nil)
                try Data("tampered".utf8).write(to: folders[0].appendingPathComponent(".owner.json"))
            }
            let engine = UpdateEngine(runner: runner, cacheRoot: cacheRoot, sourcePaths: [.homebrew: "/usr/bin/true"])
            let result = await engine.execute(PlannedUpdate(app: try fixture.candidate(), preview: ""), cleanup: true) { _, _ in }
            try expect(result.state == .succeeded && result.cleanupMessage?.contains("cleanup failed") == true)
        }
        await check("Process runner handles both streams and nonzero exit status") {
            let result = try await ProcessRunner().run("/bin/sh", ["-c", "printf hello; printf error >&2; exit 7"], environment: [:], timeout: 5)
            try expect(result.status == 7 && result.output == "hello" && result.errorOutput == "error")
            try expectThrows { _ = try result.checked() }
        }
        await check("Read-only commands have a bounded timeout") {
            do {
                _ = try await ProcessRunner().run("/bin/sleep", ["5"], environment: [:], timeout: 0.1)
                throw CheckFailure(description: "Expected timeout")
            } catch let error as UpdaterError { try expect(error.message.contains("timed out")) }
        }
        await check("MacPorts outdated output preserves full package revisions") {
            let rows = try MacPortsAdapter.parseOutdated("HexFiend 2.1.2_1 < 2.3.0_0\n")
            try expect(rows.count == 1 && rows[0].name == "HexFiend" && rows[0].target == "2.3.0_0")
            try expect(try MacPortsAdapter.parseOutdated("").isEmpty)
            try expectThrows { _ = try MacPortsAdapter.parseOutdated("Unexpected output") }
        }
        await check("MacPorts ownership requires the exact file path") {
            let path = "/Applications/Example.app/Contents/Info.plist"
            try expect(try MacPortsAdapter.parseOwner(path + " is provided by: example", path: path) == "example")
            try expect(try MacPortsAdapter.parseOwner(path + " is not provided by a MacPorts port.", path: path) == nil)
            try expectThrows { _ = try MacPortsAdapter.parseOwner("/Different/file is provided by: example", path: path) }
            for value in ["outdated", "all", "installed", "name:.*", "x;echo", "--force"] {
                try expectThrows { try MacPortsAdapter.validateName(value) }
            }
        }
        await check("MacPorts checks owned applications and leaves unrelated apps unclaimed") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let app = try fixture.app()
            let runner = FakeRunner { call in
                if call.args == ["-q", "outdated"] { return CommandResult(output: "example 1.0_0 < 2.0_1\n") }
                if call.args == ["-N", "provides", app.path + "/Contents/Info.plist"] {
                    return CommandResult(output: app.path + "/Contents/Info.plist is provided by: example\n")
                }
                throw UpdaterError("Unexpected MacPorts call")
            }
            let records = try await MacPortsAdapter(executable: "/usr/bin/true", runner: runner).check(apps: [app])
            try expect(records[0].source == .macPorts && records[0].automatic && records[0].targetPackageVersion == "2.0_1")
            runner.handler = { call in
                if call.args == ["-q", "outdated"] { return CommandResult() }
                return CommandResult(output: app.path + "/Contents/Info.plist is not provided by a MacPorts port.\n")
            }
            let other = try await MacPortsAdapter(executable: "/usr/bin/true", runner: runner).check(apps: [app])
            try expect(other[0].source == nil && other[0].state == .unchecked)
        }
        await check("A MacPorts revision-only change is manual rather than falsely verified") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let app = try fixture.app()
            let runner = FakeRunner { call in
                if call.args == ["-q", "outdated"] { return CommandResult(output: "example 1.0_0 < 1.0_1\n") }
                return CommandResult(output: app.path + "/Contents/Info.plist is provided by: example\n")
            }
            let result = try await MacPortsAdapter(executable: "/usr/bin/true", runner: runner).check(apps: [app])
            try expect(result[0].state == .manual && !result[0].automatic)
        }
        await check("Several managers produce one app with an explicit source choice") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let brewApp = try fixture.candidate()
            var portApp = brewApp; portApp.source = .macPorts; portApp.routeExecutable = "/usr/bin/false"
            let routes = [UpdateRoute(brewApp)!, UpdateRoute(portApp)!]
            let blocked = SourceResolver.resolve(try fixture.app(), routes: routes, preferred: nil)
            try expect(blocked.state == .ambiguous && !blocked.automatic && blocked.routes?.count == 2)
            let chosen = SourceResolver.resolve(blocked, routes: routes, preferred: .macPorts)
            try expect(chosen.source == .macPorts && chosen.automatic && chosen.routes?.count == 2)
        }
        await check("A store receipt cannot be switched to another manager's claimed route") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let brew = try fixture.candidate()
            var storeApp = brew; storeApp.source = .appStore; storeApp.hasStoreReceipt = true
            let result = SourceResolver.resolve(storeApp, routes: [UpdateRoute(brew)!, UpdateRoute(storeApp)!], preferred: .homebrew)
            try expect(result.source == .appStore && result.routes?.count == 1)
        }
        await check("A scan aggregates independent managers without overwriting candidates") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let brew = try fixture.runner()
            let app = try fixture.app()
            let runner = FakeRunner { call in
                if call.executable == "/usr/bin/true" { return try brew.handler(call) }
                if call.args == ["version"] { return CommandResult(output: "Version: 2.12.7") }
                if call.args == ["-q", "outdated"] { return CommandResult(output: "example 1.0_0 < 2.0_0\n") }
                if call.args.first == "-N" { return CommandResult(output: app.path + "/Contents/Info.plist is provided by: example\n") }
                throw UpdaterError("Unexpected command")
            }
            var prefs = Preferences(); prefs.scanRoots = [fixture.root.path]; prefs.includeSystemApplications = false
            prefs.preferredSources = [app.id: .homebrew]
            let result = await ScanService(runner: runner, sourcePaths: [.homebrew: "/usr/bin/true", .macPorts: "/usr/bin/false"]).scan(preferences: prefs)
            try expect(result.apps.count == 1 && result.apps[0].routes?.count == 2 && result.apps[0].source == .homebrew)
            try expect(result.sources.filter { $0.available && $0.error == nil }.count == 2)
            try expect(!runner.calls.contains { $0.args.contains("upgrade") })
            let engine = UpdateEngine(runner: runner, cacheRoot: fixture.root.appendingPathComponent("Cache"), sourcePaths: [.homebrew: "/usr/bin/true", .macPorts: "/usr/bin/false"])
            runner.calls = []
            let plan = try await engine.prepare(result.apps, preferences: prefs)
            try expect(plan.count == 1 && runner.calls.allSatisfy { $0.executable == "/usr/bin/true" })
        }
        await check("MacPorts mutation uses one named package and preserves other source caches") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var app = try fixture.candidate(); app.source = .macPorts
            let runner = FakeRunner { _ in CommandResult() }
            try await MacPortsAdapter(executable: "/opt/local/bin/port", runner: runner).upgrade(app)
            try expect(runner.calls.count == 1 && runner.calls[0].executable == "/usr/bin/osascript")
            try expect(runner.calls[0].args.last?.contains("port -N -k upgrade example") == true)
            app.packageID = "outdated"
            do { try await MacPortsAdapter(executable: "/opt/local/bin/port", runner: runner).upgrade(app); throw CheckFailure(description: "Expected rejection") }
            catch is UpdaterError { }
            try expect(runner.calls.count == 1)
        }
        await check("Discovery includes deeply nested apps and a standalone bundle root") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let nested = fixture.root.appendingPathComponent("a/b/c/d/e/f/Deep.app")
            try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture.appURL, to: nested)
            try expect(AppInventory().discover(roots: [fixture.root.path]).apps.count == 2)
            try expect(AppInventory().discover(roots: [nested.path]).apps.count == 1)
        }
        await check("System apps can be inventoried but never become third-party update targets") {
            let result = AppInventory().discover(roots: ["/System/Applications"], includeSystem: true)
            try expect(!result.apps.isEmpty && result.apps.allSatisfy { $0.state == .systemManaged })
            try expect(result.apps.allSatisfy { !Preferences().isEligible($0) })
        }
        await check("Hidden application bundles are inventoried while hidden non-app folders are pruned") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let hiddenApp = fixture.root.appendingPathComponent(".Hidden.app")
            try FileManager.default.copyItem(at: fixture.appURL, to: hiddenApp)
            let hiddenFolder = fixture.root.appendingPathComponent(".cache/Nested.app")
            try FileManager.default.createDirectory(at: hiddenFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture.appURL, to: hiddenFolder)
            let result = AppInventory().discover(roots: [fixture.root.path])
            try expect(result.apps.count == 2 && result.apps.contains { $0.path == hiddenApp.path })
        }
        await check("Hidden files and app symlinks do not prune sibling applications") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let other = fixture.root.appendingPathComponent("Other.app")
            try FileManager.default.copyItem(at: fixture.appURL, to: other)
            let root = fixture.root.appendingPathComponent("Links")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent(".localized"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("First.app"), withDestinationURL: fixture.appURL)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Second.app"), withDestinationURL: other)
            let result = AppInventory().discover(roots: [root.path])
            try expect(result.apps.count == 2)
        }
        await check("Manager subprocesses can resolve standard MacPorts dependencies") {
            let result = try await ProcessRunner().run("/usr/bin/printenv", ["PATH"], environment: [:], timeout: 5)
            try expect(result.status == 0 && result.output.contains("/opt/local/bin"))
        }
        print("\n\(passed) passed; \(failures.count) failed.")
        if !failures.isEmpty { exit(1) }
    }
}
