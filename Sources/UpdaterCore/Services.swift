import Foundation
import AppKit

public struct ScanService {
    public let runner: any CommandRunning
    public let cacheRoot: URL?
    public let sourcePaths: [UpdateSource: String]
    public var sparkleChecker = SparkleCheck()
    public var vendorChecker = OfficialVendorService()
    public var discoveryCatalog: AuthenticatedSourceMappingCatalog?
    public init(runner: any CommandRunning = ProcessRunner(), cacheRoot: URL? = nil, sourcePaths: [UpdateSource: String]? = nil) {
        self.runner = runner; self.cacheRoot = cacheRoot
        self.sourcePaths = sourcePaths ?? ToolLocator.defaultSources()
    }
    private func installableSparkleRoute(_ observation: SparkleObservation, app: AppRecord, release: SparkleSelectedRelease, review: DiscoveryChannelReview?) -> SparkleInstallRoute? {
        guard observation.state == .updateAvailable,
              let publicKeyFingerprint = SparkleTrustKey.ed25519PublicKeyFingerprint(at: app.path),
              release.edSignature != nil,
              release.archiveURL.hasSuffix(".zip"),
              release.installationType == nil || release.installationType == "default",
              let archiveURL = URL(string: release.archiveURL),
              (try? SparkleFeedLoader.validateURL(archiveURL)) != nil else { return nil }
        return SparkleInstallRoute(feedURL: app.sparkleFeed!, archiveURL: release.archiveURL, archiveLength: release.archiveLength,
                                   edSignature: release.edSignature!, targetVersion: release.version, targetBuild: release.build,
                                   channel: release.channel, channelReview: review, publicKeyFingerprint: publicKeyFingerprint)
    }
    public func scan(preferences: Preferences, onPartial: ((ScanResult) async -> Void)? = nil) async -> ScanResult {
        let inventory = await Task.detached { AppInventory().discover(roots: preferences.inventoryRoots, includeSystem: preferences.includeSystemApplications ?? true) }.value
        let updateInventory = inventory.apps.filter { $0.state != .systemManaged }
        let applicableSources = inventory.applicableSources(macPortsAvailable: sourcePaths[.macPorts] != nil)
        var result = ScanResult(apps: inventory.apps, sources: [], warnings: inventory.warnings)
        var routes: [String: [UpdateRoute]] = [:]
        await onPartial?(result)
        for source in UpdateSource.allCases {
            if preferences.disabledSources.contains(source) {
                result.sources.append(SourceHealth(source: source, executable: sourcePaths[source], available: sourcePaths[source] != nil, message: "Disabled in Settings.", checkRequired: false)); continue
            }
            if !applicableSources.contains(source) {
                let message = source == .macPorts && sourcePaths[source] == nil
                    ? "Optional MacPorts is not installed. This source was not checked. Include MacPorts in Sources preparation if you use it."
                    : "Not needed for this inventory. No update check was performed."
                result.sources.append(SourceHealth(source: source, executable: sourcePaths[source], available: sourcePaths[source] != nil, message: message, checkRequired: false)); continue
            }
            guard let executable = sourcePaths[source] else {
                result.sources.append(SourceHealth(source: source, message: "\(source.title) not installed. Open Sources and choose Prepare Sources.", checkRequired: true)); continue
            }
            var health = SourceHealth(source: source, executable: executable, available: true, message: "Available", checkRequired: true)
            do {
                let output = try await runner.run(executable, source.versionArguments, environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"], timeout: 15).checked()
                health.version = try SourceToolVersion.validated(output, source: source)
                let records: [AppRecord]
                if source == .homebrew {
                    records = try await HomebrewAdapter(executable: executable, runner: runner, cacheRoot: cacheRoot).check(apps: updateInventory)
                    health.message = "Managed casks checked, including self-updating casks. Catalog metadata may lag upstream releases."
                } else if source == .macPorts {
                    records = try await MacPortsAdapter(executable: executable, runner: runner).check(apps: updateInventory)
                    health.message = "Installed-file ownership checked against the local ports index. Choose Prepare Sources in Sources to refresh a stale index."
                } else {
                    records = try await AppStoreAdapter(executable: executable, runner: runner).check(apps: updateInventory)
                    health.message = "Receipt, bundle identity, and installed path matched. Apple's lookup may lag store availability."
                }
                for app in records where app.source == source {
                    if let route = UpdateRoute(app) { routes[app.id, default: []].append(route) }
                }
                result.apps = inventory.apps.map { SourceResolver.resolve($0, routes: routes[$0.id] ?? [], preferred: preferences.preferredSources?[$0.id]) }
            } catch {
                health.error = Diagnostics.redact(error.localizedDescription)
                health.message = "Check incomplete. Open the source or retry."
                for index in result.apps.indices where source == .appStore && result.apps[index].hasStoreReceipt && result.apps[index].state != .systemManaged {
                    result.apps[index].source = .appStore; result.apps[index].state = .failed
                    result.apps[index].detail = health.error ?? "Source check failed."
                }
            }
            result.sources.append(health)
            await onPartial?(result)
        }
        if preferences.checkOfficialVendorReleases == true {
            var checks = 0
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            for index in result.apps.indices where OfficialVendorService.recognizes(result.apps[index]) && result.apps[index].state != .systemManaged
                && !result.apps[index].hasStoreReceipt && (result.apps[index].routes ?? []).isEmpty {
                let observation: VendorObservation
                if checks >= 8 || ContinuousClock.now >= deadline || Task.isCancelled {
                    observation = VendorObservation(state: .unsupported, message: "Vendor scan request/time budget reached or canceled. This copy was not requested.")
                } else {
                    checks += 1
                    observation = await vendorChecker.check(result.apps[index], review: preferences.discoveryChannelReviews?[result.apps[index].id])
                }
                result.apps[index].vendorObservation = observation
                result.apps[index].detail = observation.message; result.apps[index].automatic = false
                switch observation.state {
                case .updateAvailable:
                    result.apps[index].targetVersion = observation.targetVersion; result.apps[index].state = .manual; result.apps[index].checkedAt = observation.date
                case .current: result.apps[index].state = .current; result.apps[index].checkedAt = observation.date
                case .unsupported: result.apps[index].state = .unchecked
                case .failed: result.apps[index].state = .failed
                }
                await onPartial?(result)
            }
        }
        // Embedded-feed observations cannot displace a manager or store receipt.
        // A separately trusted local key can promote an observation to a narrow
        // installable route; the observation alone never creates that route.
        var feedCount = 0
        let feedDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        for index in result.apps.indices where preferences.checkEmbeddedSparkleFeeds == true && result.apps[index].sparkleFeed != nil
            && !result.apps[index].hasStoreReceipt && result.apps[index].state != .systemManaged
            && result.apps[index].vendorObservation == nil && (result.apps[index].routes ?? []).isEmpty {
            let observation: SparkleObservation
            var selectedRelease: SparkleSelectedRelease?
            if Task.isCancelled {
                observation = SparkleObservation(state: .failed, message: "Sparkle check canceled.")
            } else if feedCount >= 16 || ContinuousClock.now >= feedDeadline {
                observation = SparkleObservation(state: .unsupported, message: "The Sparkle scan request/time budget was reached. This feed was not requested; choose a smaller scan folder to include it.")
            } else {
                feedCount += 1
                let review = preferences.discoveryChannelReviews?[result.apps[index].id]
                let check = await sparkleChecker.checkWithRelease(result.apps[index], review: review)
                observation = check.observation; selectedRelease = check.release
            }
            result.apps[index].sparkleObservation = observation
            result.apps[index].detail = observation.message
            result.apps[index].automatic = false
            switch observation.state {
            case .updateAvailable:
                if let release = selectedRelease, let route = installableSparkleRoute(observation, app: result.apps[index], release: release, review: preferences.discoveryChannelReviews?[result.apps[index].id]) {
                    result.apps[index].sparkleInstallRoute = route
                    result.apps[index].state = .updateAvailable
                    result.apps[index].automatic = true
                    result.apps[index].targetVersion = observation.version
                    result.apps[index].targetBuild = observation.build
                    result.apps[index].checkedAt = observation.date
                    result.apps[index].detail = "Sparkle update available with a local EdDSA trust key. Review before installing."
                } else {
                    result.apps[index].state = .manual
                    result.apps[index].targetVersion = observation.version
                    result.apps[index].targetBuild = observation.build
                    result.apps[index].checkedAt = observation.date
                }
            case .current:
                result.apps[index].state = .current
                result.apps[index].checkedAt = observation.date
            case .unsupported: result.apps[index].state = .unchecked
            case .failed: result.apps[index].state = .failed
            }
            await onPartial?(result)
        }
        if let discoveryCatalog {
            for index in result.apps.indices {
                result.apps[index].catalogCandidates = SourceDiscoveryService.candidates(for: result.apps[index], catalog: discoveryCatalog, review: preferences.discoveryChannelReviews?[result.apps[index].id])
            }
        }
        result.date = Date()
        return result
    }
}

public struct UpdateEngine {
    public let runner: any CommandRunning
    public let cacheRoot: URL?
    public let sourcePaths: [UpdateSource: String]
    public var sparkleFeedLoader: any SparkleFeedLoading
    public var sparkleInstaller: any SparkleInstalling
    public var isRunning: (AppRecord) async -> Bool
    public init(runner: any CommandRunning = ProcessRunner(), cacheRoot: URL? = nil, sourcePaths: [UpdateSource: String]? = nil, sparkleFeedLoader: any SparkleFeedLoading = SparkleFeedLoader(), sparkleInstaller: any SparkleInstalling = SparkleInstaller(), isRunning: @escaping (AppRecord) async -> Bool = Self.isRunning) {
        self.runner = runner; self.cacheRoot = cacheRoot
        self.sourcePaths = sourcePaths ?? ToolLocator.defaultSources()
        self.sparkleFeedLoader = sparkleFeedLoader
        self.sparkleInstaller = sparkleInstaller
        self.isRunning = isRunning
    }

