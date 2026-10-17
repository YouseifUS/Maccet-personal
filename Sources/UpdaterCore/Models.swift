import Foundation

public enum UpdateSource: String, Codable, CaseIterable, Identifiable {
    case homebrew, macPorts, appStore
    public var id: String { rawValue }
    public var title: String {
        switch self { case .homebrew: return "Homebrew"; case .macPorts: return "MacPorts"; case .appStore: return "App Store" }
    }
    public var symbol: String { self == .appStore ? "app.badge" : "shippingbox" }
    public var toolName: String { self == .homebrew ? "brew" : self == .macPorts ? "port" : "mas" }
    public var versionArguments: [String] { self == .macPorts || self == .appStore ? ["version"] : ["--version"] }
    public var documentationURL: String {
        switch self { case .homebrew: return "https://brew.sh"; case .macPorts: return "https://www.macports.org"; case .appStore: return "https://github.com/mas-cli/mas" }
    }
}

public enum CheckState: String, Codable, CaseIterable {
    case unchecked, current, updateAvailable, manual, failed, ambiguous, newerInstalled, systemManaged
    public var title: String {
        switch self {
        case .unchecked: return "Not checked"
        case .current: return "Current in source"
        case .updateAvailable: return "Update available"
        case .manual: return "Needs attention"
        case .failed: return "Check failed"
        case .ambiguous: return "Ambiguous source"
        case .newerInstalled: return "Newer than catalog"
        case .systemManaged: return "Updated with macOS"
        }
    }
    public var isChecked: Bool { [.current, .updateAvailable, .manual, .newerInstalled].contains(self) }
}

public struct AppRecord: Codable, Identifiable, Equatable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var bundleID: String
    public var version: String
    public var build: String
    public var hasStoreReceipt: Bool
    public var sparkleFeed: String?
    public var source: UpdateSource?
    public var packageID: String?
    public var targetVersion: String?
    public var targetBuild: String?
    public var targetPackageVersion: String?
    public var targetSHA256: String?
    public var state: CheckState = .unchecked
    public var detail: String = "No supported source has checked this application."
    public var checkedAt: Date?
    public var automatic: Bool = false
    public var routeExecutable: String?
    public var routes: [UpdateRoute]?

    public init(name: String, path: String, bundleID: String, version: String, build: String = "", hasStoreReceipt: Bool = false, sparkleFeed: String? = nil) {
        self.name = name; self.path = path; self.bundleID = bundleID
        self.version = version; self.build = build
        self.hasStoreReceipt = hasStoreReceipt; self.sparkleFeed = sparkleFeed
    }
    public var hasUpdate: Bool { targetVersion != nil && [.updateAvailable, .manual].contains(state) }
    public var releaseIdentity: String { "\(source?.rawValue ?? "unknown"):\(packageID ?? ""):\(targetVersion ?? "")" + (targetPackageVersion.map { ":package=" + $0 } ?? "") + (targetBuild.map { ":build=" + $0 } ?? "") }
}

public struct SourceHealth: Codable, Identifiable {
    public var id: UpdateSource { source }
    public var source: UpdateSource
    public var executable: String?
    public var version: String
    public var available: Bool
    public var message: String
    public var error: String?
    // nil preserves the conservative meaning of reports written before this field.
    public var checkRequired: Bool?
    public var needsAttention: Bool { checkRequired != false && (!available || error != nil) }
    public init(source: UpdateSource, executable: String? = nil, version: String = "", available: Bool = false, message: String, error: String? = nil, checkRequired: Bool? = nil) {
        self.source = source; self.executable = executable; self.version = version
        self.available = available; self.message = message; self.error = error
        self.checkRequired = checkRequired
    }
}

public struct ScanResult: Codable {
    public var apps: [AppRecord]
    public var sources: [SourceHealth]
    public var warnings: [String]
    public var date: Date
    public var checkedCount: Int { apps.filter { $0.state.isChecked }.count }
    public init(apps: [AppRecord], sources: [SourceHealth], warnings: [String], date: Date = Date()) {
        self.apps = apps; self.sources = sources; self.warnings = warnings; self.date = date
    }
}

public struct Preferences: Codable {
    public var scanRoots: [String] = ["/Applications", NSHomeDirectory() + "/Applications"]
    public var disabledSources: Set<UpdateSource> = []
    public var ignoredPaths: Set<String> = []
    public var skippedReleases: [String: String] = [:]
    public var cleanupAfterSuccess = true
    public var preferredSources: [String: UpdateSource]?
    public var includeSystemApplications: Bool?
    public var inventoryRoots: [String] {
        scanRoots + ((includeSystemApplications ?? true) ? ["/System/Applications", "/System/Library/CoreServices/Applications"] : [])
    }
    public init() {}
    public func isEligible(_ app: AppRecord) -> Bool {
        app.state == .updateAvailable && app.automatic && app.targetVersion != nil
            && !ignoredPaths.contains(app.id) && skippedReleases[app.id] != app.releaseIdentity
    }
}

