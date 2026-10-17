import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UpdaterCore

enum Screen: String, CaseIterable, Identifiable {
    case updates = "Updates", installed = "Installed Apps", appStore = "App Store", activity = "Activity", cleanup = "Cleanup", sources = "Sources", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .updates: return "arrow.triangle.2.circlepath"
        case .installed: return "square.grid.2x2"
        case .appStore: return "app.badge"
        case .activity: return "clock.arrow.circlepath"
        case .cleanup: return "sparkles"
        case .sources: return "externaldrive.connected.to.line.below"
        case .settings: return "slider.horizontal.3"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var screen: Screen? = .updates
    @Published var apps: [AppRecord] = []
    @Published var sources: [SourceHealth] = []
    @Published var warnings: [String] = []
    @Published var preferences = Preferences()
    @Published var history: [ActivityRecord] = []
    @Published var lastScan: Date?
    @Published var settingUp = false
    @Published private(set) var maintainingSources = false
    @Published private(set) var setupWasPrepared = false
    @Published var setupItems = DependencySetup.initialItems
    @Published var includeMacPortsInPreparation = false
    @Published var refreshingMetadata = false
    @Published var metadataRefreshItems: [SetupItem] = []
    @Published var lastMetadataRefreshAttempt: Date?
    private var startupStarted = false
    @Published var scanning = false
    @Published var preparing = false
    @Published var updating = false
    @Published var cancelRequested = false
    @Published var search = ""
    @Published var sourceFilter: UpdateSource?
    @Published var showIgnored = false
    @Published var selected = Set<String>()
    @Published var inspected: AppRecord?
    @Published var review: [PlannedUpdate] = []
    @Published var showingReview = false
    @Published var errorTitle = "Needs attention"
    @Published var error: String?
    @Published var status = "Ready for your first check"
    let store: LocalStore
    let cacheRoot: URL
    let runner: any CommandRunning
    private let setupLocate: (String) -> String?
    private let sourcePaths: [UpdateSource: String]?
    var busy: Bool { settingUp || refreshingMetadata || scanning || preparing || updating }
    var preventsQuit: Bool { updating || maintainingSources || refreshingMetadata }
    var setupNeedsAttention: Bool { setupItems.contains { $0.phase.needsAttention } }
    var setupActionTitle: String { setupWasPrepared ? (setupNeedsAttention ? "Retry Setup" : "Prepare Sources Again") : "Prepare Sources" }
    var metadataNeedsAttention: Bool {
        metadataRefreshItems.contains { item in
            item.phase.needsAttention && UpdateSource.allCases.contains { $0.toolName == item.id && !preferences.disabledSources.contains($0) }
        }
    }
    var sourceChecksNeedAttention: Bool { metadataNeedsAttention || sources.contains { !preferences.disabledSources.contains($0.source) && $0.needsAttention } }
    var eligible: [AppRecord] { apps.filter(preferences.isEligible) }
    var checkedCount: Int { apps.filter { $0.state.isChecked }.count }
    var checkableCount: Int { apps.filter { $0.state != .systemManaged }.count }
    var systemAppCount: Int { apps.filter { $0.state == .systemManaged }.count }
    var needsAttention: Int { apps.filter { $0.state != .systemManaged && (!$0.state.isChecked || $0.state == .manual) }.count }
    var filteredApps: [AppRecord] {
        apps.filter { app in
            let screenMatch: Bool
            switch screen ?? .updates {
            case .updates: screenMatch = app.hasUpdate || app.state == .ambiguous
            case .appStore: screenMatch = app.hasStoreReceipt
            default: screenMatch = true
            }
            let visible = showIgnored || (!preferences.ignoredPaths.contains(app.id) && preferences.skippedReleases[app.id] != app.releaseIdentity)
            return screenMatch && visible && (screen == .appStore || sourceFilter == nil || app.source == sourceFilter)
                && (search.isEmpty || app.name.localizedCaseInsensitiveContains(search) || app.bundleID.localizedCaseInsensitiveContains(search))
        }
    }

