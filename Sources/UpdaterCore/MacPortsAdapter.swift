import Foundation

public struct PortRelease: Equatable {
    public var name: String
    public var installed: String
    public var target: String
}

public struct MacPortsAdapter {
    public let executable: String
    public let runner: any CommandRunning
    public init(executable: String, runner: any CommandRunning) { self.executable = executable; self.runner = runner }
    public func command(_ arguments: [String]) async throws -> String {
        try await runner.run(executable, arguments, environment: [:], timeout: 90).checked()
    }
    public static func validateName(_ name: String) throws {
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil,
              !["all", "active", "inactive", "installed", "uninstalled", "outdated", "obsolete", "requested", "unrequested", "current", "leaves", "rleaves"].contains(name.lowercased()) else {
            throw UpdaterError("Invalid or broad MacPorts package selector.")
        }
    }
    public static func parseOutdated(_ text: String) throws -> [PortRelease] {
        let regex = try NSRegularExpression(pattern: #"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s+([^\s]+)\s+<\s+([^\s]+)\s*$"#)
        return try text.split(whereSeparator: \.isNewline).compactMap { line in
            let value = String(line).trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value == "No installed ports are outdated." || value == "The following installed ports are outdated:" { return nil }
            guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
                throw UpdaterError("Unrecognized MacPorts outdated output. The result was not treated as current.")
            }
            func part(_ n: Int) -> String { String(value[Range(match.range(at: n), in: value)!]) }
            try validateName(part(1))
            return PortRelease(name: part(1), installed: part(2), target: part(3))
        }
    }
    public static func parseOwner(_ text: String, path: String) throws -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "\(path) is not provided by a MacPorts port." { return nil }
        let prefix = path + " is provided by: "
        guard trimmed.hasPrefix(prefix), !trimmed.contains("\n") else { throw UpdaterError("Unrecognized MacPorts ownership result.") }
        let name = String(trimmed.dropFirst(prefix.count))
        try validateName(name)
        return name
    }
    public func check(apps: [AppRecord]) async throws -> [AppRecord] {
        let releases = try Self.parseOutdated(await command(["-q", "outdated"]))
        var result = apps
        for index in result.indices where !result[index].hasStoreReceipt && !result[index].bundleID.isEmpty {
            let path = result[index].path + "/Contents/Info.plist"
            // A registered installed file, not a similar catalog name, proves ownership.
            let response = try await runner.run(executable, ["-N", "provides", path], environment: [:], timeout: 15)
            let noOwner = "\(path) is not provided by a MacPorts port."
            let text = response.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == noOwner && response.errorOutput.isEmpty { continue }
            let owner = try Self.parseOwner(response.checked(), path: path)
            guard let owner else { continue }
            var app = result[index]
            app.source = .macPorts; app.packageID = owner; app.routeExecutable = executable; app.checkedAt = Date()
            if let release = releases.first(where: { $0.name == owner }) {
                let target = String(release.target.split(separator: "_").first ?? "")
                app.targetVersion = target; app.state = .manual; app.automatic = false
                app.targetPackageVersion = release.target
                app.detail = "MacPorts reports \(release.installed) → \(release.target). Uses the local ports index; retry source setup to refresh it if it is stale."
                if ReleaseComparison.compare(app.version, target) == .orderedAscending {
                    app.state = .updateAvailable; app.automatic = true
                } else if ReleaseComparison.compare(app.version, target) == .orderedDescending {
                    app.state = .newerInstalled; app.targetVersion = nil
                } else {
                    app.detail += " A revision, variant, or non-numeric release requires manual verification."
                }
            } else {
                app.state = .current; app.detail = "No update reported by MacPorts' local index. Launch setup refreshes this index; retry source setup if needed."
            }
            result[index] = app
        }
        return result
    }
    public func preview(_ app: AppRecord) async throws -> String {
        guard let name = app.packageID else { throw UpdaterError("Missing MacPorts identity.") }
        try Self.validateName(name)
        let result = try await command(["-y", "-N", "upgrade", name])
        return result + "\nMacPorts may upgrade required dependencies shown above. Old port versions and shared caches will be retained."
    }
    public func upgrade(_ app: AppRecord) async throws {
        guard let name = app.packageID else { throw UpdaterError("Missing MacPorts identity.") }
        try Self.validateName(name)
        guard executable == "/opt/local/bin/port" else { throw UpdaterError("Only the standard MacPorts installation can be elevated in this release.") }
        let script = "do shell script \"/opt/local/bin/port -N -k upgrade " + name + "\" with administrator privileges"
        _ = try await runner.run("/usr/bin/osascript", ["-e", script], environment: [:], timeout: nil).checked()
    }
}
