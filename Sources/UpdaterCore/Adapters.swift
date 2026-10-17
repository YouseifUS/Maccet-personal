import Foundation
import Darwin

public enum ToolLocator {
    public static func find(_ name: String) -> String? {
        if name == "port" { return FileManager.default.isExecutableFile(atPath: "/opt/local/bin/port") ? "/opt/local/bin/port" : nil }
        for root in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] {
            let path = root + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
    public static func defaultSources() -> [UpdateSource: String] {
        Dictionary(uniqueKeysWithValues: UpdateSource.allCases.compactMap { source in find(source.toolName).map { (source, $0) } })
    }
    public static func validatePackageID(_ id: String) throws {
        guard id.range(of: #"^[a-z0-9][a-z0-9+@._-]*(?:/[a-z0-9][a-z0-9+@._-]*){0,2}$"#, options: .regularExpression) != nil else {
            throw UpdaterError("Invalid Homebrew package identity.")
        }
    }
    public static func validateStoreID(_ id: String) throws {
        guard id.range(of: #"^[1-9][0-9]{3,19}$"#, options: .regularExpression) != nil else { throw UpdaterError("Invalid App Store identity.") }
    }
    public static func canonicalPath(_ path: String) -> String {
        var value = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        if value.hasPrefix("/System/Volumes/Data/") { value = String(value.dropFirst("/System/Volumes/Data".count)) }
        return value
    }
}

public struct BrewCask {
    public var token: String
    public var version: String
    public var installed: String
    public var targets: [String]
    public var simpleApp: Bool
    public var pinned: Bool
    public var disabled: Bool
    public var macOSMinimum: String?
    public var displayVersion: String?
    public var buildVersion: String?
}

public struct HomebrewAdapter {
    public let executable: String
    public let runner: any CommandRunning
    public let environment: [String: String]
    public init(executable: String, runner: any CommandRunning, cacheRoot: URL? = nil, freezeMetadata: Bool = false) {
        self.executable = executable; self.runner = runner
        var environment = [
            "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1",
            "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1"
        ]
        if let cacheRoot {
            environment["HOMEBREW_CACHE"] = cacheRoot.appendingPathComponent("Homebrew").path
            environment["HOMEBREW_LOGS"] = cacheRoot.appendingPathComponent("Logs").path
        }
        if freezeMetadata { environment["HOMEBREW_API_AUTO_UPDATE_SECS"] = "2147483647" }
        self.environment = environment
    }
    public func command(_ args: [String], timeout: TimeInterval? = 120) async throws -> String {
        try await runner.run(executable, args, environment: environment, timeout: timeout).checked()
    }
    public static func parseCasks(_ text: String) throws -> [BrewCask] {
        guard let data = text.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]] else { throw UpdaterError("Unsupported Homebrew inventory format.") }
        return try casks.map { value in
            guard let token = value["token"] as? String, let version = value["version"] as? String,
                  let artifacts = value["artifacts"] as? [[String: Any]] else { throw UpdaterError("Incomplete Homebrew cask record.") }
            try ToolLocator.validatePackageID(token)
            let installed = value["installed"] as? String ?? (value["installed"] as? [String])?.first ?? ""
            let targets: [String] = artifacts.compactMap { artifact in
                guard let app = artifact["app"] as? [Any], let name = app.first as? String else { return nil }
                if let target = artifact["target"] as? String { return target }
                if let options = app.last as? [String: Any], let target = options["target"] as? String {
                    return target.hasPrefix("/") ? target : "/Applications/" + target
                }
                return "/Applications/" + name
            }
            let complex = artifacts.contains { $0["pkg"] != nil || $0["installer"] != nil || $0["preflight"] != nil || $0["postflight"] != nil }
            let depends = value["depends_on"] as? [String: Any]
            let macOS = depends?["macos"] as? [String: Any]
            let minimum = (macOS?[">="] as? [String])?.first
            return BrewCask(token: token, version: version, installed: installed, targets: targets,
                simpleApp: targets.count == 1 && !complex, pinned: value["pinned"] as? Bool ?? false,
                disabled: value["disabled"] as? Bool ?? false, macOSMinimum: minimum,
                displayVersion: value["bundle_short_version"] as? String, buildVersion: value["bundle_version"] as? String)
        }
    }
    public static func parseOutdated(_ text: String) throws -> Set<String> {
        guard let data = text.data(using: .utf8), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = value["casks"] as? [[String: Any]] else { throw UpdaterError("Unsupported Homebrew outdated format.") }
        return try Set(casks.map {
            guard let name = $0["name"] as? String ?? $0["token"] as? String else { throw UpdaterError("Missing cask identity in Homebrew result.") }
            try ToolLocator.validatePackageID(name)
            return name
        })
    }
    public func inventory() async throws -> [BrewCask] {
        try Self.parseCasks(await command(["info", "--cask", "--json=v2", "--installed"]))
    }
    public func check(apps: [AppRecord]) async throws -> [AppRecord] {
        let casks = try await inventory()
        let outdated = try Self.parseOutdated(await command(["outdated", "--cask", "--greedy", "--json=v2"]))
        return Self.apply(casks: casks, outdated: outdated, to: apps, executable: executable)
    }
    public static func apply(casks: [BrewCask], outdated: Set<String>, to apps: [AppRecord], executable: String) -> [AppRecord] {
        apps.map { original in
            var app = original
            guard !app.hasStoreReceipt else { return app }
            let matches = casks.filter { !$0.installed.isEmpty && $0.targets.contains { ToolLocator.canonicalPath($0) == ToolLocator.canonicalPath(app.path) } }
            guard !matches.isEmpty else { return app }
            guard matches.count == 1 else {
                app.source = .homebrew
                app.state = .ambiguous; app.detail = "Multiple installed casks claim this location. Automatic updates are blocked."; return app
            }
            let cask = matches[0]
            app.source = .homebrew; app.packageID = cask.token; app.routeExecutable = executable; app.checkedAt = Date()
            if cask.version == "latest" {
                app.detail = "This cask has no specific latest version. Check its built-in updater."; return app
            }
            let target = cask.displayVersion ?? cask.version
            if ReleaseComparison.compare(app.version, target) == .orderedDescending {
                app.state = .newerInstalled; app.detail = "The installed app is newer than Homebrew's catalog."; return app
            }
            let versionMatches: Bool
            if let display = cask.displayVersion, let build = cask.buildVersion {
                versionMatches = ReleaseComparison.compare(app.version, display) == .orderedSame
                    && ReleaseComparison.compare(app.build, build) == .orderedSame
            } else { versionMatches = ReleaseComparison.satisfies(app, target: cask.version) }
            if versionMatches {
                app.state = .current; app.detail = "Installed metadata matches the available Homebrew release."; return app
            }
            guard outdated.contains(cask.token) else {
                app.detail = "Homebrew does not report an update, but installed app metadata could not be reconciled with its catalog."; return app
            }
            app.targetVersion = cask.version
            app.targetBuild = cask.buildVersion
            app.state = .updateAvailable; app.automatic = cask.simpleApp && !cask.pinned && !cask.disabled
            app.detail = "Managed by Homebrew. The update will be checked again before installation."
            if !app.automatic { app.state = .manual; app.detail = "Pinned, disabled, or complex installer cask. Update through Homebrew manually." }
            if cask.version.split(separator: ",").contains(where: { ReleaseComparison.compare(String($0), String($0)) == nil }) {
                app.state = .manual; app.automatic = false; app.detail = "This vendor version needs a source-specific verifier. Update through Homebrew manually."
            }
            if let minimum = cask.macOSMinimum {
                let os = ProcessInfo.processInfo.operatingSystemVersion
                if ReleaseComparison.compare("\(os.majorVersion).\(os.minorVersion)", minimum) == .orderedAscending {
                    app.state = .manual; app.automatic = false; app.detail = "Latest release requires macOS \(minimum) or later."
                }
            }
            return app
        }
    }
    public func preview(_ app: AppRecord) async throws -> String {
        guard let id = app.packageID else { throw UpdaterError("Missing cask identity.") }
        try ToolLocator.validatePackageID(id)
        return try await command(["upgrade", "--dry-run", "--cask", "--greedy", "--no-quit", "--skip-cask-deps", id])
    }
    public func upgrade(_ app: AppRecord) async throws {
        guard let id = app.packageID else { throw UpdaterError("Missing cask identity.") }
        try ToolLocator.validatePackageID(id)
        _ = try await command(["upgrade", "--cask", "--greedy", "--no-quit", "--skip-cask-deps", id], timeout: nil)
    }
}