    public func prepare(_ apps: [AppRecord], preferences: Preferences) async throws -> [PlannedUpdate] {
        var seen = Set<String>()
        var plans: [PlannedUpdate] = []
        for app in apps where seen.insert(app.id).inserted {
            guard preferences.isEligible(app) else { throw UpdaterError("\(app.name) is no longer eligible for automatic updating.") }
            var plan = PlannedUpdate(app: app, preview: "")
            try plan.reviewedSignature.validate(at: app.path)
            if let route = app.sparkleInstallRoute {
                let release = try await revalidateSparkle(app, route: route)
                try plan.reviewedSignature.validate(at: app.path)
                plan.preview = "Sparkle update to \(release.version) (build \(release.build)) from the embedded feed.\n\n" + plan.reviewedSignature.reviewSummary
                plans.append(plan); continue
            }
            try plan.validateReviewedTool()
            _ = try await revalidate(app)
            let preview: String
            if app.source == .homebrew {
                preview = try await brew(for: app).preview(app)
            } else if app.source == .macPorts {
                preview = try await MacPortsAdapter(executable: app.routeExecutable!, runner: runner).preview(app)
            } else {
                preview = "Update \(app.name) through App Store to \(app.targetVersion ?? ""). macOS will ask for administrator authorization. Save your work and close the app before continuing."
            }
            try plan.reviewedSignature.validate(at: app.path)
            try plan.validateReviewedTool()
            plan.preview = Diagnostics.redact(preview) + "\n\n" + plan.reviewedSignature.reviewSummary
            plans.append(plan)
        }
        guard !plans.isEmpty else { throw UpdaterError("There are no eligible updates in this selection.") }
        return plans
    }