/// A route is evidence from one manager for one installed app instance.
/// Catalog suggestions alone must never be promoted to an executable route.
public struct UpdateRoute: Codable, Equatable, Identifiable {
    public var id: UpdateSource { source }
    public var source: UpdateSource
    public var packageID: String?
    public var targetVersion: String?
    public var targetBuild: String?
    public var targetPackageVersion: String?
    public var targetSHA256: String?
    public var state: CheckState
    public var detail: String
    public var checkedAt: Date?
    public var automatic: Bool
    public var executable: String?
    public init?(_ app: AppRecord) {
        guard let source = app.source else { return nil }
        self.source = source; packageID = app.packageID; targetVersion = app.targetVersion
        targetBuild = app.targetBuild; state = app.state; detail = app.detail
        targetPackageVersion = app.targetPackageVersion; targetSHA256 = app.targetSHA256
        checkedAt = app.checkedAt; automatic = app.automatic; executable = app.routeExecutable
    }
    public func applying(to original: AppRecord) -> AppRecord {
        var app = original
        app.source = source; app.packageID = packageID; app.targetVersion = targetVersion
        app.targetBuild = targetBuild; app.state = state; app.detail = detail
        app.targetPackageVersion = targetPackageVersion; app.targetSHA256 = targetSHA256
        app.checkedAt = checkedAt; app.automatic = automatic; app.routeExecutable = executable
        return app
    }
}

public enum SourceResolver {
    public static func resolve(_ original: AppRecord, routes: [UpdateRoute], preferred: UpdateSource?) -> AppRecord {
        // An App Store receipt is an ownership boundary, even if another
        // manager's stale registry claims the same path.
        let allowed = routes.filter { !original.hasStoreReceipt || $0.source == .appStore }
        var app = original
        app.routes = allowed
        if let chosen = allowed.first(where: { $0.source == preferred }) {
            return chosen.applying(to: app)
        }
        if allowed.count == 1 { return allowed[0].applying(to: app) }
        if allowed.count > 1 {
            app.source = nil; app.packageID = nil; app.targetVersion = nil; app.targetBuild = nil
            app.targetPackageVersion = nil; app.targetSHA256 = nil
            app.routeExecutable = nil; app.automatic = false; app.state = .ambiguous
            app.detail = "Several managers claim this application. Choose one verified route in Details before updating."
        }
        return app
    }
}

public enum TaskState: String, Codable {
    case queued, preflight, installing, verifying, succeeded, failed, deferred, canceled, interrupted
    public var title: String { rawValue.capitalized }
    public var isActive: Bool { [.queued, .preflight, .installing, .verifying].contains(self) }
}

public struct ActivityRecord: Codable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var appName: String
    public var appPath: String
    public var source: UpdateSource?
    public var fromVersion: String
    public var targetVersion: String
    public var state: TaskState
    public var message: String
    public var cleanupMessage: String?
    public init(app: AppRecord, state: TaskState, message: String) {
        appName = app.name; appPath = app.path; source = app.source
        fromVersion = app.version; targetVersion = app.targetVersion ?? "Unknown"
        self.state = state; self.message = message
    }
}

public struct PlannedUpdate: Identifiable {
    public var id: String { app.id }
    public var app: AppRecord
    public var preview: String
    public init(app: AppRecord, preview: String) { self.app = app; self.preview = preview }
}

public struct UpdaterError: LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public enum ReleaseComparison {
    /// Only comparable numeric marketing/build versions are ordered here.
    /// Non-numeric vendor versions require the source's own comparison.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        let pattern = #"^\d+(?:\.\d+)*$"#
        guard a.range(of: pattern, options: .regularExpression) != nil,
              b.range(of: pattern, options: .regularExpression) != nil else { return nil }
        var left = a.split(separator: ".").map(String.init)
        var right = b.split(separator: ".").map(String.init)
        while left.count < right.count { left.append("0") }
        while right.count < left.count { right.append("0") }
        for (l, r) in zip(left, right) {
            let result = l.compare(r, options: .numeric)
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }
    public static func satisfies(_ app: AppRecord, target: String) -> Bool {
        let parts = target.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2 {
            return compare(app.version, parts[0]) == .orderedSame && compare(app.build, parts[1]) == .orderedSame
        }
        return compare(app.version, target) == .orderedSame || compare(app.build, target) == .orderedSame
    }
}
