import Foundation

/// Refresh requests only use installed tools; installation and tool upgrades
/// remain explicit preparation operations with their own results.
public struct SourceMetadataRefresh {
    public static var initialItems: [SetupItem] {
        UpdateSource.allCases.map { SetupItem(id: $0.toolName, title: $0.title) }
    }
    private let runner: any CommandRunning
    private let locate: (String) -> String?
    private let cacheRoot: URL?
    private let homebrewAPIEnabled: Bool
    public init(runner: any CommandRunning = ProcessRunner(), cacheRoot: URL? = nil,
                locate: @escaping (String) -> String? = ToolLocator.find,
                homebrewAPIEnabled: Bool = (ProcessInfo.processInfo.environment["HOMEBREW_NO_INSTALL_FROM_API"] ?? "").isEmpty) {
        self.runner = runner; self.locate = locate; self.cacheRoot = cacheRoot; self.homebrewAPIEnabled = homebrewAPIEnabled
    }
    public func refresh(inventory: InventoryResult? = nil, disabledSources: Set<UpdateSource> = [],
                        progress: @escaping ([SetupItem]) async -> Void = { _ in }) async -> [SetupItem] {
        var items = Self.initialItems
        let requirements = inventory ?? InventoryResult(apps: [], warnings: ["Inventory is incomplete"])
        let applicable = requirements.applicableSources(macPortsAvailable: locate("port") != nil)
        func report(_ index: Int, _ phase: SetupPhase, _ message: String) async {
            items[index].phase = phase; items[index].message = Diagnostics.redact(message)
            await progress(items)
        }
        for (index, source) in UpdateSource.allCases.enumerated() {
            if disabledSources.contains(source) {
                await report(index, .disabled, "\(source.title) is disabled in Settings."); continue
            }
            guard applicable.contains(source) else {
                await report(index, .notRequired, "No metadata refresh is required for this inventory and installed-source choice."); continue
            }
            if source == .appStore {
                await report(index, .notRequired, "App Store has no local package index. Application scans query its live service."); continue
            }
            guard let executable = locate(source.toolName) else {
                await report(index, .unavailable, "Install or update this source tool through Prepare Sources, then refresh its metadata."); continue
            }
            await report(index, .running, "Refreshing \(source.title) metadata…")
            do {
                let canonical = ToolLocator.canonicalPath(executable)
                var environment = HomebrewAdapter(executable: executable, runner: runner, cacheRoot: cacheRoot).environment
                let versionOutput = try await runner.run(executable, source.versionArguments, environment: environment, timeout: 20).checked()
                let version = try SourceToolVersion.validated(versionOutput, source: source)
                guard locate(source.toolName).map(ToolLocator.canonicalPath) == canonical else { throw UpdaterError("The source tool changed during the metadata request. Retry after reviewing Sources.") }
                items[index].executablePath = canonical; items[index].version = version
                if source == .homebrew {
                    guard homebrewAPIEnabled else { throw UpdaterError("Metadata-only refresh requires Homebrew API mode. Git-tap mode needs a separately requested source-tool preparation; no broader update was started.") }
                    // `outdated` is an API auto-update command. Disable Git/tool
                    // auto-update while forcing an immediate API-cache check.
                    environment["HOMEBREW_FORCE_API_AUTO_UPDATE"] = "1"
                    environment["HOMEBREW_API_AUTO_UPDATE_SECS"] = "0"
                    environment["HOMEBREW_API_UPDATED"] = ""
                    let result = try await runner.run(executable, ["outdated", "--cask", "--greedy", "--json=v2"], environment: environment, timeout: 180)
                    _ = try HomebrewAdapter.parseOutdated(result.checked())
                    let context = result.errorOutput.isEmpty ? "" : " Diagnostic: " + Diagnostics.redact(result.errorOutput).prefixString(1500)
                    await report(index, .ready, "Installed casks checked with an API refresh request. Homebrew can reuse verified cached data if upstream is unavailable; Git taps were not synchronized." + context)
                } else {
                    guard executable == "/opt/local/bin/port" else { throw UpdaterError("Only the standard MacPorts location supports authorized index refresh.") }
                    _ = try await runner.run("/bin/bash", [DependencySetup.scriptURL.path, "ports-sync"], environment: environment, timeout: nil).checked()
                    await report(index, .ready, "MacPorts port definitions synchronized. Tool-base updates remain a separate preparation action.")
                }
            } catch { await report(index, .failed, error.localizedDescription) }
        }
        return items
    }
}
