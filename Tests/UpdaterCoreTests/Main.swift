import Foundation
import Darwin
import CryptoKit
@_spi(Testing) import UpdaterCore

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
private actor InstallBarrier {
    var entered = false
    var released = false
    func enter() { entered = true }
    func release() { released = true }
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
    func brewJSON(target: String = "2.0", sha256: String? = String(repeating: "a", count: 64)) throws -> String {
        var cask: [String: Any] = ["token": "example", "version": target, "installed": "1.0", "artifacts": [["app": ["Example.app"], "target": appURL.path]], "auto_updates": true]
        cask["sha256"] = sha256
        let json: [String: Any] = ["casks": [cask]]
        return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }
    func sign(identifier: String? = nil) throws {
        let fm = FileManager.default
        let contents = appURL.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Example")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: executable.path) { try fm.copyItem(atPath: "/usr/bin/true", toPath: executable.path) }
        let infoURL = contents.appendingPathComponent("Info.plist")
        var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
        info["CFBundleExecutable"] = "Example"; info["CFBundlePackageType"] = "APPL"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        let resource = contents.appendingPathComponent("Resources/Sealed.txt")
        try fm.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: resource.path) { try Data("reviewed resource".utf8).write(to: resource) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--identifier", identifier ?? (info["CFBundleIdentifier"] as! String), appURL.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        try expect(process.terminationStatus == 0, "Could not sign disposable fixture")
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

private func catalogFixture(_ app: AppRecord, now: Date, revision: UInt64 = 2) -> SourceMappingCatalog {
    let mapping = SourceMapping(id: "example", source: .homebrew, packageID: "example", bundleID: app.bundleID,
        signingTeamIdentifier: "TEAMID1234", channel: "stable", officialHosts: ["updates.example.com"],
        metadataURL: URL(string: "https://updates.example.com/feed.xml"), reviewedAt: now.addingTimeInterval(-60), capability: .managerUpdate)
    return SourceMappingCatalog(revision: revision, issuedAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(3600), mappings: [mapping])
}
private func signedCatalog(_ catalog: SourceMappingCatalog, key: Curve25519.Signing.PrivateKey, keyID: String = "test", mutate: ((inout [String: Any]) -> Void)? = nil) throws -> Data {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
    var payload = try encoder.encode(catalog)
    if let mutate {
        var object = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        mutate(&object); payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    var message = SourceMappingCatalogStore.signatureDomain; message.append(payload)
    return try JSONSerialization.data(withJSONObject: ["keyID": keyID, "payload": payload.base64EncodedString(), "signature": try key.signature(for: message).base64EncodedString()])
}

private func authenticatedCatalog(_ catalog: SourceMappingCatalog, root: URL, now: Date) throws -> AuthenticatedSourceMappingCatalog {
    let key = Curve25519.Signing.PrivateKey()
    let store = SourceMappingCatalogStore(root: root.appendingPathComponent("Authenticated-" + UUID().uuidString), trustedKeys: ["test": key.publicKey.rawRepresentation])
    return try store.accept(signedCatalog(catalog, key: key), now: now)
}

@main
private enum Checks {
    static func main() async {
        if CommandLine.arguments.contains("--inspect-output-transport") {
            for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
                var info = stat()
                guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else { exit(2) }
                print("pipe")
            }
            return
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--hold-update-lock" {
            do {
                let app = try AppInventory().read(CommandLine.arguments[2])
                let cask: [String: Any] = ["token": "example", "version": "2.0", "sha256": String(repeating: "a", count: 64), "installed": "1.0", "artifacts": [["app": ["Example.app"], "target": app.path]]]
                let metadata = String(decoding: try JSONSerialization.data(withJSONObject: ["casks": [cask]]), as: UTF8.self)
                let runner = FakeRunner { call in
                    if call.args.first == "info" { return CommandResult(output: metadata) }
                    if call.args.first == "outdated" { return CommandResult(output: #"{"casks":[{"name":"example"}]}"#) }
                    if call.args.first == "upgrade" {
                        try Data("owned".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
                        // The parent deliberately terminates this process to prove
                        // kernel ownership is released after abnormal interruption.
                        while true { Thread.sleep(forTimeInterval: 0.1) }
                    }
                    throw UpdaterError("Unexpected child command")
                }
                let candidate = HomebrewAdapter.apply(casks: try HomebrewAdapter.parseCasks(metadata), outdated: ["example"], to: [app], executable: "/usr/bin/true")[0]
                let cache = URL(fileURLWithPath: app.path).deletingLastPathComponent().appendingPathComponent("ChildCache")
                _ = await UpdateEngine(runner: runner, cacheRoot: cache, sourcePaths: [.homebrew: "/usr/bin/true"])
                    .execute(PlannedUpdate(app: candidate, preview: ""), cleanup: false) { _, _ in }
            } catch { }
            exit(3)
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--stream-process-output" {
            do {
                let root = URL(fileURLWithPath: CommandLine.arguments[2])
                try FileHandle.standardError.write(contentsOf: Data("Useful fixture context: Bearer SYNTHETIC_BEARER\n".utf8))
                let chunk = Data(repeating: 65, count: 64 * 1024)
                for phase in 0..<2 {
                    for _ in 0..<320 {
                        try FileHandle.standardOutput.write(contentsOf: chunk)
                        try FileHandle.standardError.write(contentsOf: chunk)
                    }
                    if phase == 0 {
                        try Data().write(to: root.appendingPathComponent("ready"))
                        for _ in 0..<500 {
                            if FileManager.default.fileExists(atPath: root.appendingPathComponent("continue").path) { break }
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                    }
                }
                try Data().write(to: root.appendingPathComponent("finished"))
                return
            } catch { exit(2) }
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--delayed-process-output" {
            for _ in 0..<500 {
                if FileManager.default.fileExists(atPath: CommandLine.arguments[2] + ".continue") { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            do {
                try FileHandle.standardOutput.write(contentsOf: Data("late".utf8))
                try Data().write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            } catch { exit(2) }
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--inherited-process-output" {
            do {
                let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                child.arguments = ["--delayed-process-output", CommandLine.arguments[2]]
                child.standardOutput = FileHandle.standardOutput; child.standardError = FileHandle.standardError
                try child.run()
                try FileHandle.standardOutput.write(contentsOf: Data("done".utf8))
                return
            } catch { exit(2) }
        }
        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ action: () async throws -> Void) async {
            do { try await action(); passed += 1; print("PASS \(name)") }
            catch { failures.append("\(name): \(error)"); print("FAIL \(name): \(error)") }
        }
        await check("Sparkle selects builds independently of marketing versions and feed order") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let app = try fixture.app()
            let checker = SparkleCheck(macOS: "27.0", architecture: "arm64")
            let result = try checker.evaluate(appcast(feedItem("12", version: "1.2") + feedItem() + feedItem("15", version: "1.5")), app: app)
            try expect(result.state == .updateAvailable && result.build == "20" && result.version == "2.0")
            try expect(result.message.contains("default channel") && result.message.contains("runtime"))
            let current = try checker.evaluate(appcast(feedItem("10", version: "1.0")), app: app)
            try expect(current.state == .current)
        }
        await check("Sparkle honors channels, OS, hardware and minimum installed builds") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var app = try fixture.app()
            let checker = SparkleCheck(macOS: "27.0", architecture: "x86_64")
            let base = feedItem()
            let variants = [
                "<sparkle:channel>beta</sparkle:channel>",
                "<sparkle:minimumSystemVersion>28.0</sparkle:minimumSystemVersion>",
                "<sparkle:maximumSystemVersion>26.0</sparkle:maximumSystemVersion>",
                "<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>",
                "<sparkle:minimumUpdateVersion>11</sparkle:minimumUpdateVersion>"
            ]
            for rule in variants {
                let result = try checker.evaluate(appcast(base + feedItem("30", version: "3.0", rules: rule)), app: app)
                try expect(result.build == "20", "Incompatible release selected: " + rule)
            }
            app.sourceEvidence = SourceEvidence(level: .reviewedMapping, capability: .checkOnly, bundleID: app.bundleID, signingTeamIdentifier: nil, channel: "beta", officialHosts: [], reviewedAt: Date())
            let beta = try checker.evaluate(appcast(base + feedItem("30", version: "3.0", rules: variants[0])), app: app)
            try expect(beta.build == "30")
            let none = try checker.evaluate(appcast(feedItem(rules: variants[1])), app: app)
            try expect(none.state == .unsupported)
        }
        await check("Sparkle handles legacy version attributes and namespace aliases without fetching enclosures") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let checker = SparkleCheck(macOS: "27.0", architecture: "arm64")
            let legacy = "<item><enclosure sparkle:version=\"20\" sparkle:shortVersionString=\"2.0\" sparkle:os=\"macos\" url=\"file:///never-open-this\"/></item>"
            let result = try checker.evaluate(appcast(legacy), app: fixture.app())
            try expect(result.build == "20")
            let windows = legacy.replacingOccurrences(of: "macos", with: "windows")
            try expect(checker.evaluate(appcast(windows), app: fixture.app()).state == .unsupported)
            let alias = String(decoding: appcast(legacy), as: UTF8.self).replacingOccurrences(of: "sparkle:", with: "s:").replacingOccurrences(of: "xmlns:sparkle", with: "xmlns:s")
            try expect(checker.evaluate(Data(alias.utf8), app: fixture.app()).build == "20")
        }
        await check("Sparkle rejects malicious XML, excessive work and ambiguous release rules") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let checker = SparkleCheck(macOS: "27.0", architecture: "arm64")
            let bad = [
                Data("<!DOCTYPE rss [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><rss/>".utf8),
                Data("<rss><channel><item>".utf8),
                Data(repeating: 65, count: SparkleFeedLoader.maximumBytes + 1),
                appcast(String(repeating: feedItem(), count: 257)),
                appcast(feedItem(rules: String(repeating: "<x>", count: 17) + String(repeating: "</x>", count: 17))),
                appcast(feedItem(rules: "<sparkle:hardwareRequirements>futureCPU</sparkle:hardwareRequirements>")),
                appcast(feedItem(rules: "<sparkle:unknownRequirement>yes</sparkle:unknownRequirement>")),
                appcast(feedItem("abc")),
                appcast(feedItem(rules: "<sparkle:version>30</sparkle:version>")),
                appcast(feedItem(rules: "<sparkle:minimumSystemVersion>27.<x/>0</sparkle:minimumSystemVersion>")),
                appcast("<item><enclosure sparkle:version=\"20\" sparkle:arch=\"x86_64\" url=\"https://example.com/a\"/></item>"),
                appcast(feedItem(rules: "<description>" + String(repeating: "a", count: 16385) + "</description>"))
            ]
            for bytes in bad { try expectThrows { _ = try checker.evaluate(bytes, app: fixture.app()) } }
        }
        await check("Sparkle transport rejects untrusted URL forms before requesting and bounds HTTP data") {
            for text in ["http://example.com/feed", "file:///tmp/feed", "https://user:pass@example.com/feed", "https://example.com:8443/feed", "https://127.0.0.1/feed", "https://[::1]/feed", "https://localhost/feed", "https://host.local/feed", "https://example.com/feed#secret"] {
                try expectThrows { try SparkleFeedLoader.validateURL(URL(string: text)!) }
            }
            let loader = SparkleFeedLoader(protocolClasses: [FixtureFeedProtocol.self])
            let url = URL(string: "https://updates.example.com/appcast.xml")!
            FixtureFeedProtocol.responseStatus = 200
            FixtureFeedProtocol.responseHeaders = ["Content-Type": "application/rss+xml"]
            FixtureFeedProtocol.responseData = appcast(feedItem())
            let loaded = try await loader.load(url)
            try expect(loaded == FixtureFeedProtocol.responseData)
            for (status, headers, data) in [
                (302, ["Content-Type": "application/rss+xml", "Location": "https://other.example.com/feed"], Data()),
                (404, ["Content-Type": "application/rss+xml"], Data()),
                (200, ["Content-Type": "text/html"], Data()),
                (200, ["Content-Type": "application/rss+xml", "Content-Length": "1048577"], Data()),
                (200, ["Content-Type": "application/rss+xml"], Data(repeating: 65, count: SparkleFeedLoader.maximumBytes + 1))
            ] {
                FixtureFeedProtocol.responseStatus = status; FixtureFeedProtocol.responseHeaders = headers; FixtureFeedProtocol.responseData = data
                do { _ = try await loader.load(url); throw CheckFailure(description: "Unsafe feed response accepted") }
                catch let error as CheckFailure { throw error }
                catch { }
            }
        }
        await check("Sparkle signed-feed and custom-version requirements do not make network requests") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var app = try fixture.app(); app.sparkleFeed = "https://updates.example.com/feed.xml"
            let loader = FixtureFeedLoader(String(decoding: appcast(feedItem()), as: UTF8.self))
            let checker = SparkleCheck(loader: loader)
            app.sparkleRequiresSignedFeed = true
            let signed = await checker.check(app)
            try expect(signed.state == .unsupported && loader.requested.isEmpty)
            app.sparkleRequiresSignedFeed = nil; app.version = "2.0-beta"
            let custom = await checker.check(app)
            try expect(custom.state == .unsupported && loader.requested.isEmpty)
        }
        await check("Sparkle scans surface read-only updates without granting manager ownership or installation") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let infoURL = fixture.appURL.appendingPathComponent("Contents/Info.plist")
            var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
            info["SUFeedURL"] = "https://updates.example.com/feed.xml"
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
            let loader = FixtureFeedLoader(String(decoding: appcast(feedItem()), as: UTF8.self))
            let runner = FakeRunner { _ in throw UpdaterError("No manager command expected") }
            var service = ScanService(runner: runner, sourcePaths: [:])
            service.sparkleChecker = SparkleCheck(loader: loader, macOS: "27.0", architecture: "arm64")
            var prefs = Preferences(); prefs.scanRoots = [fixture.appURL.path]; prefs.includeSystemApplications = false
            _ = await service.scan(preferences: prefs)
            try expect(loader.requested.isEmpty, "Sparkle must require explicit opt-in")
            prefs.checkEmbeddedSparkleFeeds = true
            let result = await service.scan(preferences: prefs)
            try expect(result.apps.count == 1 && loader.requested.count == 1)
            let app = result.apps[0]
            try expect(app.state == .manual && app.targetBuild == "20" && app.source == nil && app.automatic == false)
            try expect(!prefs.isEligible(app) && result.checkedCount == 1 && runner.calls.isEmpty)
            try expect(app.sparkleObservation?.state == .updateAvailable)
            let copy = try JSONDecoder().decode(ScanResult.self, from: JSONEncoder().encode(result))
            try expect(copy.apps[0].sparkleObservation == app.sparkleObservation)
            let receipt = fixture.appURL.appendingPathComponent("Contents/_MASReceipt")
            try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
            try Data().write(to: receipt.appendingPathComponent("receipt"))
            _ = await service.scan(preferences: prefs)
            try expect(loader.requested.count == 1, "Store-owned app contacted the feed")
        }
        await check("Sparkle scan budgets leave omitted feeds unchecked and managers retain priority") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let infoURL = fixture.appURL.appendingPathComponent("Contents/Info.plist")
            var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
            info["SUFeedURL"] = "https://updates.example.com/feed.xml"
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
            for index in 1...16 {
                try FileManager.default.copyItem(at: fixture.appURL, to: fixture.root.appendingPathComponent("Copy\(index).app"))
            }
            let loader = FixtureFeedLoader(String(decoding: appcast(feedItem()), as: UTF8.self))
            var service = ScanService(runner: FakeRunner { _ in throw UpdaterError("No commands expected") }, sourcePaths: [:])
            service.sparkleChecker = SparkleCheck(loader: loader)
            var prefs = Preferences(); prefs.scanRoots = [fixture.root.path]; prefs.includeSystemApplications = false; prefs.checkEmbeddedSparkleFeeds = true
            let result = await service.scan(preferences: prefs)
            try expect(loader.requested.count == 16 && result.apps.count == 17)
            try expect(result.apps.filter { $0.state == .unchecked }.count == 1 && result.checkedCount == 16)
            let managedLoader = FixtureFeedLoader(String(decoding: appcast(feedItem()), as: UTF8.self))
            var managed = ScanService(runner: try fixture.runner(), sourcePaths: [.homebrew: "/usr/bin/true"])
            managed.sparkleChecker = SparkleCheck(loader: managedLoader)
            prefs.scanRoots = [fixture.appURL.path]
            let managedResult = await managed.scan(preferences: prefs)
            try expect(managedLoader.requested.isEmpty && managedResult.apps[0].source == .homebrew)
        }
        await check("Discovery refresh caches authenticated dated catalogs, limits requests and preserves valid offline results") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let now = Date(); let key = Curve25519.Signing.PrivateKey()
            var catalog = catalogFixture(try fixture.app(), now: now); catalog.expiresAt = now.addingTimeInterval(7200)
            let loader = FixtureCatalogLoader(bytes: try signedCatalog(catalog, key: key))
            let configuration = DiscoveryCatalogConfiguration(endpoint: URL(string: "https://catalog.example.com/catalog.json")!, keyID: "test", publicKey: key.publicKey.rawRepresentation.base64EncodedString())
            let service = SourceDiscoveryService(root: fixture.root.appendingPathComponent("Discovery"), configuration: configuration, loader: loader)
            try expect(service.load(now: now).catalog == nil && loader.calls == 0)
            let first = await service.refresh(now: now)
            try expect(first.catalog?.revision == 2 && first.status.state == .ready && first.status.lastSuccess != nil)
            _ = await service.refresh(now: now.addingTimeInterval(10))
            try expect(loader.calls == 1)
            loader.failure = UpdaterError("Offline Bearer PRIVATE_FIXTURE_TOKEN")
            let offline = await service.refresh(now: now.addingTimeInterval(3601))
            try expect(offline.catalog?.revision == 2 && offline.status.state == .cached && offline.status.error != nil)
            try expect(!(offline.status.error ?? "").contains("PRIVATE_FIXTURE_TOKEN"))
            try expect(service.load(now: now.addingTimeInterval(3602)).status.error != nil, "A scan erased the last refresh failure")
            _ = await service.refresh(now: now.addingTimeInterval(3610))
            try expect(loader.calls == 2, "Failure retry ignored its one-minute limit")
            loader.failure = nil; loader.bytes = Data("untrusted response".utf8)
            let invalid = await service.refresh(now: now.addingTimeInterval(3662))
            try expect(invalid.catalog?.revision == 2 && invalid.status.error != nil)
            try expect(service.load(now: now.addingTimeInterval(7201)).catalog == nil, "Expired candidates were reused")
            var next = catalogFixture(try fixture.app(), now: now.addingTimeInterval(7300), revision: 3)
            next.expiresAt = now.addingTimeInterval(20000)
            loader.bytes = try signedCatalog(next, key: key)
            let refreshed = await service.refresh(now: now.addingTimeInterval(7300))
            try expect(refreshed.catalog?.revision == 3)
            loader.bytes = try signedCatalog(catalogFixture(try fixture.app(), now: now.addingTimeInterval(11000), revision: 1), key: key)
            let rollback = await service.refresh(now: now.addingTimeInterval(11000))
            try expect(rollback.catalog?.revision == 3 && rollback.status.error?.contains("rollback") == true)
        }
        await check("Discovery refresh serializes across instances and never accepts data after cancellation or expiry") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let now = Date(); let key = Curve25519.Signing.PrivateKey(); let bytes = try signedCatalog(catalogFixture(try fixture.app(), now: now), key: key)
            let configuration = DiscoveryCatalogConfiguration(endpoint: URL(string: "https://catalog.example.com/catalog.json")!, keyID: "test", publicKey: key.publicKey.rawRepresentation.base64EncodedString())
            let loader = GatedCatalogLoader(bytes: bytes)
            let service = SourceDiscoveryService(root: fixture.root.appendingPathComponent("Gated"), configuration: configuration, loader: loader)
            let pending = Task { await service.refresh(now: now) }
            while !(await loader.entered) { try await Task.sleep(nanoseconds: 1_000_000) }
            let simultaneous = await service.refresh(now: now)
            await loader.release()
            let completed = await pending.value
            let calls = await loader.calls
            try expect(calls == 1 && simultaneous.catalog == nil && completed.catalog?.revision == 2)
            let canceledLoader = FixtureCatalogLoader(bytes: bytes)
            let canceledService = SourceDiscoveryService(root: fixture.root.appendingPathComponent("Canceled"), configuration: configuration, loader: canceledLoader)
            let canceled = Task { await canceledService.refresh(now: now) }; canceled.cancel()
            let result = await canceled.value
            try expect(result.catalog == nil && canceledService.load(now: now).catalog == nil)
            let expiryNow = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
            var expiring = catalogFixture(try fixture.app(), now: expiryNow); expiring.expiresAt = expiryNow.addingTimeInterval(1)
            let delayed = FixtureCatalogLoader(bytes: try signedCatalog(expiring, key: key)); delayed.delay = 1_100_000_000
            let expired = await SourceDiscoveryService(root: fixture.root.appendingPathComponent("Expired"), configuration: configuration, loader: delayed).refresh(now: expiryNow)
            try expect(expired.catalog == nil, "Catalog expiry was checked only before the request")
        }
        await check("Discovery matches exact installed identities and keeps channels and local copies independent") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let now = Date(); let app = try fixture.app()
            let catalog = try authenticatedCatalog(catalogFixture(app, now: now), root: fixture.root, now: now)
            let review = DiscoveryChannelReview(path: app.path, bundleID: app.bundleID, teamIdentifier: "TEAMID1234", channel: "stable")
            let matched = SourceDiscoveryService.candidates(for: app, catalog: catalog, review: review, now: now, macOS: "27.0", architecture: .arm64, teamIdentifier: "TEAMID1234")
            try expect(matched.count == 1 && matched[0].assessment == .matched)
            var copy = app; copy.path = fixture.root.appendingPathComponent("Copy.app").path
            let copyResult = SourceDiscoveryService.candidates(for: copy, catalog: catalog, review: review, now: now, teamIdentifier: "TEAMID1234")
            try expect(copyResult[0].assessment == .provisional)
            var wrongNameMatch = app; wrongNameMatch.bundleID = "unrelated.bundle"
            try expect(SourceDiscoveryService.candidates(for: wrongNameMatch, catalog: catalog, review: review, now: now).isEmpty)
            let unknown = SourceDiscoveryService.candidates(for: app, catalog: catalog, review: nil, now: now, teamIdentifier: "TEAMID1234")
            try expect(unknown[0].assessment == .provisional)
            let wrongPublisher = SourceDiscoveryService.candidates(for: app, catalog: catalog, review: review, now: now, teamIdentifier: "OTHER12345")
            try expect(wrongPublisher[0].assessment == .conflict)
            let beta = DiscoveryChannelReview(path: app.path, bundleID: app.bundleID, teamIdentifier: "TEAMID1234", channel: "beta")
            try expect(SourceDiscoveryService.candidates(for: app, catalog: catalog, review: beta, now: now, teamIdentifier: "TEAMID1234")[0].assessment == .conflict)
            var receipt = app; receipt.hasStoreReceipt = true
            try expect(SourceDiscoveryService.candidates(for: receipt, catalog: catalog, review: review, now: now).isEmpty)
            try expect(SourceDiscoveryService.candidates(for: app, catalog: catalog, review: review, now: now.addingTimeInterval(7200)).isEmpty)
        }
        await check("Catalog suggestions appear beyond installed ownership without granting coverage or an executable route") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let now = Date(); let catalog = try authenticatedCatalog(catalogFixture(try fixture.app(), now: now), root: fixture.root, now: now)
            let runner = FakeRunner { _ in throw UpdaterError("Unexpected command") }
            var service = ScanService(runner: runner, sourcePaths: [:]); service.discoveryCatalog = catalog
            var prefs = Preferences(); prefs.scanRoots = [fixture.appURL.path]; prefs.includeSystemApplications = false
            let result = await service.scan(preferences: prefs)
            let app = result.apps[0]
            try expect(app.catalogCandidates?.count == 1 && app.source == nil && app.routes?.isEmpty != false)
            try expect(app.state == .unchecked && result.checkedCount == 0 && !prefs.isEligible(app) && runner.calls.isEmpty)
            let restored = try JSONDecoder().decode(ScanResult.self, from: JSONEncoder().encode(result))
            try expect(restored.apps[0].catalogCandidates?.first?.id == "example")
            do { _ = try await UpdateEngine(runner: runner, sourcePaths: [:]).prepare([app], preferences: prefs); throw CheckFailure(description: "Candidate became an executable plan") }
            catch is UpdaterError { }
            try expect(runner.calls.isEmpty)
        }
        await check("Shared metadata transport retains separate JSON/XML type and decoded-size bounds") {
            let transport = BoundedMetadataLoader(protocolClasses: [FixtureFeedProtocol.self])
            let url = URL(string: "https://catalog.example.com/catalog.json")!
            FixtureFeedProtocol.responseStatus = 200
            FixtureFeedProtocol.responseHeaders = ["Content-Type": "application/json"]
            FixtureFeedProtocol.responseData = Data("{}".utf8)
            let json = try await transport.load(url, maximumBytes: 2 * 1024 * 1024, mimeTypes: ["application/json"])
            try expect(json == Data("{}".utf8))
            for bytes in [Data(repeating: 65, count: 2 * 1024 * 1024 + 1)] {
                FixtureFeedProtocol.responseData = bytes
                do { _ = try await transport.load(url, maximumBytes: 2 * 1024 * 1024, mimeTypes: ["application/json"]); throw CheckFailure(description: "Oversized JSON accepted") }
                catch let error as CheckFailure { throw error }
                catch { }
            }
            FixtureFeedProtocol.responseData = Data("{}".utf8)
            FixtureFeedProtocol.responseHeaders = ["Content-Type": "application/rss+xml"]
            do { _ = try await transport.load(url, maximumBytes: 2 * 1024 * 1024, mimeTypes: ["application/json"]); throw CheckFailure(description: "Wrong metadata type accepted") }
            catch let error as CheckFailure { throw error }
            catch { }
        }
        await check("Discovery publisher configuration rejects unsafe URLs, invalid keys and revision floors") {
            let key = Curve25519.Signing.PrivateKey()
            let good = DiscoveryCatalogConfiguration(endpoint: URL(string: "https://catalog.example.com/catalog.json")!, keyID: "test", publicKey: key.publicKey.rawRepresentation.base64EncodedString())
            try good.validate(); try expect(good.fingerprint.count == 64)
            for field in ["url", "key", "id", "revision"] {
                var changed = good
                switch field {
                case "url": changed.endpoint = URL(string: "http://catalog.example.com/catalog.json")!
                case "key": changed.publicKey = "invalid"
                case "id": changed.keyID = "untrusted key id"
                default: changed.minimumRevision = 0
                }
                try expectThrows { try changed.validate() }
            }
        }
        await check("Chrome release selection excludes unserved, ended and future releases and rejects incomplete identities") {
            let active = vendorRelease("2.0.0.0")
            let rows = [vendorRelease("9.0.0.0", fraction: 0), active, vendorRelease("8.0.0.0", end: "2025-01-01T00:00:00Z"), vendorRelease("7.0.0.0", start: "2099-01-01T00:00:00Z")]
            try expect(OfficialVendorService.latestRelease(vendorJSON(rows), platform: "mac_arm64", channel: "stable") == "2.0.0.0")
            for bytes in [try vendorJSON([vendorRelease("2.0.0.0", channel: "beta")]), try vendorJSON([vendorRelease("bad")]), try vendorJSON([vendorRelease("2.0.0.0", fraction: 2)]), try vendorJSON([active], token: "more"), try vendorJSON(Array(repeating: active, count: 257)), Data(repeating: 65, count: 512 * 1024 + 1)] {
                try expectThrows { _ = try OfficialVendorService.latestRelease(bytes, platform: "mac_arm64", channel: "stable") }
            }
        }
        await check("Bounded Mach-O inspection identifies thin and universal architectures without launching an executable") {
            func word(_ value: UInt32) -> [UInt8] { [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
            let thin = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1])
            try expect(ExecutableArchitecture.parse(thin) == [.arm64])
            var universal = word(0xcafebabe) + word(2)
            universal += word(0x0100000c) + Array(repeating: 0, count: 16)
            universal += word(0x01000007) + Array(repeating: 0, count: 16)
            try expect(ExecutableArchitecture.parse(Data(universal)) == [.arm64, .x86_64])
            for bad in [Data(), Data(universal.prefix(12)), Data(word(0xcafebabe) + word(100)), Data("not Mach-O".utf8)] {
                try expectThrows { _ = try ExecutableArchitecture.parse(bad) }
            }
        }
        await check("Official vendor checks require pinned publisher, explicit per-copy channel and supported architecture") {
            let fixture = try Fixture(); defer { fixture.clean() }
            func write(_ version: String) throws {
                try fixture.write(version: version, build: version)
                let url = fixture.appURL.appendingPathComponent("Contents/Info.plist")
                var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
                info["CFBundleIdentifier"] = "com.google.Chrome"
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url)
            }
            try write("1.0.0.0")
            let app = try fixture.app()
            let loader = FixtureVendorLoader(bytes: try vendorJSON([vendorRelease("2.0.0.0")]))
            let service = OfficialVendorService(loader: loader, validateIdentity: { _ in }, architectures: { _ in [.arm64] })
            let unknown = await service.check(app, review: nil)
            try expect(unknown.state == .unsupported && loader.urls.isEmpty)
            let review = DiscoveryChannelReview(path: app.path, bundleID: app.bundleID, teamIdentifier: "EQHXZ8M8AV", channel: "stable")
            let valid = await service.check(app, review: review)
            try expect(valid.state == .updateAvailable && valid.targetVersion == "2.0.0.0" && valid.platform == "mac_arm64")
            try expect(loader.urls[0].host == "versionhistory.googleapis.com" && loader.urls[0].absoluteString.contains("fraction%3E0"))
            let denied = await OfficialVendorService(loader: loader).check(app, review: review)
            try expect(denied.state == .unsupported && loader.urls.count == 1, "Unsigned fixture reached the official vendor endpoint")
            let wrongArchitecture = OfficialVendorService(loader: loader, nativeArchitecture: .x86_64, validateIdentity: { _ in }, architectures: { _ in [.arm64] })
            let incompatible = await wrongArchitecture.check(app, review: review)
            try expect(incompatible.state == .unsupported && loader.urls.count == 1)
            var copyReview = review; copyReview.path = fixture.root.appendingPathComponent("Other.app").path
            let wrongCopy = await service.check(app, review: copyReview)
            try expect(wrongCopy.state == .unsupported && loader.urls.count == 1)
            try write("2.0.0.0")
            let current = await service.check(try fixture.app(), review: review)
            try expect(current.state == .current)
        }
        await check("Vendor handoffs recheck targets, verify independently and reject changed paths, receipts, channels or architecture") {
            let fixture = try Fixture(); defer { fixture.clean() }
            func write(_ version: String, bundle: String = "com.google.Chrome") throws {
                try fixture.write(version: version, build: version)
                let url = fixture.appURL.appendingPathComponent("Contents/Info.plist")
                var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
                info["CFBundleIdentifier"] = bundle
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url)
            }
            try write("1.0.0.0")
            var app = try fixture.app()
            let loader = FixtureVendorLoader(bytes: try vendorJSON([vendorRelease("2.0.0.0")]))
            var architecture: Set<CatalogArchitecture> = [.arm64]
            var running = false
            let service = OfficialVendorService(loader: loader, validateIdentity: { _ in }, architectures: { _ in architecture }, isRunning: { _ in running })
            let review = DiscoveryChannelReview(path: app.path, bundleID: app.bundleID, teamIdentifier: "EQHXZ8M8AV", channel: "stable")
            app.vendorObservation = await service.check(app, review: review)
            let plan = try await service.prepareHandoff(app, review: review)
            let unchanged = await service.verify(plan, review: review); try expect(!unchanged.0)
            loader.bytes = try vendorJSON([vendorRelease("3.0.0.0")])
            do { _ = try await service.prepareHandoff(app, review: review); throw CheckFailure(description: "Changed vendor target passed review") }
            catch is UpdaterError { }
            try write("2.0.0.0")
            running = true; let active = await service.verify(plan, review: review); try expect(!active.0)
            running = false
            let verified = await service.verify(plan, review: review); try expect(verified.0)
            let barrier = InstallBarrier()
            let intercepted = FakeRunner { _ in throw UpdaterError("No command should run") }
            let owned = Task {
                await UpdateEngine(runner: intercepted, sourcePaths: [:]).execute(PlannedUpdate(app: app, preview: ""), cleanup: false) { stage, _ in
                    if stage == .preflight {
                        await barrier.enter()
                        while !(await barrier.released) { try await Task.sleep(nanoseconds: 1_000_000) }
                    }
                }
            }
            while !(await barrier.entered) { try await Task.sleep(nanoseconds: 1_000_000) }
            let conflict = await service.verify(plan, review: review)
            await barrier.release(); _ = await owned.value
            try expect(!conflict.0 && intercepted.calls.isEmpty, "Vendor verification bypassed application ownership")
            architecture = [.x86_64]; let wrongArch = await service.verify(plan, review: review); try expect(!wrongArch.0)
            architecture = [.arm64]
            var changedReview = review; changedReview.channel = "beta"
            let changedChannel = await service.verify(plan, review: changedReview); try expect(!changedChannel.0)
            try write("2.0.0.0", bundle: "other.bundle")
            let changedIdentity = await service.verify(plan, review: review); try expect(!changedIdentity.0)
            try write("2.0.0.0")
            let receipt = fixture.appURL.appendingPathComponent("Contents/_MASReceipt")
            try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
            try Data().write(to: receipt.appendingPathComponent("receipt"))
            let changedReceipt = await service.verify(plan, review: review); try expect(!changedReceipt.0)
            try FileManager.default.removeItem(at: receipt)
            let moved = fixture.root.appendingPathComponent("Moved.app")
            try FileManager.default.moveItem(at: fixture.appURL, to: moved)
            try FileManager.default.createSymbolicLink(at: fixture.appURL, withDestinationURL: moved)
            let changedPath = await service.verify(plan, review: review); try expect(!changedPath.0)
        }
        await check("Vendor identity requirement rejects unsigned and ad-hoc bundles without treating the requirement as malformed") {
            let fixture = try Fixture(); defer { fixture.clean() }
            for signed in [false, true] {
                if signed { try fixture.sign() }
                do {
                    try DeveloperIDValidation.validate(path: fixture.appURL.path, bundleID: "com.google.Chrome", team: "EQHXZ8M8AV")
                    throw CheckFailure(description: "Untrusted vendor signature passed")
                } catch let error as UpdaterError { try expect(error.message.contains("does not satisfy"), error.message) }
            }
        }
        await check("Owned command observations distinguish output evidence from quiet waiting without declaring a stall") {
            let recorder = ObservationsRecorder()
            let result = try await ProcessRunner(observationInterval: 20_000_000).runObserved("/bin/sh", ["-c", "printf first; sleep 0.3; printf second >&2; sleep 0.3"], environment: [:], timeout: 5) { await recorder.receive($0) }
            let values = await recorder.snapshot()
            try expect(result.status == 0 && result.output == "first" && result.errorOutput == "second")
            try expect(values.contains { $0.isRunning && $0.stdoutBytes > 0 })
            try expect(values.last?.isRunning == false && values.last?.stdoutBytes == 5 && values.last?.stderrBytes == 6)
            try expect(values.allSatisfy { !$0.needsAttention && $0.processID != nil })
            let count = values.count
            try await Task.sleep(nanoseconds: 100_000_000)
            let afterReturn = await recorder.snapshot()
            try expect(afterReturn.count == count, "Observer continued after the command returned")
            let quiet = ProcessObservation(processID: 123, elapsedSeconds: 150, silentSeconds: 130, stdoutBytes: 0, stderrBytes: 0, isRunning: true)
            try expect(quiet.needsAttention && quiet.message.contains("Silence does not prove a stall"))
        }
        await check("App Store live observations preserve no-timeout installation and sanitized failure") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var app = try fixture.app(); app.packageID = "123456789"
            let runner = ObservingFixtureRunner()
            runner.observations = [ProcessObservation(processID: 123, elapsedSeconds: 150, silentSeconds: 130, stdoutBytes: 0, stderrBytes: 0, isRunning: true)]
            runner.handler = { _, _ in CommandResult(status: 1, errorOutput: "Controlled failure Bearer SYNTHETIC_TOKEN") }
            let recorder = ObservationsRecorder()
            do {
                try await AppStoreAdapter(executable: "/opt/homebrew/bin/mas", runner: runner, invokingUser: { (501, 20) }).upgrade(app) { await recorder.receive($0) }
                throw CheckFailure(description: "Expected automatic failure")
            } catch let error as UpdaterError { try expect(!error.message.contains("SYNTHETIC_TOKEN")) }
            let values = await recorder.snapshot()
            try expect(values.count == 1 && values[0].needsAttention && runner.observedCommands == ["/usr/bin/osascript"])
        }
        await check("Assisted App Store verification checks reviewed identity and target without mutating the original outcome") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let receipt = fixture.appURL.appendingPathComponent("Contents/_MASReceipt")
            try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
            try Data().write(to: receipt.appendingPathComponent("receipt"))
            var app = try fixture.app(); app.source = .appStore; app.packageID = "123456789"; app.targetVersion = "2.0"
            let plan = PlannedUpdate(app: app, preview: "Reviewed store target")
            try expect(!UpdateEngine.verifyAssisted(plan).verified)
            try fixture.write(version: "2.0", build: "20")
            let verification = UpdateEngine.verifyAssisted(plan)
            try expect(verification.verified)
            var record = ActivityRecord(app: app, state: .failed, message: "Original automatic failure")
            record.assistedVerification = verification
            let restored = try JSONDecoder().decode(ActivityRecord.self, from: JSONEncoder().encode(record))
            try expect(restored.state == .failed && restored.message == "Original automatic failure" && restored.assistedVerification?.verified == true)
            try FileManager.default.removeItem(at: receipt)
            try expect(!UpdateEngine.verifyAssisted(plan).verified)
            try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
            try Data().write(to: receipt.appendingPathComponent("receipt"))
            let infoURL = fixture.appURL.appendingPathComponent("Contents/Info.plist")
            var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
            info["CFBundleIdentifier"] = "test.wrong.identity"
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
            try expect(!UpdateEngine.verifyAssisted(plan).verified)
        }
        await check("Assisted verification rejects a changed canonical path or invalid reviewed signature") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let receipt = fixture.appURL.appendingPathComponent("Contents/_MASReceipt")
            try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
            try Data().write(to: receipt.appendingPathComponent("receipt"))
            try fixture.sign()
            var app = try fixture.app(); app.source = .appStore; app.packageID = "123456789"; app.targetVersion = "2.0"
            let plan = PlannedUpdate(app: app, preview: "")
            try fixture.write(version: "2.0", build: "20")
            try expect(!UpdateEngine.verifyAssisted(plan).verified, "Invalid signature was accepted")
            let destination = fixture.root.appendingPathComponent("Moved.app")
            try FileManager.default.moveItem(at: fixture.appURL, to: destination)
            try FileManager.default.createSymbolicLink(at: fixture.appURL, withDestinationURL: destination)
            try expect(!UpdateEngine.verifyAssisted(plan).verified)
        }
        await check("Assisted verification cannot bypass ownership while an automatic command remains active") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let brew = try fixture.candidate()
            let barrier = InstallBarrier()
            let runner = try fixture.runner()
            let task = Task {
                await UpdateEngine(runner: runner, sourcePaths: [.homebrew: "/usr/bin/true"])
                    .execute(PlannedUpdate(app: brew, preview: ""), cleanup: false) { stage, _ in
                        if stage == .preflight {
                            await barrier.enter()
                            while !(await barrier.released) { try await Task.sleep(nanoseconds: 1_000_000) }
                        }
                    }
            }
            while !(await barrier.entered) { try await Task.sleep(nanoseconds: 1_000_000) }
            let receipt = fixture.appURL.appendingPathComponent("Contents/_MASReceipt")
            try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
            try Data().write(to: receipt.appendingPathComponent("receipt"))
            var store = try fixture.app(); store.source = .appStore; store.packageID = "123456789"; store.targetVersion = "2.0"
            let plan = PlannedUpdate(app: store, preview: "")
            try fixture.write(version: "2.0", build: "20")
            let blocked = UpdateEngine.verifyAssisted(plan)
            await barrier.release()
            _ = await task.value
            try expect(!blocked.verified && blocked.message.contains("still owns"))
            try expect(UpdateEngine.verifyAssisted(plan).verified)
            try expect(!runner.calls.contains { $0.args.first == "upgrade" })
        }
        await check("Observed command timeouts stop their observer and retain an exited process observation") {
            let recorder = ObservationsRecorder()
            do {
                _ = try await ProcessRunner(observationInterval: 10_000_000).runObserved("/bin/sleep", ["2"], environment: [:], timeout: 0.1) { await recorder.receive($0) }
                throw CheckFailure(description: "Expected benign check timeout")
            } catch let error as UpdaterError { try expect(error.message.contains("timed out")) }
            let values = await recorder.snapshot()
            try expect(values.last?.isRunning == false && values.last?.processID != nil)
        }
        await check("Attention history recovers as interrupted and older records decode without fabricated observations") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let active = ActivityRecord(app: try fixture.app(), state: .needsAttention, message: "Waiting without recent output")
            let recovered = LocalStore(root: fixture.root).recover([active])[0]
            try expect(recovered.state == .interrupted && recovered.assistedVerification == nil)
            let old = ActivityRecord(app: try fixture.app(), state: .failed, message: "Earlier attempt")
            let data = try JSONEncoder().encode(old)
            let restored = try JSONDecoder().decode(ActivityRecord.self, from: data)
            try expect(restored.lastProcessObservation == nil && restored.automaticAttentionMessage == nil)
        }
        await check("Signed catalogs retain known-good data and reject unknown publishers and rollback") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let now = Date(); let key = Curve25519.Signing.PrivateKey(); let other = Curve25519.Signing.PrivateKey()
            let root = fixture.root.appendingPathComponent("Mappings")
            let store = SourceMappingCatalogStore(root: root, trustedKeys: ["test": key.publicKey.rawRepresentation])
            let catalog = catalogFixture(try fixture.app(), now: now)
            let bytes = try signedCatalog(catalog, key: key)
            try expect(try store.accept(bytes, now: now).revision == 2)
            try expect(try store.accept(bytes, now: now).revision == 2)
            for invalid in [try signedCatalog(catalog, key: other), try signedCatalog(catalog, key: key, keyID: "untrusted"), try signedCatalog(catalogFixture(try fixture.app(), now: now, revision: 1), key: key)] {
                try expectThrows { _ = try store.accept(invalid, now: now) }
                try expect(try store.load(now: now)?.revision == 2)
            }
            var replacement = catalog; replacement.mappings[0].channel = "beta"
            try expectThrows { _ = try store.accept(signedCatalog(replacement, key: key), now: now) }
            let noKeys = SourceMappingCatalogStore(root: fixture.root.appendingPathComponent("NoTrust"), trustedKeys: [:])
            try expectThrows { _ = try noKeys.accept(bytes, now: now) }
        }
        await check("Catalog expiry, client minimum and later revision do not reset rollback protection") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let now = Date(); let key = Curve25519.Signing.PrivateKey(); let root = fixture.root.appendingPathComponent("Mappings")
            let store = SourceMappingCatalogStore(root: root, trustedKeys: ["test": key.publicKey.rawRepresentation])
            let first = catalogFixture(try fixture.app(), now: now)
            try store.accept(signedCatalog(first, key: key), now: now)
            try expectThrows { _ = try store.load(now: now.addingTimeInterval(7200)) }
            let advanced = SourceMappingCatalogStore(root: root, trustedKeys: ["test": key.publicKey.rawRepresentation], minimumRevision: 3)
            try expectThrows { _ = try advanced.load(now: now) }
            let later = now.addingTimeInterval(7200)
            let next = catalogFixture(try fixture.app(), now: later, revision: 3)
            try expect(try advanced.accept(signedCatalog(next, key: key), now: later).revision == 3)
            try expectThrows { _ = try advanced.accept(signedCatalog(first, key: key), now: now) }
        }
        await check("Mapping matches require independent bundle, team, channel and compatibility evidence") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let now = Date(); let app = try fixture.app(); let catalog = catalogFixture(app, now: now)
            let identity = SourceIdentity(bundleID: app.bundleID, signingTeamIdentifier: "TEAMID1234", channel: "stable", macOS: "27.0", architecture: .arm64)
            let reviewed = try authenticatedCatalog(catalog, root: fixture.root, now: now)
            let evidence = try reviewed.evidence(mappingID: "example", identity: identity, now: now)
            try expect(evidence.level == .reviewedMapping && !evidence.permitsManagerUpdate)
            for conflict in ["bundle", "team", "channel", "unknown-team", "unknown-channel", "os", "receipt"] {
                var changed = identity
                switch conflict {
                case "bundle": changed.bundleID = "different.app"
                case "team": changed.signingTeamIdentifier = "OTHER12345"
                case "channel": changed.channel = "beta"
                case "unknown-team": changed.signingTeamIdentifier = nil
                case "unknown-channel": changed.channel = nil
                case "os": changed.macOS = "12.0"
                default: changed.hasStoreReceipt = true
                }
                try expectThrows { _ = try reviewed.evidence(mappingID: "example", identity: changed, now: now) }
            }
            var onlyIntel = catalog; onlyIntel.mappings[0].architectures = [.x86_64]
            let intel = try authenticatedCatalog(onlyIntel, root: fixture.root, now: now)
            try expectThrows { _ = try intel.evidence(mappingID: "example", identity: identity, now: now) }
            var unknown = catalog; unknown.mappings[0].signingTeamIdentifier = nil
            let provisional = try authenticatedCatalog(unknown, root: fixture.root, now: now)
            try expectThrows { _ = try provisional.evidence(mappingID: "example", identity: identity, now: now) }
        }
        await check("Signed mappings reject execution fields, conflicting domains and unsupported schema") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let now = Date(); let key = Curve25519.Signing.PrivateKey(); let catalog = catalogFixture(try fixture.app(), now: now)
            let store = SourceMappingCatalogStore(root: fixture.root.appendingPathComponent("Mappings"), trustedKeys: ["test": key.publicKey.rawRepresentation])
            let command = try signedCatalog(catalog, key: key, mutate: { object in
                var entries = object["mappings"] as! [[String: Any]]; entries[0]["command"] = "untrusted execution"; object["mappings"] = entries
            })
            try expectThrows { _ = try store.accept(command, now: now) }
            for kind in ["domain", "scheme", "user-info", "wildcard", "schema", "duplicate", "selector"] {
                var changed = catalog
                switch kind {
                case "domain": changed.mappings[0].metadataURL = URL(string: "https://evil.example.net/feed")
                case "scheme": changed.mappings[0].metadataURL = URL(string: "http://updates.example.com/feed")
                case "user-info": changed.mappings[0].metadataURL = URL(string: "https://user:password@updates.example.com/feed")
                case "wildcard": changed.mappings[0].officialHosts = ["*.example.com"]
                case "schema": changed.schemaVersion = 2
                case "duplicate": var duplicate = changed.mappings[0]; duplicate.id = "another"; changed.mappings.append(duplicate)
                default: changed.mappings[0].packageID = "--force"
                }
                try expectThrows { _ = try store.accept(signedCatalog(changed, key: key), now: now) }
            }
        }
        await check("Mapping evidence survives routes and cannot grant automatic installation") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let now = Date(); var app = try fixture.candidate()
            try expect(Preferences().isEligible(app), "Legacy installed-manager routes changed")
            let catalog = catalogFixture(app, now: now)
            app.sourceEvidence = try authenticatedCatalog(catalog, root: fixture.root, now: now).evidence(mappingID: "example", identity: SourceIdentity(bundleID: app.bundleID, signingTeamIdentifier: "TEAMID1234", channel: "stable", macOS: "27.0", architecture: .arm64), now: now)
            try expect(!Preferences().isEligible(app), "A signed mapping alone authorized an installer")
            let route = try JSONDecoder().decode(UpdateRoute.self, from: JSONEncoder().encode(UpdateRoute(app)!))
            try expect(route.applying(to: try fixture.app()).sourceEvidence == app.sourceEvidence)
            let release = app.releaseIdentity; app.sourceEvidence?.channel = "beta"
            try expect(release != app.releaseIdentity)
            app.sourceEvidence?.level = .installedManager; app.sourceEvidence?.bundleID = "different.app"
            try expect(!Preferences().isEligible(app), "Evidence for another bundle granted eligibility")
            let legacy = try JSONDecoder().decode(AppRecord.self, from: JSONEncoder().encode(try fixture.candidate()))
            try expect(legacy.sourceEvidence == nil && Preferences().isEligible(legacy))
        }
        await check("Catalog input and cached files are bounded and do not follow symlinks") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let now = Date(); let key = Curve25519.Signing.PrivateKey(); let root = fixture.root.appendingPathComponent("Mappings")
            let store = SourceMappingCatalogStore(root: root, trustedKeys: ["test": key.publicKey.rawRepresentation])
            try expectThrows { _ = try store.accept(Data(repeating: 65, count: 2 * 1024 * 1024 + 1), now: now) }
            try store.accept(signedCatalog(catalogFixture(try fixture.app(), now: now), key: key), now: now)
            let cache = root.appendingPathComponent("source-mapping-catalog.json")
            let mode = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as! NSNumber
            try expect(mode.intValue & 0o777 == 0o600)
            let retained = fixture.root.appendingPathComponent("RetainedCatalog")
            try FileManager.default.moveItem(at: cache, to: retained)
            try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: retained)
            try expectThrows { _ = try store.load(now: now) }
            try expect(FileManager.default.fileExists(atPath: retained.path))
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
        await check("Homebrew requires a complete SHA-256 for automatic updates") {
            let fixture = try Fixture(); defer { fixture.clean() }
            for digest: String? in [nil, "", "no_check", "abc", String(repeating: "g", count: 64), String(repeating: "a", count: 63), String(repeating: "a", count: 64) + "\n"] {
                let casks = try HomebrewAdapter.parseCasks(fixture.brewJSON(sha256: digest))
                let app = HomebrewAdapter.apply(casks: casks, outdated: ["example"], to: [try fixture.app()], executable: "/usr/bin/true")[0]
                try expect(app.state == .manual && !app.automatic && app.hasUpdate, "Unreviewable digest allowed automatic installation")
            }
        }
        await check("Reviewed Homebrew digests survive route and report round trips") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let casks = try HomebrewAdapter.parseCasks(fixture.brewJSON(sha256: String(repeating: "A", count: 64)))
            let app = HomebrewAdapter.apply(casks: casks, outdated: ["example"], to: [try fixture.app()], executable: "/usr/bin/true")[0]
            try expect(app.automatic && app.targetSHA256 == String(repeating: "a", count: 64))
            let route = try JSONDecoder().decode(UpdateRoute.self, from: JSONEncoder().encode(UpdateRoute(app)!))
            try expect(route.applying(to: try fixture.app()).targetSHA256 == app.targetSHA256)
            var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(app)) as! [String: Any]
            old.removeValue(forKey: "targetSHA256")
            let legacy = try JSONDecoder().decode(AppRecord.self, from: JSONSerialization.data(withJSONObject: old))
            try expect(legacy.targetSHA256 == nil)
        }
        await check("A changed Homebrew digest blocks either preflight before installation") {
            for isolatedOnly in [false, true] {
                let fixture = try Fixture(); defer { fixture.clean() }
                let runner = try fixture.runner { try fixture.write(version: "2.0", build: "20") }
                let original = runner.handler
                runner.handler = { call in
                    if call.args.first == "info", !isolatedOnly || call.environment["HOMEBREW_CACHE"]?.contains("Operations") == true {
                        return CommandResult(output: try fixture.brewJSON(sha256: String(repeating: "b", count: 64)))
                    }
                    return try original(call)
                }
                let engine = UpdateEngine(runner: runner, cacheRoot: fixture.root.appendingPathComponent("Cache"), sourcePaths: [.homebrew: "/usr/bin/true"])
                let result = await engine.execute(PlannedUpdate(app: try fixture.candidate(), preview: ""), cleanup: false) { _, _ in }
                try expect(result.state == .failed && !runner.calls.contains { $0.args.first == "upgrade" })
                try expect(try fixture.app().version == "1.0")
            }
        }
        await check("Homebrew display targets and package identities remain distinct") {
            let fixture = try Fixture(); defer { fixture.clean() }
            func metadata(_ package: String) throws -> String {
                var json = try JSONSerialization.jsonObject(with: Data(fixture.brewJSON(target: package).utf8)) as! [String: Any]
                var casks = json["casks"] as! [[String: Any]]
                casks[0]["bundle_short_version"] = "2.0"; casks[0]["bundle_version"] = "20"
                json["casks"] = casks
                return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
            }
            let json = try metadata("2000")
            let candidate = HomebrewAdapter.apply(casks: try HomebrewAdapter.parseCasks(json), outdated: ["example"], to: [try fixture.app()], executable: "/usr/bin/true")[0]
            try expect(candidate.targetVersion == "2.0" && candidate.targetPackageVersion == "2000" && candidate.targetBuild == "20")
            let runner = try fixture.runner { try fixture.write(version: "2.0", build: "20") }
            let original = runner.handler
            runner.handler = { call in call.args.first == "info" ? CommandResult(output: json) : try original(call) }
            let engine = UpdateEngine(runner: runner, cacheRoot: fixture.root.appendingPathComponent("Cache"), sourcePaths: [.homebrew: "/usr/bin/true"])
            let plan = try await engine.prepare([candidate], preferences: Preferences())[0]
            let changed = HomebrewAdapter.apply(casks: try HomebrewAdapter.parseCasks(metadata("2001")), outdated: ["example"], to: [try fixture.app()], executable: "/usr/bin/true")[0]
            try expect(changed.releaseIdentity != candidate.releaseIdentity)
            runner.handler = { call in call.args.first == "info" ? CommandResult(output: try metadata("2001")) : try original(call) }
            let rejected = await engine.execute(plan, cleanup: true) { _, _ in }
            try expect(rejected.state == .failed && !runner.calls.contains { $0.args.first == "upgrade" && !$0.args.contains("--dry-run") })
            runner.handler = { call in call.args.first == "info" ? CommandResult(output: json) : try original(call) }
            let result = await engine.execute(plan, cleanup: true) { _, _ in }
            try expect(result.state == .succeeded, result.message)
        }
        await check("Explicit Homebrew marketing targets cannot match only a build") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var casks = try HomebrewAdapter.parseCasks(fixture.brewJSON(target: "2000"))
            casks[0].displayVersion = "2.0"
            let candidate = HomebrewAdapter.apply(casks: casks, outdated: ["example"], to: [try fixture.app()], executable: "/usr/bin/true")[0]
            var after = candidate; after.build = "2.0"
            try expect(!UpdateEngine.verify(before: candidate, after: after))
            after.version = "2.0"; after.build = "20"
            try expect(UpdateEngine.verify(before: candidate, after: after))
            let current = HomebrewAdapter.apply(casks: casks, outdated: ["example"], to: [after], executable: "/usr/bin/true")[0]
            try expect(current.state == .current)
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
        await check("Signature verification rejects tampered, stripped and differently identified replacements") {
            for change in ["tampered", "stripped", "identity"] {
                let fixture = try Fixture(); defer { fixture.clean() }
                try fixture.sign()
                let plan = PlannedUpdate(app: try fixture.candidate(), preview: "Signed fixture")
                let runner = try fixture.runner {
                    try fixture.write(version: "2.0", build: "20")
                    try fixture.sign(identifier: change == "identity" ? "different.signing.identity" : nil)
                    if change == "tampered" { try Data("changed resource".utf8).write(to: fixture.appURL.appendingPathComponent("Contents/Resources/Sealed.txt")) }
                    if change == "stripped" { try FileManager.default.removeItem(at: fixture.appURL.appendingPathComponent("Contents/_CodeSignature")) }
                }
                let cache = fixture.root.appendingPathComponent("Cache")
                let engine = UpdateEngine(runner: runner, cacheRoot: cache, sourcePaths: [.homebrew: "/usr/bin/true"])
                let result = await engine.execute(plan, cleanup: true) { _, _ in }
                try expect(result.state == .failed && result.message.contains("signature"), "Invalid replacement recorded as success: " + change)
                try expect(try FileManager.default.contentsOfDirectory(atPath: cache.appendingPathComponent("Operations").path).count == 1)
            }
        }
        await check("Signature remnants cannot disguise a broken signed bundle as unsigned") {
            let fixture = try Fixture(); defer { fixture.clean() }
            try fixture.sign()
            // Removing executable metadata must not turn a broken sealed bundle
            // into the explicitly supported unsigned-app policy.
            try fixture.write(version: "1.0", build: "10")
            let runner = try fixture.runner()
            let engine = UpdateEngine(runner: runner, sourcePaths: [.homebrew: "/usr/bin/true"])
            let result = await engine.execute(PlannedUpdate(app: try fixture.candidate(), preview: ""), cleanup: false) { _, _ in }
            try expect(result.state == .failed && result.message.contains("signature") && runner.calls.isEmpty)
        }
        await check("A valid signed release with the same identity verifies and cleans its attempt") {
            let fixture = try Fixture(); defer { fixture.clean() }
            try fixture.sign()
            let runner = try fixture.runner { try fixture.write(version: "2.0", build: "20"); try fixture.sign() }
            let cache = fixture.root.appendingPathComponent("Cache")
            let engine = UpdateEngine(runner: runner, cacheRoot: cache, sourcePaths: [.homebrew: "/usr/bin/true"])
            let plans = try await engine.prepare([try fixture.candidate()], preferences: Preferences())
            let result = await engine.execute(plans[0], cleanup: true) { _, _ in }
            try expect(result.state == .succeeded, result.message)
            let retained = try FileManager.default.contentsOfDirectory(at: cache.appendingPathComponent("Operations"), includingPropertiesForKeys: nil)
            try expect(retained.count == 1 && FileManager.default.fileExists(atPath: retained[0].appendingPathComponent(".owner.json").path))
        }
        await check("A signed bundle changed after review is rejected before source commands") {
            let fixture = try Fixture(); defer { fixture.clean() }
            try fixture.sign()
            let plan = PlannedUpdate(app: try fixture.candidate(), preview: "")
            try Data("changed resource".utf8).write(to: fixture.appURL.appendingPathComponent("Contents/Resources/Sealed.txt"))
            let runner = try fixture.runner()
            let engine = UpdateEngine(runner: runner, sourcePaths: [.homebrew: "/usr/bin/true"])
            let result = await engine.execute(plan, cleanup: true) { _, _ in }
            try expect(result.state == .failed && result.message.contains("signature") && runner.calls.isEmpty)
            do { _ = try await engine.prepare([try fixture.candidate()], preferences: Preferences()); throw CheckFailure(description: "Invalid signature allowed review") }
            catch is UpdaterError { }
        }
        await check("Concurrent engines defer a duplicate app while unrelated updates remain independent") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let other = try Fixture(); defer { other.clean() }
            let firstRunner = try fixture.runner { try fixture.write(version: "2.0", build: "20") }
            let secondRunner = try fixture.runner { try fixture.write(version: "2.0", build: "20") }
            let otherRunner = try other.runner { try other.write(version: "2.0", build: "20") }
            let plan = PlannedUpdate(app: try fixture.candidate(), preview: "")
            let barrier = InstallBarrier()
            let first = Task {
                await UpdateEngine(runner: firstRunner, cacheRoot: fixture.root.appendingPathComponent("FirstCache"), sourcePaths: [.homebrew: "/usr/bin/true"])
                    .execute(plan, cleanup: true) { state, _ in
                        if state == .installing {
                            await barrier.enter()
                            while !(await barrier.released) { try await Task.sleep(nanoseconds: 10_000_000) }
                        }
                    }
            }
            for _ in 0..<500 {
                if await barrier.entered { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let duplicate = await UpdateEngine(runner: secondRunner, cacheRoot: fixture.root.appendingPathComponent("SecondCache"), sourcePaths: [.homebrew: "/usr/bin/true"])
                .execute(plan, cleanup: true) { _, _ in }
            let independent = await UpdateEngine(runner: otherRunner, cacheRoot: other.root.appendingPathComponent("Cache"), sourcePaths: [.homebrew: "/usr/bin/true"])
                .execute(PlannedUpdate(app: try other.candidate(), preview: ""), cleanup: true) { _, _ in }
            await barrier.release()
            let owned = await first.value
            try expect(owned.state == .succeeded && duplicate.state == .deferred && independent.state == .succeeded)
            try expect(secondRunner.calls.isEmpty, "Duplicate attempt ran source commands")
            try expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SecondCache").path))
        }
        await check("Separate processes share ownership and a killed owner cannot leave a stale lock") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let ready = fixture.root.appendingPathComponent("OwnerReady")
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            child.arguments = ["--hold-update-lock", fixture.appURL.path, ready.path]
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run()
            defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) }; child.waitUntilExit() }
            for _ in 0..<500 {
                if FileManager.default.fileExists(atPath: ready.path) || !child.isRunning { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try expect(FileManager.default.fileExists(atPath: ready.path), "Child did not reach its intercepted installer")
            let runner = try fixture.runner { try fixture.write(version: "2.0", build: "20") }
            let engine = UpdateEngine(runner: runner, cacheRoot: fixture.root.appendingPathComponent("ParentCache"), sourcePaths: [.homebrew: "/usr/bin/true"])
            let plan = PlannedUpdate(app: try fixture.candidate(), preview: "")
            let duplicate = await engine.execute(plan, cleanup: true) { _, _ in }
            kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
            try expect(duplicate.state == .deferred && runner.calls.isEmpty, "Separate process allowed a conflicting installer")
            let retried = await engine.execute(plan, cleanup: true) { _, _ in }
            try expect(retried.state == .succeeded, retried.message)
        }
        await check("Ownership releases after cancellation and an independent explicit retry can run") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let runner = try fixture.runner { try fixture.write(version: "2.0", build: "20") }
            let engine = UpdateEngine(runner: runner, cacheRoot: fixture.root.appendingPathComponent("Cache"), sourcePaths: [.homebrew: "/usr/bin/true"])
            let plan = PlannedUpdate(app: try fixture.candidate(), preview: "")
            let canceled = await engine.execute(plan, cleanup: true) { _, _ in throw CancellationError() }
            try expect(canceled.state == .canceled && runner.calls.isEmpty)
            let retried = await engine.execute(plan, cleanup: true) { _, _ in }
            try expect(retried.state == .succeeded, retried.message)
        }
        await check("Reviewed tool symlink destinations remain bound through both preflights and installation") {
            for changeAt in ["after-review", "isolated-preflight", "install-boundary", "stable"] {
                let fixture = try Fixture(); defer { fixture.clean() }
                let tool = fixture.root.appendingPathComponent("brew")
                try FileManager.default.createSymbolicLink(atPath: tool.path, withDestinationPath: "/usr/bin/true")
                func retarget() throws {
                    try FileManager.default.removeItem(at: tool)
                    try FileManager.default.createSymbolicLink(atPath: tool.path, withDestinationPath: "/usr/bin/false")
                }
                var app = try fixture.candidate(); app.routeExecutable = tool.path
                let runner = try fixture.runner { try fixture.write(version: "2.0", build: "20") }
                let engine = UpdateEngine(runner: runner, cacheRoot: fixture.root.appendingPathComponent("Cache"), sourcePaths: [.homebrew: tool.path])
                let plan = try await engine.prepare([app], preferences: Preferences())[0]
                runner.calls = []
                if changeAt == "after-review" { try retarget() }
                let original = runner.handler
                runner.handler = { call in
                    let result = try original(call)
                    if changeAt == "isolated-preflight", call.args.first == "info", call.environment["HOMEBREW_CACHE"]?.contains("Operations") == true { try retarget() }
                    return result
                }
                let result = await engine.execute(plan, cleanup: true) { state, _ in
                    if changeAt == "install-boundary", state == .installing { try retarget() }
                }
                let installs = runner.calls.filter { $0.args.first == "upgrade" }
                if changeAt == "stable" { try expect(result.state == .succeeded && installs.count == 1, result.message) }
                else { try expect(result.state == .failed && installs.isEmpty, "Changed destination reached installation at " + changeAt) }
                if changeAt == "after-review" { try expect(runner.calls.isEmpty) }
            }
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
            let metadata = try FileManager.default.contentsOfDirectory(at: operations, includingPropertiesForKeys: nil)
            try expect(metadata.count == 1 && FileManager.default.fileExists(atPath: metadata[0].appendingPathComponent(".owner.json").path))
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
            try Data("failed download".utf8).write(to: failed.folder.appendingPathComponent("Failed"))
            let nested = success.folder.appendingPathComponent("Homebrew/Nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data("owned download".utf8).write(to: nested.appendingPathComponent("Download"))
            try FileManager.default.createSymbolicLink(at: success.folder.appendingPathComponent("external"), withDestinationURL: external)
            try success.removeAfterVerification(verified: true)
            try expect(FileManager.default.fileExists(atPath: external.path) && FileManager.default.fileExists(atPath: failed.folder.appendingPathComponent("Failed").path))
            try expect(!FileManager.default.fileExists(atPath: nested.appendingPathComponent("Download").path))
            try expect(!FileManager.default.fileExists(atPath: success.folder.appendingPathComponent("external").path))
            try expect(FileManager.default.fileExists(atPath: success.folder.appendingPathComponent(".owner.json").path))
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
        await check("Diagnostics remove OAuth, API keys, signed URLs, user info, and complete bearer tokens") {
            let credentials = ["access_token", "refresh_token", "api_key", "X-Amz-Signature", "X-Amz-Credential", "X-Amz-Security-Token", "X-Goog-Signature", "X-Goog-Credential", "sig", "TOKEN"]
            for key in credentials {
                let original = "https://example.com/download?" + key + "=SYNTHETIC_CREDENTIAL%2B%3D&release=2#notes"
                let redacted = Diagnostics.redact(original)
                try expect(!redacted.contains("SYNTHETIC_CREDENTIAL"), "Leaked " + key)
                try expect(redacted.contains("&release=2#notes"), "Lost ordinary URL context")
            }
            try expect(Diagnostics.redact("https://user:secret@example.com/feed") == "https://[REDACTED]@example.com/feed")
            try expect(Diagnostics.redact("https://SYNTHETIC_USER@example.com/feed") == "https://[REDACTED]@example.com/feed")
            try expect(Diagnostics.redact("Authorization: Bearer abc~def+/ghi== next") == "Authorization: Bearer [REDACTED] next")
            let ordinary = "https://example.com/feed?release=2&architecture=arm64 source returned 401"
            try expect(Diagnostics.redact(ordinary) == ordinary)
        }
        await check("Report export redacts values without corrupting JSON") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var app = try fixture.app()
            app.sparkleFeed = "https://user:secret@example.com/feed?token=secret"
            app.detail = "Failure: https://example.com/?access_token=secret&refresh_token=secret&api_key=secret&X-Amz-Signature=secret&release=2"
            let data = try ReportExport.data(apps: [app], sources: [], history: [], lastScan: nil)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            try expect(json?["apps"] != nil)
            try expect(!String(decoding: data, as: UTF8.self).contains("secret"))
        }
        await check("Post-validation swaps cannot redirect cleanup into replacements or failed attempts") {
            for swap in ["replacement", "failed", "parent"] {
                let fixture = try Fixture(); defer { fixture.clean() }
                let fm = FileManager.default
                let root = fixture.root.appendingPathComponent("Operations")
                let cache = try OwnedUpdateCache(root: root)
                let failed = try OwnedUpdateCache(root: root)
                try Data("owned download".utf8).write(to: cache.folder.appendingPathComponent("Download"))
                try Data("failed download".utf8).write(to: failed.folder.appendingPathComponent("Failed"))
                let retained = fixture.root.appendingPathComponent("Retained")
                try cache.removeAfterVerification(verified: true, afterValidation: {
                    if swap == "parent" {
                        try fm.moveItem(at: root, to: retained)
                        try fm.copyItem(at: retained, to: root)
                    } else {
                        try fm.moveItem(at: cache.folder, to: retained)
                        if swap == "failed" { try fm.moveItem(at: failed.folder, to: cache.folder) }
                        else { try fm.copyItem(at: retained, to: cache.folder) }
                    }
                    try Data("unrelated data".utf8).write(to: cache.folder.appendingPathComponent("Keep"))
                })
                try expect(try Data(contentsOf: cache.folder.appendingPathComponent("Keep")) == Data("unrelated data".utf8), "Deleted replacement after validation: " + swap)
                let original = swap == "parent" ? retained.appendingPathComponent(cache.folder.lastPathComponent) : retained
                try expect(!fm.fileExists(atPath: original.appendingPathComponent("Download").path))
                let preservedFailed = swap == "failed" ? cache.folder : (swap == "parent" ? retained.appendingPathComponent(failed.folder.lastPathComponent) : failed.folder)
                try expect(try Data(contentsOf: preservedFailed.appendingPathComponent("Failed")) == Data("failed download".utf8))
            }
        }
        await check("Report publication is private under every process mask and replaces old permissions") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let data = try ReportExport.data(apps: [try fixture.app()], sources: [], history: [], lastScan: nil)
            let original = umask(0o000); defer { umask(original) }
            for mask: mode_t in [0o000, 0o022, 0o077, 0o777] {
                for replacing in [false, true] {
                    let destination = fixture.root.appendingPathComponent("report-" + String(mask, radix: 8) + "-" + String(replacing) + ".json")
                    umask(0o000)
                    if replacing {
                        try Data("old report".utf8).write(to: destination)
                        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: destination.path)
                    }
                    umask(mask)
                    try ReportExport.write(data, to: destination)
                    let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as! NSNumber
                    try expect(mode.intValue & 0o777 == 0o600, "Report inherited broad/old permissions under mask " + String(mask, radix: 8))
                    try expect(try Data(contentsOf: destination) == data)
                    try expect(try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) is [String: Any])
                }
            }
        }
        await check("Atomic report publication replaces a selected symlink without modifying its target") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let target = fixture.root.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: target)
            let destination = fixture.root.appendingPathComponent("report.json")
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
            try ReportExport.write(Data("report".utf8), to: destination)
            try expect(try Data(contentsOf: target) == Data("keep".utf8))
            try expect(try Data(contentsOf: destination) == Data("report".utf8))
            try expect(try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true)
        }
        await check("A failed report publication retains the destination and removes its temporary file") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let destination = fixture.root.appendingPathComponent("ReportDirectory")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let keep = destination.appendingPathComponent("Keep.txt")
            try Data("keep".utf8).write(to: keep)
            try expectThrows { try ReportExport.write(Data("report".utf8), to: destination) }
            try expect(try Data(contentsOf: keep) == Data("keep".utf8))
            try expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix(".maccet-report-") })
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
        await check("Raw output stays in anonymous pipes under permissive and restrictive process masks") {
            // These checks run serially; restore the process-wide test mask even
            // if the assertion fails. No production code changes the user's mask.
            let originalMask = umask(0o000)
            defer { umask(originalMask) }
            let masks: [mode_t] = [0o000, 0o022, 0o077]
            for mask in masks {
                umask(mask)
                let result = try await ProcessRunner().run(URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path, ["--inspect-output-transport"], environment: [:], timeout: 5)
                try expect(result.status == 0)
                try expect(result.output.split(whereSeparator: \.isNewline).map(String.init) == ["pipe", "pipe"], "Raw process capture was not private under mask " + String(mask, radix: 8))
            }
        }
        await check("Continuously growing output stays bounded while the child safely finishes") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let fm = FileManager.default
            func captures() throws -> [URL] {
                try fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("unified-updater-") }
            }
            let existing = Set(try captures())
            let operation = Task { () -> String in
                do {
                    _ = try await ProcessRunner().run(URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path, ["--stream-process-output", fixture.root.path], environment: [:], timeout: nil)
                    return ""
                } catch { return error.localizedDescription }
            }
            for _ in 0..<500 {
                if fm.fileExists(atPath: fixture.root.appendingPathComponent("ready").path) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            var maximumCaptureSize = 0
            for folder in try captures() where !existing.contains(folder) {
                for stream in ["stdout", "stderr"] {
                    let attributes = try fm.attributesOfItem(atPath: folder.appendingPathComponent(stream).path)
                    maximumCaptureSize = max(maximumCaptureSize, (attributes[.size] as? NSNumber)?.intValue ?? 0)
                }
            }
            try Data().write(to: fixture.root.appendingPathComponent("continue"))
            let message = await operation.value
            try expect(fm.fileExists(atPath: fixture.root.appendingPathComponent("ready").path) && fm.fileExists(atPath: fixture.root.appendingPathComponent("finished").path), "Output policy interrupted the child")
            try expect(maximumCaptureSize <= 16 * 1024 * 1024, "Capture exceeded the limit while the child was still running")
            try expect(message.contains("exceeded") && message.contains("exit status 0") && message.contains("Useful fixture context"))
            try expect(!message.contains("SYNTHETIC_BEARER"), "Overflow diagnostics leaked a credential")
        }
        await check("Inherited output descriptors do not delay the owned command or break descendants") {
            let fixture = try Fixture(); defer { fixture.clean() }
            let marker = fixture.root.appendingPathComponent("descendant-finished")
            let result = try await ProcessRunner().run(URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path, ["--inherited-process-output", marker.path], environment: [:], timeout: 5)
            try expect(result.status == 0 && result.output == "done")
            try expect(!FileManager.default.fileExists(atPath: marker.path), "Runner waited for an unrelated inherited descriptor")
            try Data().write(to: URL(fileURLWithPath: marker.path + ".continue"))
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: marker.path) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try expect(FileManager.default.fileExists(atPath: marker.path), "Closing capture broke the descendant")
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
        await check("App Store authorization forwards the invoking user and group") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var app = try fixture.app(); app.packageID = "123456789"
            let runner = FakeRunner { _ in CommandResult() }
            try await AppStoreAdapter(executable: "/opt/homebrew/bin/mas", runner: runner).upgrade(app)
            try expect(runner.calls.count == 1 && runner.calls[0].executable == "/usr/bin/osascript")
            let call = runner.calls[0]
            let script = call.args.last ?? ""
            try expect(script.contains("/usr/bin/env SUDO_UID=\(getuid()) SUDO_GID=\(getgid()) '"))
            try expect(script.contains("/opt/homebrew/bin/mas' update --inaccurate --check-min-os 123456789"))
            try expect(script.hasSuffix("with administrator privileges") && call.timeout == nil)
            app.packageID = "123456789;whoami"
            do { try await AppStoreAdapter(executable: "/opt/homebrew/bin/mas", runner: runner).upgrade(app); throw CheckFailure(description: "Expected invalid ID rejection") }
            catch is UpdaterError { }
            try expect(runner.calls.count == 1)
        }
        await check("App Store context validation and authorization cancellation fail safely") {
            let fixture = try Fixture(); defer { fixture.clean() }
            var app = try fixture.app(); app.packageID = "123456789"
            let runner = FakeRunner { _ in CommandResult(status: 1, errorOutput: "User canceled. (-128)") }
            for path in ["/opt/homebrew/bin/mas", "/usr/local/bin/mas", "/opt/local/bin/mas"] {
                do {
                    try await AppStoreAdapter(executable: path, runner: runner, invokingUser: { (501, 20) }).upgrade(app)
                    throw CheckFailure(description: "Canceled authorization succeeded")
                } catch let error as UpdaterError { try expect(error.message.contains("User canceled")) }
                try expect(runner.calls.last?.args.last?.contains("SUDO_UID=501 SUDO_GID=20 '") == true)
            }
            let count = runner.calls.count
            for (path, uid) in [("/opt/homebrew/bin/mas", uid_t(0)), ("/tmp/mas", uid_t(501))] {
                do {
                    try await AppStoreAdapter(executable: path, runner: runner, invokingUser: { (uid, 20) }).upgrade(app)
                    throw CheckFailure(description: "Unsafe context reached authorization")
                } catch is UpdaterError { }
            }
            try expect(runner.calls.count == count)
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
        await check("Install Missing Tools does not upgrade already-installed tools or mas") {
            let fixture = SetupFixture()
            let result = await fixture.service().installMissingTools()
            try expect(result.allSatisfy { $0.phase == .ready })
            try expect(fixture.actions.isEmpty, "Install Missing Tools upgraded installed tools")
        }
        await check("Install Missing Tools installs only the missing helper route without manager self-updates") {
            let fixture = SetupFixture(); fixture.paths.removeValue(forKey: "brew"); fixture.paths.removeValue(forKey: "mas")
            let result = await fixture.service().installMissingTools()
            try expect(result.allSatisfy { $0.phase == .ready })
            try expect(fixture.actions == ["install-package", "mas-install"], "Missing-tool install performed manager upgrades")
        }
        await check("Upgrade Source Tools updates installed tools, refreshes metadata, and does not install missing managers") {
            let fixture = SetupFixture()
            let result = await fixture.service().upgradeSourceTools()
            try expect(result[1].phase == .ready && result[2].phase == .ready && result[3].phase == .ready)
            try expect(fixture.actions == ["brew-update", "ports-update", "mas-update"])
            try expect(result[1].message.contains("Homebrew") && result[2].message.contains("MacPorts"))
        }
        await check("Upgrade Source Tools fails a missing required manager instead of installing it") {
            let fixture = SetupFixture(); fixture.paths.removeValue(forKey: "brew")
            let result = await fixture.service().upgradeSourceTools()
            try expect(result[1].phase == .failed && result[1].message.contains("not installed"))
            try expect(!fixture.actions.contains("install-package"), "Upgrade installed a missing manager")
            try expect(result[2].phase == .ready && result[3].phase == .failed, "Dependent/remaining steps were not handled truthfully")
        }
        await check("Upgrade Source Tools touches only enabled sources") {
            let fixture = SetupFixture(); fixture.paths = ["brew": "/opt/homebrew/bin/brew"]
            let result = await fixture.service().upgradeSourceTools(disabledSources: [.macPorts, .appStore])
            try expect(fixture.actions == ["brew-update"])
            try expect(result[1].phase == .ready && result[2].phase == .disabled && result[3].phase == .disabled)
        }
        await check("Retry on separated intents preserves unrelated ready work") {
            let fixture = SetupFixture(); fixture.failBrew = true
            let first = await fixture.service().upgradeSourceTools()
            try expect(first[1].phase == .failed && first[2].phase == .ready && first[3].phase == .failed)
            fixture.failBrew = false
            let retried = await fixture.service().upgradeSourceTools(retrying: first)
            try expect(retried[1].phase == .ready && retried[2].phase == .ready && retried[3].phase == .ready)
            try expect(fixture.actions == ["brew-update", "ports-update", "brew-update", "mas-update"], "Retry repeated successful manager upgrades")
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