    private func revalidateSparkle(_ app: AppRecord, route: SparkleInstallRoute) async throws -> SparkleSelectedRelease {
        guard let feedURL = URL(string: route.feedURL),
              let fingerprint = SparkleTrustKey.ed25519PublicKeyFingerprint(at: app.path),
              fingerprint == route.publicKeyFingerprint else {
            throw UpdaterError("The Sparkle trust key or feed URL changed. Rescan and review a new plan.")
        }
        let data = try await sparkleFeedLoader.load(feedURL)
        guard let release = try SparkleCheck(loader: sparkleFeedLoader).selectedRelease(data, app: app, review: route.channelReview),
              release.version == route.targetVersion, release.build == route.targetBuild,
              release.edSignature == route.edSignature, release.archiveURL == route.archiveURL,
              release.channel == route.channel,
              release.installationType == nil || release.installationType == "default",
              release.archiveURL.hasSuffix(".zip") else {
            throw UpdaterError("The Sparkle target release or reviewed channel changed. Rescan and review a new plan.")
        }
        return release
    }

    public func revalidate(_ app: AppRecord, isolatedCache: URL? = nil) async throws -> AppRecord {
        guard let executable = app.routeExecutable, let source = app.source else { throw UpdaterError("Missing update route.") }
        guard sourcePaths[source] == executable, FileManager.default.isExecutableFile(atPath: executable) else { throw UpdaterError("The update tool is missing or its location changed. Rescan first.") }
        let fresh = try AppInventory().read(app.path)
        guard fresh.path == app.path, fresh.bundleID == app.bundleID, fresh.version == app.version, fresh.build == app.build,
              fresh.hasStoreReceipt == app.hasStoreReceipt else { throw UpdaterError("\(app.name) changed after the scan. Rescan before updating.") }
        var inventory = AppInventory().discover(roots: [URL(fileURLWithPath: app.path).deletingLastPathComponent().path]).apps
        // Include the actual instance even when a custom root layout is used.
        if !inventory.contains(where: { $0.id == fresh.id }) { inventory.append(fresh) }
        let records: [AppRecord]
        if source == .homebrew {
            records = try await HomebrewAdapter(executable: executable, runner: runner, cacheRoot: isolatedCache ?? cacheRoot, freezeMetadata: isolatedCache != nil).check(apps: inventory)
        }
        else if source == .macPorts { records = try await MacPortsAdapter(executable: executable, runner: runner).check(apps: inventory) }
        else { records = try await AppStoreAdapter(executable: executable, runner: runner).check(apps: inventory) }
        guard let checked = records.first(where: { $0.id == fresh.id }), checked.source == source,
              checked.packageID == app.packageID, checked.targetVersion == app.targetVersion,
              checked.targetBuild == app.targetBuild,
              checked.targetPackageVersion == app.targetPackageVersion,
              checked.targetVersionIsMarketing == app.targetVersionIsMarketing,
              checked.sourceEvidence == app.sourceEvidence,
              checked.targetSHA256 == app.targetSHA256,
              checked.state == .updateAvailable, checked.automatic else {
            throw UpdaterError("The source, target release, or installation capability changed. Rescan and review a new plan.")
        }
        return checked
    }

