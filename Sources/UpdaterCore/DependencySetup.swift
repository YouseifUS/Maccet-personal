import Foundation

public enum SetupPhase: String {
    case waiting, running, ready, unavailable, failed, disabled, notRequired
    public var needsAttention: Bool { self == .unavailable || self == .failed }
    public var title: String {
        switch self {
        case .waiting: return "Pending"
        case .running: return "In progress"
        case .ready: return "Ready"
        case .unavailable: return "Unavailable"
        case .failed: return "Failed"
        case .disabled: return "Disabled"
        case .notRequired: return "Not needed"
        }
    }
}

public struct SetupItem: Identifiable {
    public var id: String
    public var title: String
    public var phase: SetupPhase = .waiting
    public var message: String = "Waiting"
    public var dependencyFor: UpdateSource? = nil
    public var executablePath: String? = nil
    public var version: String? = nil
    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// Separates read-only readiness checks from explicitly requested maintenance.
public struct DependencySetup {
    public static var initialItems: [SetupItem] {
        [SetupItem(id: "tools", title: "Apple developer tools"),
         SetupItem(id: "brew", title: "Homebrew"),
         SetupItem(id: "port", title: "MacPorts"),
         SetupItem(id: "mas", title: "App Store helper (mas)")]
    }
    public static var scriptURL: URL {
        Bundle.module.url(forResource: "prepare-sources", withExtension: "sh")!
    }
    private let runner: any CommandRunning
    private let locate: (String) -> String?
    private let osMajor: Int
    private let architecture: String
    public init(runner: any CommandRunning = ProcessRunner(),
                locate: @escaping (String) -> String? = ToolLocator.find,
                osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                architecture: String = DependencySetup.nativeArchitecture) {
        self.runner = runner; self.locate = locate; self.osMajor = osMajor; self.architecture = architecture
    }
    public static var nativeArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    private let environment = ["HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_AUTO_UPDATE": "1",
                               "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1",
                               "HOMEBREW_NO_ENV_HINTS": "1", "NONINTERACTIVE": "1"]
    private func command(_ executable: String, _ arguments: [String], timeout: TimeInterval? = 120) async throws -> String {
        try await runner.run(executable, arguments, environment: environment, timeout: timeout).checked()
    }
    private func script(_ arguments: [String]) async throws {
        // Installer processes must finish; never kill a privileged installer on a timer.
        _ = try await command("/bin/bash", [Self.scriptURL.path] + arguments, timeout: nil)
    }
    private func probeVersion(_ executable: String, tool: String) async throws -> String {
        let version = try await command(executable, tool == "brew" ? ["--version"] : ["version"], timeout: 20)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { throw UpdaterError("\(tool) did not report a version.") }
        if tool == "mas" {
            guard let major = Int(version.split(separator: ".").first ?? ""), major >= 7 else {
                throw UpdaterError("mas 7 or later is required. The installed helper reported: " + version)
            }
        }
        return version
    }
    public func prepare(inventory: InventoryResult? = nil, disabledSources: Set<UpdateSource> = [], retrying previousItems: [SetupItem]? = nil, progress: @escaping ([SetupItem]) async -> Void = { _ in }) async -> [SetupItem] {
        await run(inventory: inventory, disabledSources: disabledSources, retrying: previousItems, prepareTools: true, progress: progress)
    }
    public func checkReadiness(inventory: InventoryResult? = nil, disabledSources: Set<UpdateSource> = [], progress: @escaping ([SetupItem]) async -> Void = { _ in }) async -> [SetupItem] {
        await run(inventory: inventory, disabledSources: disabledSources, retrying: nil, prepareTools: false, progress: progress)
    }
    private func run(inventory: InventoryResult?, disabledSources: Set<UpdateSource>, retrying previousItems: [SetupItem]?, prepareTools: Bool, progress: @escaping ([SetupItem]) async -> Void) async -> [SetupItem] {
        // Reuse successful preparation only for an explicit retry in this session.
        var items = Self.initialItems.map { initial in
            guard let ready = previousItems?.first(where: { $0.id == initial.id && $0.phase == .ready }) else { return initial }
            if initial.id != "tools" {
                guard let path = ready.executablePath, let executable = locate(initial.id),
                      ToolLocator.canonicalPath(executable) == path else { return initial }
            }
            var reused = ready
            reused.dependencyFor = nil
            return reused
        }
        func report(_ index: Int, _ phase: SetupPhase, _ message: String) async {
            items[index].phase = phase; items[index].message = Diagnostics.redact(message)
            await progress(items)
        }
        func confirmReady(_ index: Int, executable: String) async throws {
            let canonicalPath = ToolLocator.canonicalPath(executable)
            let version = try await probeVersion(executable, tool: items[index].id)
            guard locate(items[index].id).map(ToolLocator.canonicalPath) == canonicalPath else {
                throw UpdaterError("The tool location changed during its readiness check. Retry Setup.")
            }
            items[index].executablePath = canonicalPath
            items[index].version = Diagnostics.redact(version)
            await report(index, .ready, items[index].id == "mas" ? "mas " + version : version)
        }
        // Missing metadata cannot prove a source unnecessary. Preserve the
        // conservative enabled-source behavior for incomplete or absent inventory.
        let applicableSources = inventory?.applicableSources ?? Set(UpdateSource.allCases)
        let requestedSources = applicableSources.subtracting(disabledSources)
        func skip(_ index: Int, _ source: UpdateSource) async {
            if disabledSources.contains(source) { await report(index, .disabled, "\(source.title) is disabled in Settings.") }
            else { await report(index, .notRequired, "No discovered application requires this source.") }
        }
        let needsMas = requestedSources.contains(.appStore)
        let masUsesPorts = needsMas && locate("mas") == "/opt/local/bin/mas"
        let needsBrew = requestedSources.contains(.homebrew) || (prepareTools && needsMas && !masUsesPorts)
        let needsPorts = requestedSources.contains(.macPorts) || (prepareTools && masUsesPorts)
        // Presence alone cannot validate a cached success. Probe only required
        // tools; healthy results skip maintenance, stale results use normal repair.
        // Finish these checks before publishing cached ready states in progress.
        for (index, needed) in [(1, needsBrew), (2, needsPorts), (3, needsMas)] where needed && items[index].phase == .ready {
            do {
                guard let executable = locate(items[index].id) else { throw UpdaterError("Tool is no longer installed.") }
                let version = try await probeVersion(executable, tool: items[index].id)
                guard locate(items[index].id).map(ToolLocator.canonicalPath) == items[index].executablePath else {
                    throw UpdaterError("Tool location changed.")
                }
                items[index].version = Diagnostics.redact(version)
                items[index].message = Diagnostics.redact(items[index].id == "mas" ? "mas " + version : version)
            } catch {
                items[index] = Self.initialItems[index]
            }
        }
        if !needsBrew { await skip(1, .homebrew) }
        else if !requestedSources.contains(.homebrew) { items[1].dependencyFor = .appStore }
        if !needsPorts { await skip(2, .macPorts) }
        else if !requestedSources.contains(.macPorts) { items[2].dependencyFor = .appStore }
        if !needsMas { await skip(3, .appStore) }
        guard needsBrew || needsPorts || needsMas else {
            await report(0, .notRequired, "No source requires developer tools for this inventory.")
            return items
        }
        if !prepareTools {
            if needsBrew || needsPorts {
                await report(0, .running, "Checking Apple developer tools…")
                do {
                    // Developer-tool shims can request installation when tools are
                    // absent. Read only the selected directory during launch checks.
                    let directory = try await command("/usr/bin/xcode-select", ["--print-path"], timeout: 20)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard directory.hasPrefix("/") else { throw UpdaterError("No developer tools directory is selected.") }
                    await report(0, .ready, "Developer tools directory is selected. Preparation checks the compiler before maintenance.")
                } catch {
                    await report(0, .unavailable, "Apple developer tools are unavailable. Choose Prepare Sources to request Apple's installer. " + error.localizedDescription)
                }
            } else {
                await report(0, .notRequired, "App Store readiness is checked directly; developer tools are checked when source maintenance needs them.")
            }
            // A missing prerequisite must not hide the readiness of working tools.
            // This path never installs, refreshes metadata, or requests authorization.
            for (index, needed) in [(1, needsBrew), (2, needsPorts), (3, needsMas)] where needed {
                guard let executable = locate(items[index].id) else {
                    await report(index, .unavailable, "Not installed. Choose Prepare Sources to install this tool.")
                    continue
                }
                await report(index, .running, "Checking \(items[index].title) readiness…")
                do { try await confirmReady(index, executable: executable) }
                catch { await report(index, .failed, error.localizedDescription) }
            }
            return items
        }
        await report(0, .running, "Checking Apple developer tools…")
        do {
            _ = try await command("/usr/bin/xcrun", ["--find", "clang"], timeout: 20)
            await report(0, .ready, "Developer tools are available")
        } catch {
            // Apple owns the download, license, and installation UI.
            _ = try? await command("/usr/bin/xcode-select", ["--install"], timeout: 20)
            await report(0, .failed, "Complete Apple's developer tools installer, then choose Retry Setup.")
            for index in 1..<items.count where items[index].phase != .disabled && items[index].phase != .notRequired {
                await report(index, .failed, "Waiting for Apple developer tools. Retry Setup after installation.")
            }
            return items
        }
        var brew: String? = items[1].phase == .ready ? locate("brew") : nil
        if needsBrew && items[1].phase != .ready {
            await report(1, .running, locate("brew") == nil ? "Downloading and installing Homebrew…" : "Updating Homebrew…")
            do {
                if locate("brew") == nil {
                    guard architecture == "arm64" else {
                        throw UpdaterError("Homebrew's automatic package installer requires Apple Silicon. Install Homebrew from brew.sh on this Intel Mac, then Retry Setup.")
                    }
                    try await installPackage(repository: "Homebrew/brew", tool: "brew")
                }
                guard let executable = locate("brew") else { throw UpdaterError("Homebrew installation finished but brew was not found in a supported location.") }
                try await script(["brew-update", executable])
                try await confirmReady(1, executable: executable)
                brew = executable
            } catch { await report(1, .failed, error.localizedDescription) }
        }

        if needsPorts && items[2].phase != .ready {
            await report(2, .running, locate("port") == nil ? "Downloading and installing MacPorts…" : "Updating MacPorts and its index…")
            do {
                if locate("port") == nil { try await installPackage(repository: "macports/macports-base", tool: "port") }
                guard let executable = locate("port") else { throw UpdaterError("MacPorts installation finished but /opt/local/bin/port was not found.") }
                try await script(["ports-update"])
                try await confirmReady(2, executable: executable)
            } catch { await report(2, .failed, error.localizedDescription) }
        }

        if needsMas && items[3].phase != .ready {
            await report(3, .running, "Installing or updating the App Store helper…")
            do {
                // Keep an existing MacPorts-owned mas under that manager.
                if locate("mas") == "/opt/local/bin/mas" {
                    guard items[2].phase == .ready else { throw UpdaterError("MacPorts setup must succeed before updating its mas helper.") }
                    try await script(["ports-mas-update"])
                } else {
                    guard let brew else { throw UpdaterError("Homebrew setup must succeed before installing or updating mas.") }
                    let installed = try await runner.run(brew, ["list", "--formula", "--versions", "mas"], environment: environment, timeout: 30)
                    let action = installed.status == 0 && !installed.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "mas-update" : "mas-install"
                    try await script([action, brew])
                }
                guard let executable = locate("mas") else { throw UpdaterError("mas could not be found after installation.") }
                try await confirmReady(3, executable: executable)
            } catch { await report(3, .failed, error.localizedDescription) }
        }

        return items
    }

