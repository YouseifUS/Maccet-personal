import Foundation
import Darwin
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
    struct Call { var executable: String; var args: [String]; var environment: [String: String]; var timeout: TimeInterval? }
    var calls: [Call] = []
    var handler: (Call) throws -> CommandResult
    init(handler: @escaping (Call) throws -> CommandResult) { self.handler = handler }
    func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval?) async throws -> CommandResult {
        let call = Call(executable: executable, args: arguments, environment: environment, timeout: timeout)
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

private final class SetupFixture {
    var paths = ["brew": "/opt/homebrew/bin/brew", "port": "/opt/local/bin/port", "mas": "/opt/homebrew/bin/mas"]
    var toolsMissing = false
    var failBrew = false
    var failPorts = false
    var badDigest = false
    var rejectSignature = false
    var cancelInstall = false
    var ownedMas = true
    var masVersion = "7.0.0"
    var brewVersion = "Homebrew 7.0.9"
    var portVersion = "Version: 2.12.7"
    var brokenTools: Set<String> = []
    let digest = String(repeating: "a", count: 64)
    lazy var runner = FakeRunner { [unowned self] call in
        if call.executable == "/usr/bin/xcrun" { return CommandResult(status: self.toolsMissing ? 1 : 0, output: "/Developer/usr/bin/clang") }
        if call.executable == "/usr/bin/xcode-select" {
            if call.args == ["--print-path"] { return CommandResult(status: self.toolsMissing ? 1 : 0, output: "/Developer") }
            return CommandResult()
        }
        if call.executable == "/usr/bin/curl" {
            if let index = call.args.firstIndex(of: "--output") {
                try Data("fixture package".utf8).write(to: URL(fileURLWithPath: call.args[index + 1]))
                return CommandResult()
            }
            let brew = call.args.last!.contains("Homebrew/brew")
            let name = brew ? "Homebrew.pkg" : "MacPorts-2.12.7-27-GoldenGate.pkg"
            let repository = brew ? "Homebrew/brew" : "macports/macports-base"
            let value: [String: Any] = ["assets": [["name": name, "browser_download_url": "https://github.com/" + repository + "/releases/download/v1/" + name, "digest": "sha256:" + self.digest]]]
            return CommandResult(output: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
        }
        if call.executable == "/usr/bin/shasum" { return CommandResult(output: (self.badDigest ? String(repeating: "b", count: 64) : self.digest) + "  package.pkg") }
        if call.executable == "/usr/sbin/spctl" { return CommandResult(status: self.rejectSignature ? 1 : 0, errorOutput: self.rejectSignature ? "Installer rejected" : "") }
        if call.executable == "/bin/bash" {
            switch call.args[1] {
            case "brew-update": return CommandResult(status: self.failBrew ? 1 : 0, errorOutput: self.failBrew ? "Network unavailable" : "")
            case "ports-update": return CommandResult(status: self.failPorts ? 1 : 0, errorOutput: self.failPorts ? "Network unavailable" : "")
            case "ports-mas-update": return CommandResult()
            case "mas-install", "mas-update": self.paths["mas"] = "/opt/homebrew/bin/mas"; return CommandResult()
            case "install-package":
                if self.cancelInstall { return CommandResult(status: 1, errorOutput: "User canceled. (-128)") }
                if call.args[2].hasSuffix("Homebrew.pkg") { self.paths["brew"] = "/opt/homebrew/bin/brew" }
                else { self.paths["port"] = "/opt/local/bin/port" }
                return CommandResult()
            default: throw UpdaterError("Unexpected script action")
            }
        }
        if call.args == ["list", "--formula", "--versions", "mas"] { return CommandResult(status: self.ownedMas ? 0 : 1, output: self.ownedMas ? "mas 7.0.0" : "") }
        if self.brokenTools.contains(where: { self.paths[$0] == call.executable }), call.args == ["--version"] || call.args == ["version"] {
            return CommandResult(status: 1, errorOutput: "Tool cannot start")
        }
        if call.executable == self.paths["brew"], call.args == ["--version"] { return CommandResult(output: self.brewVersion) }
        if call.executable == self.paths["port"], call.args == ["version"] { return CommandResult(output: self.portVersion) }
        if call.executable == self.paths["mas"], call.args == ["version"] { return CommandResult(output: self.masVersion) }
        throw UpdaterError("Unexpected setup command: " + call.executable + " " + call.args.joined(separator: " "))
    }
    func service(architecture: String = "arm64") -> DependencySetup {
        DependencySetup(runner: runner, locate: { [unowned self] in self.paths[$0] }, osMajor: 27, architecture: architecture)
    }
    var actions: [String] { runner.calls.filter { $0.executable == "/bin/bash" }.map { $0.args[1] } }
}

@main
private enum Checks {
    static func main() async {
        if CommandLine.arguments.contains("--inspect-output-permissions") {
            var paths: [String] = []
            for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                guard fcntl(descriptor, F_GETPATH, &path) != -1 else { exit(2) }
                paths.append(String(cString: path))
            }
            let locations = [URL(fileURLWithPath: paths[0]).deletingLastPathComponent().path] + paths
            for path in locations {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), let mode = attributes[.posixPermissions] as? NSNumber else { exit(2) }
                print(String(mode.intValue & 0o777, radix: 8))
            }
            return
        }
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
        await check("App Store and MacPorts verification reject a build-only target match") {
            let fixture = try Fixture(); defer { fixture.clean() }
            for source in [UpdateSource.appStore, .macPorts] {
                var before = try fixture.candidate(); before.source = source
                before.hasStoreReceipt = source == .appStore
                var after = before; after.build = "2.0"
                try expect(!UpdateEngine.verify(before: before, after: after), "A changed build is not the reviewed marketing version for \(source.title)")
                after.version = "1.5"
                try expect(!UpdateEngine.verify(before: before, after: after), "A different marketing version is not the reviewed target for \(source.title)")
            }
        }
        await check("App Store and MacPorts verification accept the reviewed marketing version") {
            let fixture = try Fixture(); defer { fixture.clean() }
            for source in [UpdateSource.appStore, .macPorts] {
                var before = try fixture.candidate(); before.source = source
                before.hasStoreReceipt = source == .appStore
                var after = before; after.version = "2.0.0"
                try expect(UpdateEngine.verify(before: before, after: after), "Normalized marketing versions should match for \(source.title)")
                before.targetBuild = "20"
                try expect(!UpdateEngine.verify(before: before, after: after))
                after.build = "20"
                try expect(UpdateEngine.verify(before: before, after: after))
                after.bundleID = "wrong.bundle"
                try expect(!UpdateEngine.verify(before: before, after: after))
            }
        }
        await check("Homebrew verification retains build-only catalog targets") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var before = try fixture.candidate(); before.targetVersion = "20"
            var after = before; after.build = "20"
            try expect(UpdateEngine.verify(before: before, after: after))
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
        await check("A changed application path blocks review before any manager command") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let app = try fixture.candidate()
            let relocated = fixture.root.appendingPathComponent("Relocated.app")
            try FileManager.default.moveItem(at: fixture.appURL, to: relocated)
            try FileManager.default.createSymbolicLink(at: fixture.appURL, withDestinationURL: relocated)
            let runner = try fixture.runner()
            let engine = UpdateEngine(runner: runner, sourcePaths: [.homebrew: "/usr/bin/true"])
            do {
                _ = try await engine.prepare([app], preferences: Preferences())
                throw CheckFailure(description: "A changed canonical path produced a review plan")
            } catch let error as UpdaterError {
                try expect(error.message.contains("changed after the scan"))
            }
            try expect(runner.calls.isEmpty, "A changed canonical path reached a manager during review")
        }
        await check("A reviewed path replaced by a symlink fails before commands or cache creation") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let runner = try fixture.runner()
            let cacheRoot = fixture.root.appendingPathComponent("Cache")
            let engine = UpdateEngine(runner: runner, cacheRoot: cacheRoot, sourcePaths: [.homebrew: "/usr/bin/true"])
            let plan = try await engine.prepare([fixture.candidate()], preferences: Preferences())[0]
            runner.calls = []
            let relocated = fixture.root.appendingPathComponent("Relocated.app")
            try FileManager.default.moveItem(at: fixture.appURL, to: relocated)
            try FileManager.default.createSymbolicLink(at: fixture.appURL, withDestinationURL: relocated)
            let fresh = try fixture.app()
            try expect(fresh.bundleID == plan.app.bundleID && fresh.version == plan.app.version && fresh.build == plan.app.build && fresh.path != plan.app.path)
            var stages: [TaskState] = []
            let result = await engine.execute(plan, cleanup: true) { stage, _ in stages.append(stage) }
            try expect(result.state == .failed && result.message.contains("changed after the scan"))
            try expect(runner.calls.isEmpty && stages == [.preflight], "The changed path reached a source command or installer")
            try expect(!FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("Operations").path))
            try expect(try fixture.app().version == "1.0" && FileManager.default.fileExists(atPath: relocated.path))
        }
        await check("Replacing an application's parent directory with a symlink blocks execution") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let parent = fixture.root.appendingPathComponent("Managed")
            let relocated = fixture.root.appendingPathComponent("Relocated")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            var app = try fixture.candidate()
            try FileManager.default.moveItem(at: fixture.appURL, to: parent.appendingPathComponent("Example.app"))
            app.path = parent.appendingPathComponent("Example.app").path
            try FileManager.default.moveItem(at: parent, to: relocated)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: relocated)
            let runner = try fixture.runner()
            let result = await UpdateEngine(runner: runner, sourcePaths: [.homebrew: "/usr/bin/true"])
                .execute(PlannedUpdate(app: app, preview: ""), cleanup: true) { _, _ in }
            try expect(result.state == .failed && runner.calls.isEmpty, "A changed parent path reached a source command")
        }
        await check("A path changed during source checking is rejected by isolated preflight") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let app = try fixture.candidate()
            let runner = try fixture.runner()
            let normal = runner.handler
            var relocated = false
            runner.handler = { call in
                if call.args.first == "info", !relocated {
                    let target = fixture.root.appendingPathComponent("Relocated.app")
                    try FileManager.default.moveItem(at: fixture.appURL, to: target)
                    try FileManager.default.createSymbolicLink(at: fixture.appURL, withDestinationURL: target)
                    relocated = true
                }
                return try normal(call)
            }
            let cacheRoot = fixture.root.appendingPathComponent("Cache")
            let result = await UpdateEngine(runner: runner, cacheRoot: cacheRoot, sourcePaths: [.homebrew: "/usr/bin/true"])
                .execute(PlannedUpdate(app: app, preview: ""), cleanup: true) { _, _ in }
            try expect(result.state == .failed && result.message.contains("changed after the scan"))
            try expect(!runner.calls.contains { $0.args.first == "upgrade" } && runner.calls.filter { $0.args.first == "info" }.count == 1)
            try expect(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.appendingPathComponent("Operations").path).count == 1, "Failed-attempt artifacts were removed")
        }
        await check("A stable application symlink discovered before review remains updateable") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let target = fixture.root.appendingPathComponent("Actual.app")
            try FileManager.default.moveItem(at: fixture.appURL, to: target)
            try FileManager.default.createSymbolicLink(at: fixture.appURL, withDestinationURL: target)
            let app = try fixture.candidate()
            try expect(app.path == target.path)
            let runner = try fixture.runner { try fixture.write(version: "2.0", build: "20") }
            let engine = UpdateEngine(runner: runner, cacheRoot: fixture.root.appendingPathComponent("Cache"), sourcePaths: [.homebrew: "/usr/bin/true"])
            let plan = try await engine.prepare([app], preferences: Preferences())[0]
            let result = await engine.execute(plan, cleanup: true) { _, _ in }
            try expect(result.state == .succeeded, result.message)
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
        await check("Cleanup rejects a replacement directory carrying a copied ownership marker") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let fm = FileManager.default
            let cache = try OwnedUpdateCache(root: fixture.root.appendingPathComponent("Operations"))
            let retained = fixture.root.appendingPathComponent("OriginalAttempt")
            try fm.moveItem(at: cache.folder, to: retained)
            try fm.copyItem(at: retained, to: cache.folder)
            let keep = cache.folder.appendingPathComponent("Keep.txt")
            try Data("replacement data".utf8).write(to: keep)
            try expectThrows { try cache.removeAfterVerification(verified: true) }
            try expect(fm.fileExists(atPath: keep.path) && fm.fileExists(atPath: retained.path))
        }
        await check("Cleanup rejects a replaced cache root even when the original attempt is moved back") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let fm = FileManager.default
            let root = fixture.root.appendingPathComponent("Operations")
            let cache = try OwnedUpdateCache(root: root)
            let retained = fixture.root.appendingPathComponent("OriginalRoot")
            try fm.moveItem(at: root, to: retained)
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            try fm.moveItem(at: retained.appendingPathComponent(cache.folder.lastPathComponent), to: cache.folder)
            let keep = cache.folder.appendingPathComponent("Keep.txt")
            try Data("retained data".utf8).write(to: keep)
            try expectThrows { try cache.removeAfterVerification(verified: true) }
            try expect(fm.fileExists(atPath: keep.path) && fm.fileExists(atPath: retained.path))
        }
        await check("A replaced cache is retained and cleanup failure does not undo verified success") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let fm = FileManager.default
            let cacheRoot = fixture.root.appendingPathComponent("Cache")
            let retained = fixture.root.appendingPathComponent("OriginalAttempt")
            var replacement: URL?
            let runner = try fixture.runner {
                try fixture.write(version: "2.0", build: "20")
                let attempts = try fm.contentsOfDirectory(at: cacheRoot.appendingPathComponent("Operations"), includingPropertiesForKeys: nil)
                let folder = attempts[0]
                try fm.moveItem(at: folder, to: retained)
                try fm.copyItem(at: retained, to: folder)
                try Data("replacement data".utf8).write(to: folder.appendingPathComponent("Keep.txt"))
                replacement = folder
            }
            let engine = UpdateEngine(runner: runner, cacheRoot: cacheRoot, sourcePaths: [.homebrew: "/usr/bin/true"])
            let result = await engine.execute(PlannedUpdate(app: try fixture.candidate(), preview: ""), cleanup: true) { _, _ in }
            try expect(result.state == .succeeded && result.cleanupMessage?.contains("cleanup failed") == true)
            guard let replacement else { throw CheckFailure(description: "Fixture installer did not run") }
            try expect(fm.fileExists(atPath: replacement.appendingPathComponent("Keep.txt").path))
            try expect(fm.fileExists(atPath: retained.path))
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
        await check("Captured output is private under permissive and restrictive process masks") {
            // These checks run serially; restore the process-wide test mask even
            // if the assertion fails. No production code changes the user's mask.
            let originalMask = umask(0o000)
            defer { umask(originalMask) }
            let masks: [mode_t] = [0o000, 0o022, 0o077]
            for mask in masks {
                umask(mask)
                let result = try await ProcessRunner().run(URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path, ["--inspect-output-permissions"], environment: [:], timeout: 5)
                try expect(result.status == 0)
                try expect(result.output.split(whereSeparator: \.isNewline).map(String.init) == ["700", "600", "600"], "Raw process capture was not private under mask " + String(mask, radix: 8))
            }
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
        await check("An empty inventory performs no source checks or source failures") {
            let runner = FakeRunner { _ in throw UpdaterError("No source should be called") }
            var prefs = Preferences(); prefs.scanRoots = []; prefs.includeSystemApplications = false
            let result = await ScanService(runner: runner, sourcePaths: [.homebrew: "/usr/bin/true", .macPorts: "/usr/bin/true", .appStore: "/usr/bin/true"]).scan(preferences: prefs)
            try expect(runner.calls.isEmpty && result.sources.allSatisfy { $0.error == nil }, "Unnecessary source checks were reported as failures")
            try expect(result.sources.allSatisfy { $0.checkRequired == false && !$0.needsAttention })
        }
        await check("Non-store inventory does not fail an unnecessary App Store check") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let runner = FakeRunner { _ in throw UpdaterError("No App Store check should be called") }
            var prefs = Preferences(); prefs.scanRoots = [fixture.root.path]; prefs.includeSystemApplications = false; prefs.disabledSources = [.homebrew, .macPorts]
            let result = await ScanService(runner: runner, sourcePaths: [.appStore: "/usr/bin/true"]).scan(preferences: prefs)
            try expect(runner.calls.isEmpty && result.sources.first { $0.source == .appStore }?.error == nil, "An unnecessary App Store check produced a failure")
            try expect(result.sources.first { $0.source == .appStore }?.checkRequired == false && result.checkedCount == 0 && result.apps[0].state == .unchecked)
        }
        await check("Missing tools for an empty inventory are unnecessary rather than failed") {
            let runner = FakeRunner { _ in throw UpdaterError("No command expected") }
            var prefs = Preferences(); prefs.scanRoots = []; prefs.includeSystemApplications = false
            let result = await ScanService(runner: runner, sourcePaths: [:]).scan(preferences: prefs)
            try expect(runner.calls.isEmpty && result.sources.allSatisfy { !$0.available && $0.checkRequired == false && !$0.needsAttention })
        }
        await check("Store-only source checks skip managers while preserving verified store results") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let receipt = fixture.appURL.appendingPathComponent("Contents/_MASReceipt")
            try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: false)
            try Data().write(to: receipt.appendingPathComponent("receipt"))
            let app = try fixture.app()
            let installed = String(decoding: try JSONSerialization.data(withJSONObject: ["adamID": 123456789, "bundleID": app.bundleID, "path": app.path]), as: UTF8.self)
            let runner = FakeRunner { call in
                guard call.executable == "/usr/bin/true" else { throw UpdaterError("An unrelated manager was checked") }
                if call.args == ["version"] { return CommandResult(output: "7.0.0") }
                if call.args == ["list", "--json"] { return CommandResult(output: installed) }
                return CommandResult()
            }
            var prefs = Preferences(); prefs.scanRoots = [fixture.root.path]; prefs.includeSystemApplications = false
            let result = await ScanService(runner: runner, sourcePaths: [.homebrew: "/usr/bin/false", .macPorts: "/bin/echo", .appStore: "/usr/bin/true"]).scan(preferences: prefs)
            try expect(result.checkedCount == 1 && result.apps[0].state == .current)
            try expect(runner.calls.count == 3 && runner.calls.allSatisfy { $0.executable == "/usr/bin/true" })
            try expect(result.sources.filter { $0.source != .appStore }.allSatisfy { $0.available && $0.checkRequired == false && !$0.needsAttention })
        }
        await check("Required missing and failed sources still need attention") {
            let fixture = try Fixture(); defer { fixture.clean() }
            for present in [false, true] {
                let runner = FakeRunner { _ in throw UpdaterError("Controlled source failure") }
                var prefs = Preferences(); prefs.scanRoots = [fixture.root.path]; prefs.includeSystemApplications = false; prefs.disabledSources = [.macPorts, .appStore]
                let result = await ScanService(runner: runner, sourcePaths: present ? [.homebrew: "/usr/bin/true"] : [:]).scan(preferences: prefs)
                let health = result.sources.first { $0.source == .homebrew }!
                try expect(health.checkRequired == true && health.needsAttention && result.checkedCount == 0)
                try expect(health.available == present && (health.error != nil) == present)
            }
        }
        await check("Inventory warnings keep source checks and failure attention conservative") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let runner = FakeRunner { _ in throw UpdaterError("Offline") }
            var prefs = Preferences(); prefs.scanRoots = [fixture.root.appendingPathComponent("Missing").path]; prefs.includeSystemApplications = false
            let result = await ScanService(runner: runner, sourcePaths: [.appStore: "/usr/bin/true"]).scan(preferences: prefs)
            try expect(!result.warnings.isEmpty && runner.calls.count == 1)
            try expect(result.sources.filter { $0.source != .macPorts }.allSatisfy { $0.checkRequired == true && $0.needsAttention })
            try expect(result.sources.first { $0.source == .macPorts }?.checkRequired == false)
        }
        await check("Old source reports decode conservatively and skipped status round-trips") {
            let data = Data(#"{"source":"macPorts","version":"","available":false,"message":"Not installed"}"#.utf8)
            var health = try JSONDecoder().decode(SourceHealth.self, from: data)
            try expect(health.checkRequired == nil && health.needsAttention)
            health.checkRequired = false
            let restored = try JSONDecoder().decode(SourceHealth.self, from: JSONEncoder().encode(health))
            try expect(restored.checkRequired == false && !restored.needsAttention && !restored.available)
        }
        await check("Disabled source settings take precedence over skipped check status") {
            let runner = FakeRunner { _ in throw UpdaterError("No command expected") }
            var prefs = Preferences(); prefs.scanRoots = []; prefs.includeSystemApplications = false; prefs.disabledSources = Set(UpdateSource.allCases)
            let result = await ScanService(runner: runner, sourcePaths: [.homebrew: "/usr/bin/true"]).scan(preferences: prefs)
            try expect(runner.calls.isEmpty && result.sources.allSatisfy { $0.message == "Disabled in Settings." && $0.checkRequired == false && !$0.needsAttention })
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
        await check("Readiness checks report canonical tools and versions without maintenance") {
            let fixture = SetupFixture()
            let result = await fixture.service().checkReadiness()
            try expect(result.allSatisfy { $0.phase == .ready } && fixture.actions.isEmpty)
            for item in result.dropFirst() {
                try expect(item.executablePath == ToolLocator.canonicalPath(fixture.paths[item.id]!) && item.version?.isEmpty == false)
            }
            try expect(fixture.runner.calls.count == 4 && fixture.runner.calls.allSatisfy { $0.timeout == 20 })
        }
        await check("Readiness rejects malformed tool versions without publishing raw text as a version") {
            let rows: [(UpdateSource, Int, [String])] = [
                (.homebrew, 1, ["not a version", "7.0.9", "Homebrew 7.invalid", "Homebrew 7.0.9-junk"]),
                (.macPorts, 2, ["not a version", "2.12.7", "Version: unknown", "Version: 2.12.7 junk"]),
                (.appStore, 3, ["not a version", "7garbage.0.0", "7.0", "7.0.0 junk"])
            ]
            for (source, index, outputs) in rows {
                for output in outputs {
                    let setup = SetupFixture()
                    if source == .homebrew { setup.brewVersion = output }
                    if source == .macPorts { setup.portVersion = output }
                    if source == .appStore { setup.masVersion = output }
                    let result = await setup.service().checkReadiness(disabledSources: Set(UpdateSource.allCases).subtracting([source]))
                    try expect(result[index].phase == .failed && result[index].version == nil && setup.actions.isEmpty, "Malformed version was ready: " + output)
                }
            }
        }
        await check("Source version minimums and normalized values are explicit") {
            let rows: [(UpdateSource, Int, String, String, String)] = [
                (.homebrew, 1, "Homebrew 6.0.0", "Homebrew 5.9.9", "6.0.0"),
                (.macPorts, 2, "Version: 2.8.1", "Version: 2.8.0", "2.8.1"),
                (.appStore, 3, "7.0.0", "6.9.9", "7.0.0")
            ]
            for (source, index, supported, unsupported, normalized) in rows {
                for (raw, ready) in [(supported, true), (unsupported, false)] {
                    let setup = SetupFixture()
                    if source == .homebrew { setup.brewVersion = raw }
                    if source == .macPorts { setup.portVersion = raw }
                    if source == .appStore { setup.masVersion = raw }
                    let result = await setup.service().checkReadiness(disabledSources: Set(UpdateSource.allCases).subtracting([source]))
                    try expect(result[index].phase == (ready ? .ready : .failed))
                    try expect(result[index].version == (ready ? normalized : nil))
                }
            }
        }
        await check("Source scans reject unknown tool versions before parsing manager results") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let runner = FakeRunner { _ in CommandResult(output: "not a version") }
            var prefs = Preferences(); prefs.scanRoots = [fixture.root.path]; prefs.includeSystemApplications = false; prefs.disabledSources = [.macPorts, .appStore]
            let result = await ScanService(runner: runner, sourcePaths: [.homebrew: "/usr/bin/true"]).scan(preferences: prefs)
            try expect(result.checkedCount == 0 && result.sources.first { $0.source == .homebrew }?.error != nil)
            try expect(runner.calls.count == 1 && runner.calls[0].args == ["--version"])
        }
        await check("All missing tools remain unavailable without downloading or launching installers") {
            let fixture = SetupFixture(); fixture.paths = [:]; fixture.toolsMissing = true
            let result = await fixture.service().checkReadiness()
            try expect([0, 1, 3].allSatisfy { result[$0].phase == .unavailable && result[$0].phase.needsAttention } && result[2].phase == .notRequired)
            try expect(fixture.runner.calls.count == 1 && fixture.runner.calls[0].executable == "/usr/bin/xcode-select" && fixture.runner.calls[0].args == ["--print-path"])
        }
        await check("Readiness still reports working source tools when Apple tools are unavailable") {
            let fixture = SetupFixture(); fixture.toolsMissing = true
            let result = await fixture.service().checkReadiness()
            try expect(result[0].phase == .unavailable && result.dropFirst().allSatisfy { $0.phase == .ready })
            try expect(fixture.runner.calls.count == 4 && fixture.actions.isEmpty)
        }
        await check("Readiness rejects an incompatible helper without trying to upgrade it") {
            let fixture = SetupFixture(); fixture.masVersion = "6.0.0"
            let result = await fixture.service().checkReadiness()
            try expect(result[3].phase == .failed && result[3].message.contains("mas 7 or later") && result[3].version == nil)
            try expect(result[1].phase == .ready && result[2].phase == .ready && fixture.actions.isEmpty)
        }
        await check("Failed read-only probes preserve independent tools without attempting repairs") {
            let fixture = SetupFixture(); fixture.brokenTools = ["brew"]
            let result = await fixture.service().checkReadiness()
            try expect(result[1].phase == .failed && result[1].message.contains("Tool cannot start"))
            try expect(result[2].phase == .ready && result[3].phase == .ready && fixture.actions.isEmpty)
        }
        await check("Readiness checks only the enabled relevant source") {
            let fixture = SetupFixture(); fixture.paths = ["brew": "/opt/homebrew/bin/brew"]
            let result = await fixture.service().checkReadiness(disabledSources: [.macPorts, .appStore])
            try expect(result[1].phase == .ready && result[2].phase == .disabled && result[3].phase == .disabled)
            try expect(fixture.runner.calls.count == 2 && fixture.actions.isEmpty)
        }
        await check("Readiness skips all commands for disabled sources or an empty inventory") {
            for disabled in [false, true] {
                let fixture = SetupFixture(); fixture.paths = [:]; fixture.toolsMissing = true
                let result = await fixture.service().checkReadiness(inventory: disabled ? nil : AppInventory().discover(roots: []), disabledSources: disabled ? Set(UpdateSource.allCases) : [])
                try expect(fixture.runner.calls.isEmpty && result[0].phase == .notRequired)
                try expect(result.dropFirst().allSatisfy { $0.phase == (disabled ? .disabled : .notRequired) })
            }
        }
        await check("Store-only runtime readiness does not require the helper maintenance manager") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var inventory = AppInventory().discover(roots: [fixture.root.path]); inventory.apps[0].hasStoreReceipt = true
            let setup = SetupFixture(); setup.paths["mas"] = "/opt/local/bin/mas"
            let result = await setup.service().checkReadiness(inventory: inventory)
            try expect(result[0].phase == .notRequired && result[1].phase == .notRequired && result[2].phase == .notRequired && result[3].phase == .ready)
            try expect(result.allSatisfy { $0.dependencyFor == nil } && setup.runner.calls.count == 1 && setup.actions.isEmpty)
        }
        await check("A working mas without disabled managers is runtime ready without developer tools") {
            for path in ["/usr/local/bin/mas", "/opt/local/bin/mas"] {
                let fixture = try Fixture(); defer { fixture.clean() }
                var inventory = AppInventory().discover(roots: [fixture.root.path]); inventory.apps[0].hasStoreReceipt = true
                let setup = SetupFixture(); setup.paths = ["mas": path]; setup.toolsMissing = true
                let result = await setup.service().checkReadiness(inventory: inventory, disabledSources: [.homebrew, .macPorts])
                try expect(result[0].phase == .notRequired && result[1].phase == .disabled && result[2].phase == .disabled && result[3].phase == .ready)
                try expect(!result.contains { $0.phase.needsAttention } && result.allSatisfy { $0.dependencyFor == nil })
                try expect(setup.runner.calls.count == 1 && setup.runner.calls[0].executable == path && setup.actions.isEmpty)
            }
        }
        await check("Missing or broken mas requests attention without claiming its disabled manager is unavailable") {
            for state in ["missing", "broken", "old"] {
                let setup = SetupFixture(); setup.paths = state == "missing" ? [:] : ["mas": "/usr/local/bin/mas"]
                setup.toolsMissing = true
                if state == "broken" { setup.brokenTools = ["mas"] }
                if state == "old" { setup.masVersion = "6.0.0" }
                let result = await setup.service().checkReadiness(disabledSources: [.homebrew, .macPorts])
                try expect(result[0].phase == .notRequired && result[1].phase == .disabled && result[2].phase == .disabled && result[3].phase.needsAttention)
                try expect(setup.actions.isEmpty && !setup.runner.calls.contains { $0.executable == "/usr/bin/xcode-select" })
            }
        }
        await check("Metadata refresh requests API checks and port sync without broader preparation") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let runner = FakeRunner { call in
                if call.args == ["--version"] { return CommandResult(output: "Homebrew 7.0.9") }
                if call.args == ["version"] { return CommandResult(output: "Version: 2.12.7") }
                if call.args == ["outdated", "--cask", "--greedy", "--json=v2"] { return CommandResult(output: #"{"casks":[]}"#) }
                if call.executable == "/bin/bash", call.args.last == "ports-sync" { return CommandResult() }
                throw UpdaterError("Broader maintenance requested")
            }
            let cache = fixture.root.appendingPathComponent("MetadataCache")
            let service = SourceMetadataRefresh(runner: runner, cacheRoot: cache, locate: { $0 == "brew" ? "/opt/homebrew/bin/brew" : $0 == "port" ? "/opt/local/bin/port" : nil }, homebrewAPIEnabled: true)
            let results = await service.refresh(inventory: AppInventory().discover(roots: [fixture.root.path]))
            try expect(results[0].phase == .ready && results[1].phase == .ready && results[2].phase == .notRequired)
            let api = runner.calls.first { $0.args.first == "outdated" }!
            try expect(api.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1" && api.environment["HOMEBREW_FORCE_API_AUTO_UPDATE"] == "1" && api.environment["HOMEBREW_API_AUTO_UPDATE_SECS"] == "0")
            try expect(api.environment["HOMEBREW_CACHE"] == cache.appendingPathComponent("Homebrew").path)
            try expect(runner.calls.count == 4 && !runner.calls.contains { $0.args.contains("install") || $0.args.contains("upgrade") || $0.args.contains("brew-update") || $0.args.contains("ports-update") })
        }
        await check("Metadata refresh never installs missing tools or expands disabled and store-only scopes") {
            let setup = SetupFixture(); setup.paths = [:]
            let service = SourceMetadataRefresh(runner: setup.runner, locate: { setup.paths[$0] })
            let missing = await service.refresh()
            try expect(missing[0].phase == .unavailable && missing[1].phase == .notRequired && missing[2].phase == .notRequired && setup.runner.calls.isEmpty)
            let disabled = await service.refresh(disabledSources: Set(UpdateSource.allCases))
            try expect(disabled.allSatisfy { $0.phase == .disabled } && setup.runner.calls.isEmpty)
            let fixture = try Fixture(); defer { fixture.clean() }
            var inventory = AppInventory().discover(roots: [fixture.root.path]); inventory.apps[0].hasStoreReceipt = true
            let storeOnly = await service.refresh(inventory: inventory)
            try expect(storeOnly.allSatisfy { $0.phase == .notRequired } && setup.runner.calls.isEmpty)
        }
        await check("Metadata failures remain independent and Git mode does not broaden its request") {
            for gitMode in [false, true] {
                let runner = FakeRunner { call in
                    if call.args == ["--version"] { return CommandResult(output: "Homebrew 7.0.9") }
                    if call.args == ["version"] { return CommandResult(output: "Version: 2.12.7") }
                    if call.args.first == "outdated" { return CommandResult(status: 1, errorOutput: "Offline") }
                    if call.executable == "/bin/bash", call.args.last == "ports-sync" { return CommandResult() }
                    throw UpdaterError("Unexpected maintenance")
                }
                let service = SourceMetadataRefresh(runner: runner, locate: { $0 == "brew" ? "/opt/homebrew/bin/brew" : $0 == "port" ? "/opt/local/bin/port" : nil }, homebrewAPIEnabled: !gitMode)
                let results = await service.refresh()
                try expect(results[0].phase == .failed && results[1].phase == .ready)
                try expect(!runner.calls.contains { $0.args.contains("brew-update") || $0.args.contains("ports-update") || $0.args.contains("mas-update") || $0.executable == "/usr/bin/curl" })
                if gitMode { try expect(!runner.calls.contains { $0.args.first == "outdated" }) }
            }
        }
        await check("Metadata refresh rejects changed tool destinations before index mutation") {
            var brew = "/usr/bin/true"
            let runner = FakeRunner { _ in brew = "/usr/bin/false"; return CommandResult(output: "Homebrew 7.0.9") }
            let service = SourceMetadataRefresh(runner: runner, locate: { $0 == "brew" ? brew : nil })
            let results = await service.refresh(disabledSources: [.macPorts, .appStore])
            try expect(results[0].phase == .failed && runner.calls.count == 1)
        }
        await check("Explicit preparation updates all three dependencies without upgrading applications") {
            let fixture = SetupFixture()
            var snapshots: [[SetupItem]] = []
            let result = await fixture.service().prepare { snapshots.append($0) }
            try expect(result.allSatisfy { $0.phase == .ready })
            try expect(fixture.actions == ["brew-update", "ports-update", "mas-update"])
            try expect(snapshots.contains { $0.contains { $0.phase == .running } })
            try expect(fixture.runner.calls.allSatisfy { !$0.args.contains("outdated") && !$0.args.contains("--cask") })
        }
        await check("Disabled sources run no setup commands even when all tools are missing") {
            let fixture = SetupFixture(); fixture.paths = [:]; fixture.toolsMissing = true
            let result = await fixture.service().prepare(disabledSources: Set(UpdateSource.allCases))
            try expect(fixture.runner.calls.isEmpty)
            try expect(result[0].phase == .notRequired && result.dropFirst().allSatisfy { $0.phase == .disabled })
        }
        await check("Homebrew-only setup leaves disabled missing MacPorts and mas untouched") {
            let fixture = SetupFixture(); fixture.paths = ["brew": "/opt/homebrew/bin/brew"]
            let result = await fixture.service().prepare(disabledSources: [.macPorts, .appStore])
            try expect(fixture.actions == ["brew-update"])
            try expect(result[1].phase == .ready && result[2].phase == .disabled && result[3].phase == .disabled)
            try expect(!fixture.runner.calls.contains { $0.executable == "/usr/bin/curl" })
        }
        await check("MacPorts-only setup leaves disabled missing Homebrew and mas untouched") {
            let fixture = SetupFixture(); fixture.paths = ["port": "/opt/local/bin/port"]
            let result = await fixture.service().prepare(disabledSources: [.homebrew, .appStore])
            try expect(fixture.actions == ["ports-update"])
            try expect(result[1].phase == .disabled && result[2].phase == .ready && result[3].phase == .disabled)
        }
        await check("App Store setup prepares disabled Homebrew as an explicit helper dependency") {
            let fixture = SetupFixture(); fixture.paths.removeValue(forKey: "port")
            let result = await fixture.service().prepare(disabledSources: [.homebrew, .macPorts])
            try expect(fixture.actions == ["brew-update", "mas-update"])
            try expect(result[1].phase == .ready && result[1].dependencyFor == .appStore && result[2].phase == .disabled && result[3].phase == .ready)
        }
        await check("A MacPorts-owned App Store helper requires only its manager") {
            let fixture = SetupFixture(); fixture.paths["mas"] = "/opt/local/bin/mas"
            let result = await fixture.service().prepare(disabledSources: [.homebrew, .macPorts])
            try expect(fixture.actions == ["ports-update", "ports-mas-update"])
            try expect(result[1].phase == .disabled && result[2].dependencyFor == .appStore && result[3].phase == .ready)
        }
        await check("A missing App Store helper installs only its required Homebrew route") {
            let fixture = SetupFixture(); fixture.paths = [:]; fixture.ownedMas = false
            let result = await fixture.service().prepare(disabledSources: [.homebrew, .macPorts])
            try expect(fixture.actions == ["install-package", "brew-update", "mas-install"])
            try expect(result[1].dependencyFor == .appStore && result[2].phase == .disabled && result[3].phase == .ready)
        }
        await check("Disabled steps stay disabled when developer tools are missing") {
            let fixture = SetupFixture(); fixture.toolsMissing = true
            let result = await fixture.service().prepare(disabledSources: [.macPorts, .appStore])
            try expect(result[0].phase == .failed && result[1].phase == .failed && result[2].phase == .disabled && result[3].phase == .disabled)
            try expect(fixture.actions.isEmpty)
        }
        await check("Retry respects source changes and re-enabling prepares only unfinished work") {
            let fixture = SetupFixture(); fixture.failPorts = true
            let first = await fixture.service().prepare()
            let disabled = await fixture.service().prepare(disabledSources: [.macPorts], retrying: first)
            try expect(disabled[2].phase == .disabled && !disabled.contains { $0.phase == .failed })
            try expect(fixture.actions == ["brew-update", "ports-update", "mas-update"])
            fixture.failPorts = false
            let enabled = await fixture.service().prepare(retrying: disabled)
            try expect(enabled.allSatisfy { $0.phase == .ready } && enabled[1].dependencyFor == nil)
            try expect(fixture.actions == ["brew-update", "ports-update", "mas-update", "ports-update"])
        }
        await check("Complete empty and system-only inventories require no tool preparation") {
            for systemOnly in [false, true] {
                let fixture = try Fixture(); defer { fixture.clean() }
                let setup = SetupFixture(); setup.paths = [:]; setup.toolsMissing = true
                var inventory = AppInventory().discover(roots: [])
                if systemOnly { var app = try fixture.app(); app.state = .systemManaged; inventory.apps = [app] }
                let result = await setup.service().prepare(inventory: inventory)
                try expect(result.allSatisfy { $0.phase == .notRequired } && setup.runner.calls.isEmpty)
            }
        }
        await check("Complete non-store inventories do not install the App Store helper") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let setup = SetupFixture(); setup.paths.removeValue(forKey: "mas")
            let result = await setup.service().prepare(inventory: AppInventory().discover(roots: [fixture.root.path]))
            try expect(setup.actions == ["brew-update", "ports-update"] && result[3].phase == .notRequired)
        }
        await check("Store-only inventories prepare Homebrew only as the helper dependency") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var inventory = AppInventory().discover(roots: [fixture.root.path]); inventory.apps[0].hasStoreReceipt = true
            let setup = SetupFixture()
            let result = await setup.service().prepare(inventory: inventory)
            try expect(setup.actions == ["brew-update", "mas-update"])
            try expect(result[1].dependencyFor == .appStore && result[2].phase == .notRequired && result[3].phase == .ready)
        }
        await check("Store-only inventories preserve the MacPorts-owned helper route") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var inventory = AppInventory().discover(roots: [fixture.root.path]); inventory.apps[0].hasStoreReceipt = true
            let setup = SetupFixture(); setup.paths["mas"] = "/opt/local/bin/mas"
            let result = await setup.service().prepare(inventory: inventory)
            try expect(setup.actions == ["ports-update", "ports-mas-update"])
            try expect(result[1].phase == .notRequired && result[2].dependencyFor == .appStore)
        }
        await check("Incomplete inventory cannot prove any enabled source unnecessary") {
            let setup = SetupFixture()
            var inventory = AppInventory().discover(roots: []); inventory.warnings = ["A configured folder could not be read"]
            let result = await setup.service().prepare(inventory: inventory)
            try expect(result.allSatisfy { $0.phase == .ready })
            try expect(setup.actions == ["brew-update", "ports-update", "mas-update"])
        }
        await check("Source disable settings take precedence over inventory applicability") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var inventory = AppInventory().discover(roots: [fixture.root.path]); inventory.apps[0].hasStoreReceipt = true
            let setup = SetupFixture()
            let result = await setup.service().prepare(inventory: inventory, disabledSources: [.appStore])
            try expect(setup.runner.calls.isEmpty && result[3].phase == .disabled)
            try expect(result.prefix(3).allSatisfy { $0.phase == .notRequired })
        }
        await check("Retry recomputes inventory needs and clears obsolete dependency labels") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var inventory = AppInventory().discover(roots: [fixture.root.path]); inventory.apps[0].hasStoreReceipt = true
            let setup = SetupFixture()
            let first = await setup.service().prepare(inventory: inventory)
            inventory.apps[0].hasStoreReceipt = false
            let second = await setup.service().prepare(inventory: inventory, retrying: first)
            try expect(setup.actions == ["brew-update", "mas-update", "ports-update"])
            try expect(second[1].phase == .ready && second[1].dependencyFor == nil && second[2].phase == .ready && second[3].phase == .notRequired)
        }
        await check("Missing developer tools do not turn an unnecessary helper into a failed step") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let setup = SetupFixture(); setup.toolsMissing = true
            let result = await setup.service().prepare(inventory: AppInventory().discover(roots: [fixture.root.path]))
            try expect(result[0].phase == .failed && result[1].phase == .failed && result[2].phase == .failed && result[3].phase == .notRequired)
        }
        await check("Unknown, direct and Homebrew inventories do not install unrelated optional MacPorts") {
            for kind in ["unknown", "direct", "homebrew", "ports-owned"] {
                let fixture = try Fixture(); defer { fixture.clean() }
                var inventory = AppInventory().discover(roots: [fixture.root.path])
                if kind == "unknown" { inventory.warnings = ["Incomplete inventory"] }
                if kind == "homebrew" { inventory.apps[0].source = .homebrew }
                if kind == "ports-owned" { inventory.apps[0].source = .macPorts }
                let setup = SetupFixture(); setup.paths.removeValue(forKey: "port")
                let result = await setup.service().prepare(inventory: inventory)
                let installed = setup.actions.contains("ports-update")
                try expect(installed == (kind == "ports-owned"), "Unrelated MacPorts preparation for " + kind)
                try expect(result[2].phase == (kind == "ports-owned" ? .ready : .notRequired))
            }
        }
        await check("MacPorts opt-in requires an applicable enabled source and preserves explicit installation") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let inventory = AppInventory().discover(roots: [fixture.root.path])
            let setup = SetupFixture(); setup.paths.removeValue(forKey: "port")
            let prepared = await setup.service().prepare(inventory: inventory, includeMacPorts: true)
            try expect(prepared[2].phase == .ready && setup.actions.contains("ports-update"))
            for empty in [false, true] {
                let ignored = SetupFixture(); ignored.paths.removeValue(forKey: "port")
                let result = await ignored.service().prepare(inventory: empty ? AppInventory().discover(roots: []) : inventory, disabledSources: empty ? [] : [.macPorts], includeMacPorts: true)
                try expect(result[2].phase == (empty ? .notRequired : .disabled) && !ignored.actions.contains("ports-update"))
            }
        }
        await check("Missing optional MacPorts does not create false readiness or update coverage") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let setup = SetupFixture(); setup.paths.removeValue(forKey: "port")
            let readiness = await setup.service().checkReadiness(inventory: AppInventory().discover(roots: [fixture.root.path]))
            try expect(readiness[2].phase == .notRequired && !readiness[2].phase.needsAttention)
            let runner = FakeRunner { call in
                if call.args == ["--version"] { return CommandResult(output: "Homebrew 7.0.9") }
                return CommandResult(output: #"{"casks":[]}"#)
            }
            var prefs = Preferences(); prefs.scanRoots = [fixture.root.path]; prefs.includeSystemApplications = false
            let result = await ScanService(runner: runner, sourcePaths: [.homebrew: "/usr/bin/true"]).scan(preferences: prefs)
            let ports = result.sources.first { $0.source == .macPorts }!
            try expect(!ports.needsAttention && ports.checkRequired == false && !ports.available)
            try expect(result.checkedCount == 0 && result.apps[0].state == .unchecked)
        }
        await check("Explicit optional preparation installs missing managers from verified official packages and then mas") {
            let fixture = SetupFixture(); fixture.paths = [:]; fixture.ownedMas = false
            let result = await fixture.service().prepare(includeMacPorts: true)
            try expect(result.allSatisfy { $0.phase == .ready })
            try expect(fixture.actions == ["install-package", "brew-update", "install-package", "ports-update", "mas-install"])
            let installers = fixture.runner.calls.filter { $0.executable == "/bin/bash" && $0.args[1] == "install-package" }
            for installer in installers {
                try expect(!FileManager.default.fileExists(atPath: installer.args[2]), "Temporary installer was not removed")
                try expect(installer.args[3] == fixture.digest)
            }
        }
        await check("Startup failures preserve independent sources and explain blocked mas") {
            let fixture = SetupFixture(); fixture.failBrew = true
            let result = await fixture.service().prepare()
            try expect(result[1].phase == .failed && result[2].phase == .ready && result[3].phase == .failed)
            try expect(fixture.actions == ["brew-update", "ports-update"])
        }
        await check("Retrying failed Homebrew setup preserves successful MacPorts preparation") {
            let fixture = SetupFixture(); fixture.failBrew = true
            let first = await fixture.service().prepare()
            try expect(first[1].phase == .failed && first[2].phase == .ready && first[3].phase == .failed)
            fixture.failBrew = false
            let retried = await fixture.service().prepare(retrying: first)
            try expect(retried.allSatisfy { $0.phase == .ready })
            try expect(fixture.actions == ["brew-update", "ports-update", "brew-update", "mas-update"], "Retry repeated successful MacPorts maintenance")
        }
        await check("Retrying failed MacPorts setup preserves successful Homebrew and mas preparation") {
            let fixture = SetupFixture(); fixture.failPorts = true
            let first = await fixture.service().prepare()
            try expect(first[1].phase == .ready && first[2].phase == .failed && first[3].phase == .ready)
            fixture.failPorts = false
            let retried = await fixture.service().prepare(retrying: first)
            try expect(retried.allSatisfy { $0.phase == .ready })
            try expect(fixture.actions == ["brew-update", "ports-update", "mas-update", "ports-update"], "Retry repeated successful Homebrew or mas maintenance")
        }
        await check("A repeated setup failure leaves successful tools ready without repeating their work") {
            let fixture = SetupFixture(); fixture.failPorts = true
            let first = await fixture.service().prepare()
            var snapshots: [[SetupItem]] = []
            let retried = await fixture.service().prepare(retrying: first) { snapshots.append($0) }
            try expect(retried[2].phase == .failed && retried[1].phase == .ready && retried[3].phase == .ready)
            try expect(fixture.actions == ["brew-update", "ports-update", "mas-update", "ports-update"])
            try expect(snapshots.allSatisfy { $0[1].phase == .ready && $0[3].phase == .ready })
        }
        await check("Retrying an incompatible mas refreshes only the failed helper") {
            let fixture = SetupFixture(); fixture.masVersion = "6.0.0"
            let first = await fixture.service().prepare()
            fixture.masVersion = "7.0.0"
            let retried = await fixture.service().prepare(retrying: first)
            try expect(retried.allSatisfy { $0.phase == .ready })
            try expect(fixture.actions == ["brew-update", "ports-update", "mas-update", "mas-update"])
        }
        await check("A previously ready tool that disappeared is prepared again on retry") {
            let fixture = SetupFixture(); fixture.failBrew = true
            let first = await fixture.service().prepare()
            fixture.failBrew = false; fixture.paths.removeValue(forKey: "port")
            let retried = await fixture.service().prepare(retrying: first)
            try expect(retried.allSatisfy { $0.phase == .ready })
            try expect(fixture.actions == ["brew-update", "ports-update", "brew-update", "install-package", "ports-update", "mas-update"])
        }
        await check("A ready Homebrew at a different location is prepared again on retry") {
            let fixture = SetupFixture(); fixture.failPorts = true
            let first = await fixture.service().prepare()
            fixture.failPorts = false; fixture.paths["brew"] = "/usr/local/bin/brew"
            let retried = await fixture.service().prepare(retrying: first)
            try expect(retried.allSatisfy { $0.phase == .ready })
            try expect(fixture.actions == ["brew-update", "ports-update", "mas-update", "brew-update", "ports-update"], "A changed tool inherited preparation from its previous location")
        }
        await check("A previously ready mas downgraded below the supported version fails on retry") {
            let fixture = SetupFixture(); fixture.failPorts = true
            let first = await fixture.service().prepare()
            fixture.failPorts = false; fixture.masVersion = "6.0.0"
            let retried = await fixture.service().prepare(retrying: first)
            try expect(retried[3].phase == .failed && retried[3].message.contains("mas 7 or later"), "An incompatible helper retained its old ready result")
            try expect(fixture.actions == ["brew-update", "ports-update", "mas-update", "ports-update", "mas-update"])
        }
        await check("A previously ready manager that no longer runs fails on retry") {
            let fixture = SetupFixture(); fixture.failBrew = true
            let first = await fixture.service().prepare()
            fixture.failBrew = false; fixture.brokenTools = ["port"]
            let retried = await fixture.service().prepare(retrying: first)
            try expect(retried[2].phase == .failed && retried[2].message.contains("Tool cannot start"), "A broken executable retained its old ready result")
            try expect(retried[1].phase == .ready && retried[3].phase == .ready)
        }
        await check("A healthy ready helper is reprobed without maintenance and publishes its current version") {
            let fixture = SetupFixture(); fixture.failPorts = true
            let first = await fixture.service().prepare()
            try expect(first[1].executablePath == ToolLocator.canonicalPath(fixture.paths["brew"]!) && first[1].version == "7.0.9")
            let callCount = fixture.runner.calls.count
            fixture.failPorts = false; fixture.masVersion = "7.1.0"
            let retried = await fixture.service().prepare(retrying: first)
            try expect(retried[3].version == "7.1.0" && retried[3].message == "mas 7.1.0")
            let probes = fixture.runner.calls.dropFirst(callCount).filter { $0.executable == fixture.paths["brew"] && $0.args == ["--version"] || $0.executable == fixture.paths["mas"] && $0.args == ["version"] }
            try expect(probes.count == 2 && probes.allSatisfy { $0.timeout == 20 })
            try expect(fixture.actions == ["brew-update", "ports-update", "mas-update", "ports-update"])
        }
        await check("Changing a ready tool's symlink target invalidates its preparation") {
            let fixture = SetupFixture(); fixture.failPorts = true
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("setup-link-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let link = root.appendingPathComponent("brew")
            for name in ["first", "second"] { try Data().write(to: root.appendingPathComponent(name)) }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("first"))
            fixture.paths["brew"] = link.path
            let first = await fixture.service().prepare()
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("second"))
            fixture.failPorts = false
            let retried = await fixture.service().prepare(retrying: first)
            try expect(retried[1].executablePath == ToolLocator.canonicalPath(root.appendingPathComponent("second").path))
            try expect(fixture.actions == ["brew-update", "ports-update", "mas-update", "brew-update", "ports-update"])
        }
        await check("A canonical path alias preserves successful preparation") {
            let fixture = SetupFixture(); fixture.failPorts = true
            let first = await fixture.service().prepare()
            fixture.failPorts = false; fixture.paths["brew"] = "/System/Volumes/Data/opt/homebrew/bin/brew"
            let retried = await fixture.service().prepare(retrying: first)
            try expect(retried.allSatisfy { $0.phase == .ready })
            try expect(fixture.actions == ["brew-update", "ports-update", "mas-update", "ports-update"])
        }
        await check("Ready tools disabled before retry run no probes or maintenance") {
            let fixture = SetupFixture()
            let first = await fixture.service().prepare()
            let callCount = fixture.runner.calls.count
            let retried = await fixture.service().prepare(disabledSources: Set(UpdateSource.allCases), retrying: first)
            try expect(retried[0].phase == .notRequired && retried.dropFirst().allSatisfy { $0.phase == .disabled })
            try expect(fixture.runner.calls.count == callCount)
        }
        await check("An empty version response invalidates a ready helper") {
            let fixture = SetupFixture(); fixture.failPorts = true
            let first = await fixture.service().prepare()
            fixture.failPorts = false; fixture.masVersion = " \n"
            let retried = await fixture.service().prepare(retrying: first)
            try expect(retried[3].phase == .failed && retried[3].message.contains("did not report a version"))
            try expect(retried[3].version == nil && retried[3].executablePath == nil)
        }
        await check("Retry preserves a ready MacPorts-owned mas while fixing Homebrew") {
            let fixture = SetupFixture(); fixture.failBrew = true; fixture.paths["mas"] = "/opt/local/bin/mas"
            let first = await fixture.service().prepare()
            try expect(first[1].phase == .failed && first[3].phase == .ready)
            fixture.failBrew = false
            let retried = await fixture.service().prepare(retrying: first)
            try expect(retried.allSatisfy { $0.phase == .ready })
            try expect(fixture.actions == ["brew-update", "ports-update", "ports-mas-update", "brew-update"])
        }
        await check("Missing Apple tools launch Apple's installer and block dependent work") {
            let fixture = SetupFixture(); fixture.toolsMissing = true
            let result = await fixture.service().prepare()
            try expect(result.allSatisfy { $0.phase == .failed })
            try expect(fixture.runner.calls.contains { $0.executable == "/usr/bin/xcode-select" && $0.args == ["--install"] })
            try expect(fixture.actions.isEmpty && !fixture.runner.calls.contains { $0.executable == "/usr/bin/curl" })
        }
        await check("A mismatched package checksum blocks installation") {
            let fixture = SetupFixture(); fixture.paths.removeValue(forKey: "port"); fixture.badDigest = true
            let result = await fixture.service().prepare(includeMacPorts: true)
            try expect(result[2].phase == .failed && result[2].message.contains("checksum"))
            try expect(!fixture.actions.contains("install-package"))
        }
        await check("Gatekeeper rejection blocks package installation") {
            let fixture = SetupFixture(); fixture.paths.removeValue(forKey: "port"); fixture.rejectSignature = true
            let result = await fixture.service().prepare(includeMacPorts: true)
            try expect(result[2].phase == .failed && !fixture.actions.contains("install-package"))
        }
        await check("Canceled installation is not reported ready and other sources finish") {
            let fixture = SetupFixture(); fixture.paths.removeValue(forKey: "port"); fixture.cancelInstall = true
            let result = await fixture.service().prepare(includeMacPorts: true)
            try expect(result[2].phase == .failed && result[3].phase == .ready)
            try expect(!fixture.actions.contains("ports-update"))
        }
        await check("Repeated preparation refreshes sources on each launch without reinstalling") {
            let fixture = SetupFixture()
            _ = await fixture.service().prepare(); _ = await fixture.service().prepare()
            try expect(fixture.actions == ["brew-update", "ports-update", "mas-update", "brew-update", "ports-update", "mas-update"])
        }
        await check("MacPorts-owned mas stays with MacPorts") {
            let fixture = SetupFixture(); fixture.paths["mas"] = "/opt/local/bin/mas"
            let result = await fixture.service().prepare()
            try expect(result.allSatisfy { $0.phase == .ready })
            try expect(fixture.actions == ["brew-update", "ports-update", "ports-mas-update"])
        }
        await check("Incompatible mas is not marked ready") {
            let fixture = SetupFixture(); fixture.masVersion = "6.0.0"
            let result = await fixture.service().prepare()
            try expect(result[3].phase == .failed && result[3].message.contains("7 or later"))
        }
        await check("Intel missing Homebrew reports its installer limitation without blocking MacPorts") {
            let fixture = SetupFixture(); fixture.paths.removeValue(forKey: "brew")
            let result = await fixture.service(architecture: "x86_64").prepare()
            try expect(result[1].phase == .failed && result[2].phase == .ready)
            try expect(!fixture.actions.contains("install-package"))
        }
        await check("Official installer selection rejects wrong OS, foreign URLs, missing digests, and duplicate matches") {
            let digest = "sha256:" + String(repeating: "a", count: 64)
            func metadata(name: String, url: String, hash: String?, copies: Int = 1) throws -> Data {
                var asset = ["name": name, "browser_download_url": url]
                asset["digest"] = hash
                return try JSONSerialization.data(withJSONObject: ["assets": Array(repeating: asset, count: copies)])
            }
            let name = "MacPorts-2.12.7-27-GoldenGate.pkg"
            let url = "https://github.com/macports/macports-base/releases/download/v2.12.7/" + name
            let valid = try metadata(name: name, url: url, hash: digest)
            try expect(try DependencySetup.selectInstaller(valid, repository: "macports/macports-base", tool: "port", osMajor: 27).name == name)
            try expectThrows { _ = try DependencySetup.selectInstaller(valid, repository: "macports/macports-base", tool: "port", osMajor: 26) }
            for data in [try metadata(name: name, url: "https://example.com/" + name, hash: digest), try metadata(name: name, url: url, hash: nil), try metadata(name: name, url: url, hash: digest, copies: 2)] {
                try expectThrows { _ = try DependencySetup.selectInstaller(data, repository: "macports/macports-base", tool: "port", osMajor: 27) }
            }
        }
        await check("Bundled startup script has valid shell syntax and rejects untrusted operations") {
            let path = DependencySetup.scriptURL.path
            let runner = ProcessRunner()
            let syntax = try await runner.run("/bin/bash", ["-n", path], environment: [:], timeout: 5)
            try expect(syntax.status == 0)
            for arguments in [["unknown"], ["brew-update", "/tmp/untrusted-brew"], ["install-package", "/tmp/installer.pkg", "bad-hash"], ["ports-update", "extra"]] {
                let result = try await runner.run("/bin/bash", [path] + arguments, environment: [:], timeout: 5)
                try expect(result.status != 0)
            }
        }
        print("\n\(passed) passed; \(failures.count) failed.")
        if !failures.isEmpty { exit(1) }
    }
}