    public func execute(_ plan: PlannedUpdate, cleanup: Bool, onObservation: ((ProcessObservation) async -> Void)? = nil, onStage: @escaping (TaskState, String) async throws -> Void) async -> ActivityRecord {
        let app = plan.app
        var record = ActivityRecord(app: app, state: .preflight, message: "Revalidating identity and target release.")
        var ownedCache: OwnedUpdateCache?
        let observations = OperationObservationHistory()
        do {
            guard let ownership = try ApplicationUpdateOwnership.acquire(for: app.path) else {
                record.state = .deferred
                record.message = "Another Maccet operation owns this application. Wait for it to finish, then rescan and review a new plan."
                record.cleanupMessage = "No installation or cleanup was performed for this attempt."
                return record
            }
            defer { ownership.release() }
            try await onStage(.preflight, record.message)
            try plan.reviewedSignature.validate(at: app.path)
            if let route = app.sparkleInstallRoute {
                try await executeSparkle(plan, route: route, record: &record, ownedCache: &ownedCache, cleanup: cleanup, onStage: onStage)
                return record
            }
            try plan.validateReviewedTool()
            _ = try await revalidate(app)
            guard !(await isRunning(app)) else {
                record.state = .deferred; record.message = "The app is still running. Close it and review a new update plan."; return record
            }
            if app.source == .homebrew {
                try plan.validateReviewedTool()
                let base = cacheRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("UnifiedUpdater")
                let cache = try OwnedUpdateCache(root: base.appendingPathComponent("Operations"))
                ownedCache = cache
                // Populate and revalidate the isolated metadata cache before the
                // installer uses it; do not fetch a new target between these steps.
                _ = try await revalidate(app, isolatedCache: cache.folder)
                guard !(await Self.isRunning(app)) else {
                    record.state = .deferred; record.message = "The app started during preflight. Close it and review a new plan."; return record
                }
                try await onStage(.installing, "Installing the reviewed release through Homebrew.")
                try plan.reviewedSignature.validate(at: app.path)
                try plan.validateReviewedTool()
                try await HomebrewAdapter(executable: app.routeExecutable!, runner: runner, cacheRoot: cache.folder, freezeMetadata: true).upgrade(app)
            }
            else if app.source == .macPorts {
                try await onStage(.installing, "Installing the reviewed release through MacPorts.")
                try plan.reviewedSignature.validate(at: app.path)
                try plan.validateReviewedTool()
                try await MacPortsAdapter(executable: app.routeExecutable!, runner: runner).upgrade(app)
            } else {
                try await onStage(.installing, "Installing the reviewed release through App Store.")
                try plan.reviewedSignature.validate(at: app.path)
                try plan.validateReviewedTool()
                try await AppStoreAdapter(executable: app.routeExecutable!, runner: runner).upgrade(app) { observation in
                    await observations.receive(observation)
                    await onObservation?(observation)
                }
            }
            try await onStage(.verifying, "Reading the installed application again.")
            var verified = false
            // App Store installation metadata can settle shortly after the command returns.
            for attempt in 0..<4 {
                if attempt > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                if let installed = try? AppInventory().read(app.path), Self.verify(before: app, after: installed) {
                    try plan.reviewedSignature.validate(at: app.path)
                    verified = true; break
                }
            }
            guard verified else { throw UpdaterError("The command finished, but the reviewed target version could not be verified. No cleanup was performed. Rescan before retrying.") }
            record.state = .succeeded; record.message = "Verified installed target \(app.targetVersion ?? "")."
            if cleanup, let ownedCache {
                do {
                    try ownedCache.removeAfterVerification(verified: true)
                    record.cleanupMessage = "Removed this verified update's isolated downloads and temporary logs. Shared Homebrew and application caches were preserved. Empty folders and the ownership record were kept."
                } catch { record.cleanupMessage = "Update verified; cleanup failed: " + Diagnostics.redact(error.localizedDescription) }
            } else if app.source == .appStore {
                record.cleanupMessage = "App Store manages its downloads. No store cache was deleted by this app."
            } else if app.source == .macPorts {
                record.cleanupMessage = "MacPorts artifacts and inactive versions were retained. No global cleanup was performed."
            } else { record.cleanupMessage = "Cleanup disabled; existing downloads were retained." }
        } catch is CancellationError {
            record.state = .canceled; record.message = "Canceled before installation started."
            record.cleanupMessage = "No cleanup performed for this attempt."
        } catch {
            record.state = .failed; record.message = Diagnostics.redact(error.localizedDescription)
            record.cleanupMessage = ownedCache.map { "No cleanup performed. Failed-attempt artifacts retained at " + Diagnostics.redact($0.folder.path) } ?? "No cleanup performed for this attempt."
        }
        let snapshot = await observations.snapshot()
        record.lastProcessObservation = snapshot.0
        record.automaticAttentionMessage = snapshot.1
        return record
    }