    public struct InstallerAsset: Decodable {
        public var name: String
        public var browser_download_url: String
        public var digest: String?
    }
    private struct Release: Decodable { var assets: [InstallerAsset] }
    public static func selectInstaller(_ json: Data, repository: String, tool: String, osMajor: Int) throws -> InstallerAsset {
        guard (repository == "Homebrew/brew" && tool == "brew") || (repository == "macports/macports-base" && tool == "port") else {
            throw UpdaterError("Unsupported installer source.")
        }
        let assets = try JSONDecoder().decode(Release.self, from: json).assets
        let matches = assets.filter { asset in
            if tool == "brew" { return asset.name == "Homebrew.pkg" }
            return asset.name.range(of: "^MacPorts-[0-9]+(?:\\.[0-9]+)*-" + String(osMajor) + "-[A-Za-z]+\\.pkg$", options: .regularExpression) != nil
        }
        guard matches.count == 1, let asset = matches.first,
              asset.browser_download_url.hasPrefix("https://github.com/" + repository + "/releases/download/"),
              URL(string: asset.browser_download_url)?.lastPathComponent == asset.name,
              asset.digest?.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw UpdaterError("No uniquely identified, checksummed official installer is available for this Mac. See the source's setup documentation.")
        }
        return asset
    }
    private func installPackage(repository: String, tool: String) async throws {
        let metadata = try await command("/usr/bin/curl", ["--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--max-time", "90", "https://api.github.com/repos/" + repository + "/releases/latest"])
        let asset = try Self.selectInstaller(Data(metadata.utf8), repository: repository, tool: tool, osMajor: osMajor)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("maccet-installer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = folder.appendingPathComponent(asset.name)
        _ = try await command("/usr/bin/curl", ["--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--max-time", "1800", "--output", package.path, asset.browser_download_url], timeout: 1810)
        let digest = String(asset.digest!.dropFirst("sha256:".count))
        let actual = try await command("/usr/bin/shasum", ["-a", "256", package.path])
        guard actual.split(whereSeparator: \.isWhitespace).first.map(String.init) == digest else { throw UpdaterError("The downloaded installer checksum did not match. Installation was blocked.") }
        _ = try await command("/usr/sbin/spctl", ["--assess", "--type", "install", package.path])
        try await script(["install-package", package.path, digest])
    }
}
