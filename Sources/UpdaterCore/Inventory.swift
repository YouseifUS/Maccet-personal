import Foundation

public struct InventoryResult {
    public var apps: [AppRecord]
    public var warnings: [String]
    /// A warning prevents absence of readable metadata from excluding a source.
    public var applicableSources: Set<UpdateSource> {
        guard warnings.isEmpty else { return Set(UpdateSource.allCases) }
        let thirdParty = apps.filter { $0.state != .systemManaged }
        var sources = Set<UpdateSource>()
        if thirdParty.contains(where: \.hasStoreReceipt) { sources.insert(.appStore) }
        if thirdParty.contains(where: { !$0.hasStoreReceipt }) { sources.formUnion([.homebrew, .macPorts]) }
        return sources
    }
    /// Candidate sources and installation policy are distinct: absence of a
    /// store receipt alone does not authorize installing an optional manager.
    public func applicableSources(macPortsAvailable: Bool, includeMacPorts: Bool = false) -> Set<UpdateSource> {
        var sources = applicableSources
        let owned = apps.contains { app in
            app.state != .systemManaged && !app.hasStoreReceipt
                && (app.source == .macPorts || app.routes?.contains { $0.source == .macPorts } == true)
        }
        if !macPortsAvailable && !includeMacPorts && !owned { sources.remove(.macPorts) }
        return sources
    }
}

public struct AppInventory {
    public init() {}
    public func discover(roots: [String], includeSystem: Bool = false) -> InventoryResult {
        let fm = FileManager.default
        var apps: [String: AppRecord] = [:]
        var warnings: [String] = []
        for root in Set(roots) {
            let url = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
            if !fm.fileExists(atPath: url.path) {
                if url.path != NSHomeDirectory() + "/Applications" { warnings.append("Folder not found: \(url.path)") }
                continue
            }
            guard includeSystem || !Self.isSystemPath(url.path) else { warnings.append("System folders are excluded: \(url.path)"); continue }
            if url.pathExtension.lowercased() == "app" {
                if let app = try? read(url.path, allowSystem: includeSystem) { apps[app.id] = app }
                else { warnings.append("Cannot read application metadata: \(url.lastPathComponent)") }
                continue
            }
            // Safari's public /Applications link can carry UF_HIDDEN. Do not
            // exclude hidden app bundles just because Finder hides the link.
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { path, error in
                warnings.append("Cannot read \(path.lastPathComponent): \(error.localizedDescription)"); return true
            }) else { warnings.append("Cannot read folder: \(url.path)"); continue }
            for case let item as URL in enumerator {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let canDescend = values?.isDirectory == true && values?.isSymbolicLink != true
                if item.pathExtension.lowercased() == "app" {
                    if canDescend { enumerator.skipDescendants() }
                    let canonical = item.resolvingSymlinksInPath().standardizedFileURL
                    if !includeSystem && Self.isSystemPath(canonical.path) { continue }
                    if let app = try? read(canonical.path, allowSystem: includeSystem) { apps[app.id] = app }
                    else { warnings.append("Cannot read application metadata: \(item.lastPathComponent)") }
                } else if item.lastPathComponent.hasPrefix(".") || item.lastPathComponent == "node_modules" {
                    if canDescend { enumerator.skipDescendants() }
                }
            }
        }
        return InventoryResult(apps: apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, warnings: warnings)
    }
    public func read(_ path: String, allowSystem: Bool = false) throws -> AppRecord {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard allowSystem || !Self.isSystemPath(url.path) else { throw UpdaterError("System apps are outside this release's update scope.") }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw UpdaterError("Missing application identity at \(url.lastPathComponent).")
        }
        var app = AppRecord(
            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent,
            path: url.path, bundleID: bundleID,
            version: info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "Unknown",
            build: info["CFBundleVersion"] as? String ?? "",
            hasStoreReceipt: FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path),
            sparkleFeed: info["SUFeedURL"] as? String
        )
        if Self.isSystemPath(url.path) {
            app.state = .systemManaged
            app.detail = "Included in the inventory. This app is maintained through macOS Software Update and is excluded from third-party package updates."
        }
        return app
    }
    public static func isSystemPath(_ path: String) -> Bool { path == "/System" || path.hasPrefix("/System/") }
}