    private func executeSparkle(_ plan: PlannedUpdate, route: SparkleInstallRoute, record: inout ActivityRecord, ownedCache: inout OwnedUpdateCache?, cleanup: Bool, onStage: @escaping (TaskState, String) async throws -> Void) async throws {
        let app = plan.app
        let release = try await revalidateSparkle(app, route: route)
        try plan.reviewedSignature.validate(at: app.path)
        guard !(await isRunning(app)) else {
            record.state = .deferred; record.message = "The app is still running. Close it and review a new update plan."; return
        }
        guard let publicKeyFingerprint = SparkleTrustKey.ed25519PublicKeyFingerprint(at: app.path),
              publicKeyFingerprint == route.publicKeyFingerprint else {
            throw UpdaterError("The Sparkle trust key changed after review. Rescan and review a new plan.")
        }
        let installPlan = try SparkleInstallPlan(app: app, release: release, publicKeyFingerprint: publicKeyFingerprint, channelReview: route.channelReview)
        try await onStage(.installing, "Installing the reviewed Sparkle release.")
        try plan.reviewedSignature.validate(at: app.path)
        let base = cacheRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("UnifiedUpdater")
        let cache = try OwnedUpdateCache(root: base.appendingPathComponent("Operations"))
        ownedCache = cache
        let updated = try await sparkleInstaller.install(installPlan, cacheRoot: cache.folder)
        try await onStage(.verifying, "Reading the installed application again.")
        guard Self.verify(before: app, after: updated) else {
            throw UpdaterError("The Sparkle update finished, but the reviewed target could not be verified. No cleanup was performed.")
        }
        try plan.reviewedSignature.validate(at: app.path)
        record.state = .succeeded; record.message = "Verified installed Sparkle target \(app.targetVersion ?? "")."
        if cleanup, let ownedCache {
            do {
                try ownedCache.removeAfterVerification(verified: true)
                record.cleanupMessage = "Removed this verified Sparkle update's isolated downloads and extracted archive."
            } catch { record.cleanupMessage = "Update verified; cleanup failed: " + Diagnostics.redact(error.localizedDescription) }
        } else {
            record.cleanupMessage = "Cleanup disabled; existing Sparkle downloads were retained."
        }
    }