    init(runner: any CommandRunning = ProcessRunner(), sourcePaths: [UpdateSource: String]? = nil, setupLocate: @escaping (String) -> String? = ToolLocator.find) {
        self.runner = runner
        self.setupLocate = setupLocate
        self.sourcePaths = sourcePaths
        let override = ProcessInfo.processInfo.environment["UNIFIED_UPDATER_DATA_DIR"]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = override.map { URL(fileURLWithPath: $0) } ?? support.appendingPathComponent("UnifiedUpdater")
        store = LocalStore(root: root)
        cacheRoot = root.appendingPathComponent("SourceCache")
        do {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("preferences.json").path) {
                preferences = try store.load(Preferences.self, file: "preferences.json")
            }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("history.json").path) {
                history = store.recover(try store.load([ActivityRecord].self, file: "history.json"))
                try store.save(history, file: "history.json")
            }
        } catch { self.errorTitle = "Saved data couldn’t be read"; self.error = "Saved data could not be read. Existing files were retained. " + error.localizedDescription }
        sources = UpdateSource.allCases.map { source in
            let path = ToolLocator.find(source.toolName)
            return SourceHealth(source: source, executable: path, available: path != nil, message: path == nil ? "Not installed" : "Ready to check")
        }
    }

    func start() {
        guard !startupStarted else { return }
        startupStarted = true
        runSourceSetup(prepareTools: false)
    }

    func prepareSources() {
        runSourceSetup(prepareTools: true)
    }

    func refreshSourceMetadata() {
        guard !busy else { return }
        refreshingMetadata = true; metadataRefreshItems = SourceMetadataRefresh.initialItems
        selected = []; review = []; showingReview = false
        let prefs = preferences
        status = "Reading applications before refreshing source metadata…"
        Task { [self] in
            let inventory = await Task.detached {
                AppInventory().discover(roots: prefs.inventoryRoots, includeSystem: prefs.includeSystemApplications ?? true)
            }.value
            metadataRefreshItems = await SourceMetadataRefresh(runner: runner, cacheRoot: cacheRoot, locate: setupLocate)
                .refresh(inventory: inventory, disabledSources: prefs.disabledSources) { [weak self] items in
                    await MainActor.run {
                        self?.metadataRefreshItems = items
                        if let active = items.first(where: { $0.phase == .running }) { self?.status = active.message }
                    }
                }
            lastMetadataRefreshAttempt = Date()
            refreshingMetadata = false
            scan()
        }
    }

    private func runSourceSetup(prepareTools: Bool) {
        guard !busy else { return }
        let previousItems = prepareTools && setupWasPrepared && setupNeedsAttention ? setupItems : nil
        let prefs = preferences
        let includeMacPorts = includeMacPortsInPreparation
        maintainingSources = prepareTools; setupWasPrepared = prepareTools
        settingUp = true; setupItems = previousItems ?? DependencySetup.initialItems
        apps = []; selected = []; lastScan = nil
        status = prepareTools ? "Reading applications before source preparation…" : "Reading applications before source readiness checks…"
        Task { [self] in
            let inventory = await Task.detached {
                AppInventory().discover(roots: prefs.inventoryRoots, includeSystem: prefs.includeSystemApplications ?? true)
            }.value
            apps = inventory.apps; warnings = inventory.warnings
            let progress: ([SetupItem]) async -> Void = { [weak self] items in
                await MainActor.run {
                    self?.setupItems = items
                    if let active = items.first(where: { $0.phase == .running }) { self?.status = active.message }
                }
            }
            let setup = DependencySetup(runner: runner, locate: setupLocate)
            if prepareTools {
                setupItems = await setup.prepare(inventory: inventory, disabledSources: prefs.disabledSources, includeMacPorts: includeMacPorts, retrying: previousItems, progress: progress)
            } else {
                setupItems = await setup.checkReadiness(inventory: inventory, disabledSources: prefs.disabledSources, progress: progress)
            }
            settingUp = false; maintainingSources = false
            // A canceled authorization or offline source must not hide usable sources.
            scan()
        }
    }

    func scan() {
        guard !busy else { return }
        scanning = true; selected.removeAll(); status = "Reading applications and checking sources…"
        let prefs = preferences
        Task { [self] in
            let result = await ScanService(runner: runner, cacheRoot: cacheRoot, sourcePaths: sourcePaths).scan(preferences: prefs) { [weak self] partial in
                await MainActor.run {
                    self?.apps = partial.apps; self?.sources = partial.sources; self?.warnings = partial.warnings
                }
            }
            apps = result.apps; sources = result.sources; warnings = result.warnings; lastScan = result.date
            scanning = false
            status = "Checked \(checkedCount) of \(checkableCount) third-party apps · \(systemAppCount) managed by macOS · \(eligible.count) ready to update"
        }
    }

    func prepare(_ candidates: [AppRecord]) {
        guard !busy else { return }
        preparing = true; status = "Preparing the update plan…"
        Task { [self] in
            do {
                review = try await UpdateEngine(runner: runner, cacheRoot: cacheRoot, sourcePaths: sourcePaths).prepare(candidates, preferences: preferences)
                showingReview = true; status = "Review the selected updates"
            } catch { self.errorTitle = "The update plan changed"; self.error = Diagnostics.redact(error.localizedDescription); status = "Plan needs attention" }
            preparing = false
        }
    }
    func cancelReview() {
        showingReview = false; review = []
        status = "Update plan canceled. No installations started."
    }

    func startUpdates(requestQuit: Bool) {
        guard !busy, !review.isEmpty else { return }
        let plan = review
        let cleanup = preferences.cleanupAfterSuccess
        showingReview = false; review = []; updating = true; cancelRequested = false
        let engine = UpdateEngine(runner: runner, cacheRoot: cacheRoot, sourcePaths: sourcePaths)
        var ids: [String: UUID] = [:]
        for item in plan {
            let entry = ActivityRecord(app: item.app, state: .queued, message: "Waiting in the reviewed queue.")
            history.insert(entry, at: 0); ids[item.id] = entry.id
        }
        do { try saveHistory() } catch { self.error = error.localizedDescription; updating = false; return }
        Task { [self] in
            for item in plan {
                guard let id = ids[item.id] else { continue }
                if cancelRequested {
                    changeRecord(id, state: .canceled, message: "Canceled before installation started."); continue
                }
                if await UpdateEngine.isRunning(item.app) {
                    if requestQuit {
                        status = "Waiting for \(item.app.name) to quit…"
                        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == item.app.bundleID }.forEach { _ = $0.terminate() }
                        for _ in 0..<15 {
                            if !(await UpdateEngine.isRunning(item.app)) { break }
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                    }
                    if await UpdateEngine.isRunning(item.app) {
                        changeRecord(id, state: .deferred, message: "Still running. Save your work, close the app, and review a new update plan."); continue
                    }
                }
                if cancelRequested {
                    changeRecord(id, state: .canceled, message: "Canceled before installation started."); continue
                }
                status = "Updating \(item.app.name)…"
                var result = await engine.execute(item, cleanup: cleanup) { [weak self] stage, message in
                    guard let self else { throw UpdaterError("The update session ended.") }
                    try await MainActor.run {
                        if self.cancelRequested && stage == .installing { throw CancellationError() }
                        self.changeRecord(id, state: stage, message: message, persist: false)
                        try self.saveHistory()
                    }
                }
                result.id = id
                if let index = history.firstIndex(where: { $0.id == id }) { history[index] = result }
                do { try saveHistory() } catch { self.error = error.localizedDescription; cancelRequested = true }
            }
            updating = false; status = "Queue finished. Check Activity for verified results."
            // A new read-only check prevents old successful candidates remaining actionable.
            scan()
        }
    }

    private func changeRecord(_ id: UUID, state: TaskState, message: String, persist: Bool = true) {
        if let index = history.firstIndex(where: { $0.id == id }) {
            history[index].state = state; history[index].message = message
        }
        if persist { do { try saveHistory() } catch { self.error = error.localizedDescription; cancelRequested = true } }
    }
    private func saveHistory() throws { try store.save(Array(history.prefix(1000)), file: "history.json") }
    func savePreferences() {
        do { try store.save(preferences, file: "preferences.json") }
        catch { self.error = error.localizedDescription }
    }
    func toggleIgnored(_ app: AppRecord) {
        if !preferences.ignoredPaths.insert(app.id).inserted { preferences.ignoredPaths.remove(app.id) }
        selected.remove(app.id); savePreferences()
    }
    func skip(_ app: AppRecord) { preferences.skippedReleases[app.id] = app.releaseIdentity; selected.remove(app.id); savePreferences() }
    func addFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.title = "Choose application folders"; panel.prompt = "Add Folders"
        panel.message = "Choose folders containing applications. System apps are listed for reference and updated through macOS."
        if panel.runModal() == .OK {
            for url in panel.urls {
                let path = ToolLocator.canonicalPath(url.path)
                if !preferences.scanRoots.contains(path) { preferences.scanRoots.append(path) }
            }
            savePreferences(); invalidateInventory()
        }
    }
    func invalidateInventory() {
        apps = []; lastScan = nil; selected = []
        for index in sources.indices {
            sources[index].checkRequired = nil
            sources[index].message = "Scan settings changed. Check this source again."
        }
        status = "Scan configuration changed. Check for updates again."
    }
    func chooseSource(_ source: UpdateSource?, for app: AppRecord) {
        guard !busy, let index = apps.firstIndex(where: { $0.id == app.id }) else { return }
        if preferences.preferredSources == nil { preferences.preferredSources = [:] }
        preferences.preferredSources?[app.id] = source
        apps[index] = SourceResolver.resolve(app, routes: app.routes ?? [], preferred: source)
        selected.remove(app.id); savePreferences()
        inspected = apps[index]
    }
    func openSource(for app: AppRecord) {
        if let id = app.packageID, app.source == .appStore, (try? ToolLocator.validateStoreID(id)) != nil {
            NSWorkspace.shared.open(URL(string: "macappstore://itunes.apple.com/app/id" + id)!)
        } else if let id = app.packageID, app.source == .homebrew, (try? ToolLocator.validatePackageID(id)) != nil {
            NSWorkspace.shared.open(URL(string: "https://formulae.brew.sh/cask/" + id)!)
        } else if let id = app.packageID, app.source == .macPorts, (try? MacPortsAdapter.validateName(id)) != nil {
            NSWorkspace.shared.open(URL(string: "https://ports.macports.org/port/" + id + "/")!)
        } else if app.hasStoreReceipt { NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!) }
    }
    func exportReport() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "maccet-report.json"; panel.title = "Export Maccet report"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ReportExport.data(apps: apps, sources: sources, history: history, lastScan: lastScan)
            try data.write(to: url, options: .atomic)
        } catch { self.errorTitle = "Couldn’t export the report"; self.error = error.localizedDescription }
    }
}