public struct StoreApp: Equatable {
    public var id: String
    public var bundleID: String
    public var path: String
}
public struct StoreUpdate: Equatable {
    public var id: String
    public var installed: String
    public var target: String
}

public struct AppStoreAdapter {
    public let executable: String
    public let runner: any CommandRunning
    private let invokingUser: () -> (userID: uid_t, groupID: gid_t)
    public init(executable: String, runner: any CommandRunning,
                invokingUser: @escaping () -> (userID: uid_t, groupID: gid_t) = { (getuid(), getgid()) }) {
        self.executable = executable; self.runner = runner; self.invokingUser = invokingUser
    }
    public func command(_ args: [String]) async throws -> String {
        try await runner.run(executable, args, environment: [:], timeout: 90).checked()
    }
    public static func parseInstalled(_ text: String) throws -> [StoreApp] {
        try text.split(whereSeparator: \.isNewline).map { line in
            guard let data = String(line).data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["adamID"] as? NSNumber, let bundle = json["bundleID"] as? String,
                  let path = json["path"] as? String, path.hasPrefix("/"), !bundle.isEmpty else {
                throw UpdaterError("Unsupported mas JSON output. Version 7 or later with identity/path metadata is required.")
            }
            let value = id.stringValue; try ToolLocator.validateStoreID(value)
            return StoreApp(id: value, bundleID: bundle, path: ToolLocator.canonicalPath(path))
        }
    }
    public static func parseOutdated(_ text: String) throws -> [StoreUpdate] {
        let regex = try NSRegularExpression(pattern: #"^\s*([0-9]+)\s+.+?\s+\(([^()]+?)\s+->\s+([^()]+?)\)\s*$"#)
        return try text.split(whereSeparator: \.isNewline).map { line in
            let value = String(line)
            guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), match.numberOfRanges == 4 else {
                throw UpdaterError("Unrecognized mas update output. This check was not treated as up to date.")
            }
            func part(_ n: Int) -> String { String(value[Range(match.range(at: n), in: value)!]).trimmingCharacters(in: .whitespaces) }
            try ToolLocator.validateStoreID(part(1))
            return StoreUpdate(id: part(1), installed: part(2), target: part(3))
        }
    }
    public func check(apps: [AppRecord]) async throws -> [AppRecord] {
        let installed = try Self.parseInstalled(await command(["list", "--json"]))
        let updates = try Self.parseOutdated(await command(["outdated", "--inaccurate", "--check-min-os"]))
        return Self.apply(installed: installed, updates: updates, to: apps, executable: executable)
    }
    public static func apply(installed: [StoreApp], updates: [StoreUpdate], to apps: [AppRecord], executable: String) -> [AppRecord] {
        apps.map { original in
            var app = original
            guard app.hasStoreReceipt else { return app }
            let matches = installed.filter { $0.bundleID == app.bundleID && $0.path == ToolLocator.canonicalPath(app.path) }
            guard matches.count == 1 else {
                app.detail = "The App Store receipt could not be matched uniquely to mas identity and path metadata."; return app
            }
            let match = matches[0]
            app.source = .appStore; app.packageID = match.id; app.routeExecutable = executable; app.checkedAt = Date()
            guard apps.filter({ $0.bundleID == app.bundleID && $0.hasStoreReceipt }).count == 1,
                  installed.filter({ $0.id == match.id }).count == 1 else {
                app.state = .ambiguous; app.detail = "Multiple copies of this store app exist. Open App Store to resolve which copy to update."; return app
            }
            if let update = updates.first(where: { $0.id == match.id }) {
                guard ReleaseComparison.compare(app.version, update.installed) == .orderedSame else {
                    app.detail = "Store metadata and the installed version disagree. Rescan or open App Store."; return app
                }
                if ReleaseComparison.compare(app.version, update.target) == .orderedDescending {
                    app.state = .newerInstalled; app.detail = "Installed version is newer than the store lookup."; return app
                }
                app.targetVersion = update.target; app.state = .updateAvailable; app.automatic = true
                app.detail = "App Store update found. macOS administrator authorization may be required."
                if ReleaseComparison.compare(update.target, update.target) == nil {
                    app.state = .manual; app.automatic = false; app.detail = "This store version cannot be verified automatically. Open App Store to update."
                }
            } else {
                app.state = .current; app.detail = "No update reported by mas. Apple's lookup can lag behind the App Store."
            }
            return app
        }
    }
    public func upgrade(_ app: AppRecord) async throws {
        guard let id = app.packageID else { throw UpdaterError("Missing App Store identity.") }
        try ToolLocator.validateStoreID(id)
        guard ["/opt/homebrew/bin/mas", "/usr/local/bin/mas", "/opt/local/bin/mas"].contains(executable) else { throw UpdaterError("Unrecognized mas executable location.") }
        // Read the real process identity before authorization. Inherited SUDO_*
        // environment values are not evidence of the user requesting this update.
        let user = invokingUser()
        guard user.userID != 0 else { throw UpdaterError("Run Maccet as your regular user before updating App Store applications.") }
        // Only fixed paths and validated numeric values enter the privileged shell.
        let shellCommand = "/usr/bin/env SUDO_UID=\(user.userID) SUDO_GID=\(user.groupID) '" + executable + "' update --inaccurate --check-min-os " + id
        let script = "do shell script \"" + shellCommand + "\" with administrator privileges"
        _ = try await runner.run("/usr/bin/osascript", ["-e", script], environment: [:], timeout: nil).checked()
    }
}