    /// A separate observation after a settled automatic attempt; it never rewrites
    /// the original attempt's outcome or removes its artifacts.
    public static func verifyAssisted(_ plan: PlannedUpdate) -> AssistedVerification {
        do {
            guard plan.app.source == .appStore, plan.app.hasStoreReceipt,
                  let id = plan.app.packageID else { throw UpdaterError("This review has no App Store identity.") }
            try ToolLocator.validateStoreID(id)
            guard let ownership = try ApplicationUpdateOwnership.acquire(for: plan.app.path) else {
                throw UpdaterError("An update still owns this application. Wait for its command to settle before verifying an assisted result.")
            }
            defer { ownership.release() }
            let installed = try AppInventory().read(plan.app.path)
            guard verify(before: plan.app, after: installed) else { throw UpdaterError("The reviewed App Store target, path, bundle identity or receipt could not be verified.") }
            try plan.reviewedSignature.validate(at: plan.app.path)
            return AssistedVerification(verified: true, message: "Independently observed the reviewed target after the App Store handoff. The automatic attempt's original outcome is retained; no cleanup was performed.")
        } catch {
            return AssistedVerification(verified: false, message: Diagnostics.redact(error.localizedDescription))
        }
    }
    // Metadata comparison only; execute also validates the reviewed code signature.
    public static func verify(before: AppRecord, after: AppRecord) -> Bool {
        guard before.bundleID == after.bundleID, before.path == after.path, before.hasStoreReceipt == after.hasStoreReceipt,
              before.version != after.version || before.build != after.build, let target = before.targetVersion else { return false }
        // App Store and MacPorts targets are marketing versions. Only Homebrew
        // catalog fallbacks can also describe a build or a version/build pair.
        // Explicit Homebrew display metadata always identifies a marketing release.
        let matchesTarget: Bool
        switch before.source {
        case .appStore, .macPorts:
            matchesTarget = ReleaseComparison.compare(after.version, target) == .orderedSame
        default:
            matchesTarget = before.targetVersionIsMarketing == true
                ? ReleaseComparison.compare(after.version, target) == .orderedSame
                : ReleaseComparison.satisfies(after, target: target)
        }
        return matchesTarget
            && (before.targetBuild.map { ReleaseComparison.compare(after.build, $0) == .orderedSame } ?? true)
    }
    public static func isRunning(_ app: AppRecord) async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { running in
                running.bundleIdentifier == app.bundleID
                    || running.bundleURL.map { ToolLocator.canonicalPath($0.path) == ToolLocator.canonicalPath(app.path) } == true
            }
        }
    }
    private func brew(for app: AppRecord) throws -> HomebrewAdapter {
        guard app.source == .homebrew, let executable = app.routeExecutable else { throw UpdaterError("Missing Homebrew route.") }
        return HomebrewAdapter(executable: executable, runner: runner, cacheRoot: cacheRoot)
    }
}
