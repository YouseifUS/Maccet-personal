import Foundation
import AppKit

public struct VendorObservation: Codable, Equatable {
    public enum State: String, Codable { case updateAvailable, current, unsupported, failed }
    public var state: State
    public var targetVersion: String?
    public var channel: String?
    public var platform: String?
    public var date = Date()
    public var message: String
}

public struct VendorHandoffPlan: Identifiable {
    public let id = UUID()
    public let app: AppRecord
    public let targetVersion: String
    public let channelReview: DiscoveryChannelReview
    public let platform: String
    public let date = Date()
    public var instructionsURL: URL { OfficialVendorService.instructionsURL }
    let signature: CodeSignatureEvidence
    fileprivate init(app: AppRecord, targetVersion: String, review: DiscoveryChannelReview, platform: String) {
        self.app = app; self.targetVersion = targetVersion; channelReview = review; self.platform = platform
        signature = CodeSignatureEvidence.capture(at: app.path)
    }
}

public struct VendorAssistedRecord: Codable, Identifiable {
    public enum State: String, Codable { case awaitingUser, verified, notVerified }
    public var id: UUID
    public var date = Date()
    public var verifiedAt: Date?
    public var appName: String
    public var appPath: String
    public var fromVersion: String
    public var targetVersion: String
    public var channel: String
    public var state: State = .awaitingUser
    public var message = "Guided vendor handoff recorded. No automatic installation was attempted."
    public init(plan: VendorHandoffPlan) {
        id = plan.id; appName = plan.app.name; appPath = plan.app.path
        fromVersion = plan.app.version; targetVersion = plan.targetVersion; channel = plan.channelReview.channel
    }
}

/// The first vendor family is Chrome. No endpoint, team or command comes from a feed.
public struct OfficialVendorService {
    public static let instructionsURL = URL(string: "https://support.google.com/chrome/answer/95414?co=GENIE.Platform%3DDesktop&hl=en")!
    public static let channels = ["stable", "extended", "beta", "dev", "canary"]
    private static let bundles: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"]
    private let loader: any MetadataLoading
    private let validateIdentity: (AppRecord) throws -> Void
    private let architectures: (AppRecord) throws -> Set<CatalogArchitecture>
    private let isRunning: (AppRecord) async -> Bool
    private let nativeArchitecture: CatalogArchitecture
    private let macOS: String
    public init(loader: any MetadataLoading = BoundedMetadataLoader()) {
        self.loader = loader
        validateIdentity = Self.validateChrome
        architectures = { try ExecutableArchitecture.read(appPath: $0.path) }
        isRunning = Self.isRunningCopy
        #if arch(arm64)
        nativeArchitecture = .arm64
        #else
        nativeArchitecture = .x86_64
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        macOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
    @_spi(Testing) public init(loader: any MetadataLoading, nativeArchitecture: CatalogArchitecture = .arm64, macOS: String = "27.0",
                              validateIdentity: @escaping (AppRecord) throws -> Void, architectures: @escaping (AppRecord) throws -> Set<CatalogArchitecture>, isRunning: @escaping (AppRecord) async -> Bool = { _ in false }) {
        self.loader = loader; self.nativeArchitecture = nativeArchitecture; self.macOS = macOS
        self.validateIdentity = validateIdentity; self.architectures = architectures; self.isRunning = isRunning
    }
    private static func isRunningCopy(_ app: AppRecord) async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { running in
                if let url = running.bundleURL { return ToolLocator.canonicalPath(url.path) == app.path }
                return running.bundleIdentifier == app.bundleID
            }
        }
    }
    public static func recognizes(_ app: AppRecord) -> Bool { bundles.contains(app.bundleID) }
    private static func validateChrome(_ app: AppRecord) throws {
        guard recognizes(app) else { throw UpdaterError("No supported official vendor identity.") }
        try DeveloperIDValidation.validate(path: app.path, bundleID: app.bundleID, team: "EQHXZ8M8AV")
    }
    private func context(_ app: AppRecord, review: DiscoveryChannelReview?) throws -> (DiscoveryChannelReview, String) {
        guard Self.recognizes(app), app.state != .systemManaged, !app.hasStoreReceipt, app.source == nil, (app.routes ?? []).isEmpty,
              app.path == ToolLocator.canonicalPath(app.path) else { throw UpdaterError("This application is outside the unmanaged Chrome vendor route.") }
        try validateIdentity(app)
        guard let review, review.path == app.path, review.bundleID == app.bundleID, review.teamIdentifier == "EQHXZ8M8AV",
              Self.channels.contains(review.channel) else { throw UpdaterError("Confirm this copy's installed Chrome channel from its own settings or administrator policy before checking vendor releases.") }
        guard let osComparison = ReleaseComparison.compare(macOS, "13.0"), osComparison != .orderedAscending,
              app.version.range(of: #"\A[0-9]+(?:\.[0-9]+){3}\z"#, options: .regularExpression) != nil,
              app.version.utf8.count <= 64 else { throw UpdaterError("Unsupported Chrome version or macOS baseline. Use the vendor's instructions.") }
        let available = try architectures(app)
        let platform: String
        if nativeArchitecture == .arm64 && available.contains(.arm64) { platform = "mac_arm64" }
        else if available.contains(.x86_64) { platform = "mac" }
        else { throw UpdaterError("The installed executable cannot run on this architecture.") }
        return (review, platform)
    }
    private static func endpoint(platform: String, channel: String) -> URL {
        var parts = URLComponents(string: "https://versionhistory.googleapis.com/v1/chrome/platforms/\(platform)/channels/\(channel)/versions/all/releases")!
        parts.queryItems = [URLQueryItem(name: "filter", value: "endtime=none,fraction>0"), URLQueryItem(name: "order_by", value: "version desc")]
        return parts.url!
    }
    public func check(_ app: AppRecord, review: DiscoveryChannelReview?) async -> VendorObservation {
        let context: (DiscoveryChannelReview, String)
        do { context = try self.context(app, review: review) }
        catch { return VendorObservation(state: .unsupported, message: Diagnostics.redact(error.localizedDescription)) }
        do {
            let bytes = try await loader.load(Self.endpoint(platform: context.1, channel: context.0.channel), maximumBytes: 512 * 1024, mimeTypes: ["application/json"])
            try Task.checkCancellation()
            let target = try Self.latestRelease(bytes, platform: context.1, channel: context.0.channel)
            let fresh = try AppInventory().read(app.path)
            guard fresh.path == app.path, fresh.bundleID == app.bundleID, fresh.version == app.version, fresh.build == app.build, fresh.hasStoreReceipt == app.hasStoreReceipt else { throw UpdaterError("The application changed during the vendor check. Rescan.") }
            try validateIdentity(fresh)
            let available = ReleaseComparison.compare(app.version, target) == .orderedAscending
            return VendorObservation(state: available ? .updateAvailable : .current, targetVersion: target, channel: context.0.channel, platform: context.1,
                                     message: "Official Chrome published-release observation for the reviewed \(context.0.channel) channel. Rollout eligibility, managed policies and release compatibility must be confirmed in Chrome. No automatic installation is offered.")
        } catch { return VendorObservation(state: .failed, message: Diagnostics.redact(error.localizedDescription)) }
    }
    @_spi(Testing) public static func latestRelease(_ data: Data, platform: String, channel: String, now: Date = Date()) throws -> String {
        struct Envelope: Decodable { var releases: [Release]; var nextPageToken: String? }
        struct Release: Decodable {
            struct Serving: Decodable { var startTime: String; var endTime: String? }
            var name: String; var version: String; var fraction: Double; var serving: Serving
        }
        guard data.count <= 512 * 1024 else { throw UpdaterError("Vendor response exceeded its size limit.") }
        let body = try JSONDecoder().decode(Envelope.self, from: data)
        guard body.releases.count <= 256, body.nextPageToken?.isEmpty != false else { throw UpdaterError("Vendor response is incomplete or exceeds the release limit.") }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let simple = ISO8601DateFormatter()
        var versions: [String] = []
        for release in body.releases {
            guard release.version.utf8.count <= 64, release.version.range(of: #"\A[0-9]+(?:\.[0-9]+){3}\z"#, options: .regularExpression) != nil,
                  release.name.hasPrefix("chrome/platforms/\(platform)/channels/\(channel)/versions/\(release.version)/releases/"), release.name.utf8.count <= 512,
                  release.fraction.isFinite, (0...1).contains(release.fraction),
                  let start = formatter.date(from: release.serving.startTime) ?? simple.date(from: release.serving.startTime) else { throw UpdaterError("Vendor release identity, version or rollout metadata is unsupported.") }
            if let end = release.serving.endTime, end != "1970-01-01T00:00:00Z" { continue }
            if release.fraction <= 0 || start > now { continue }
            versions.append(release.version)
        }
        guard let target = versions.max(by: { ReleaseComparison.compare($0, $1) == .orderedAscending }) else { throw UpdaterError("No currently served Chrome release was found for this platform and reviewed channel.") }
        return target
    }
    public func prepareHandoff(_ app: AppRecord, review: DiscoveryChannelReview?) async throws -> VendorHandoffPlan {
        let observation = await check(app, review: review)
        guard observation.state == .updateAvailable, let target = observation.targetVersion, let platform = observation.platform, let review,
              app.vendorObservation?.targetVersion == target, app.vendorObservation?.channel == review.channel else {
            throw UpdaterError("The official vendor target or reviewed channel changed. Check again before reviewing a handoff. " + observation.message)
        }
        return VendorHandoffPlan(app: app, targetVersion: target, review: review, platform: platform)
    }
    public func verify(_ plan: VendorHandoffPlan, review: DiscoveryChannelReview?) async -> (Bool, String) {
        do {
            guard review == plan.channelReview else { throw UpdaterError("The reviewed channel changed. Check and review a new vendor target.") }
            guard !(await isRunning(plan.app)) else { throw UpdaterError("Close the application before verifying the installed vendor result.") }
            guard let ownership = try ApplicationUpdateOwnership.acquire(for: plan.app.path) else { throw UpdaterError("An automatic update owns this application. Wait for it to settle.") }
            defer { ownership.release() }
            let installed = try AppInventory().read(plan.app.path)
            guard installed.path == plan.app.path, installed.bundleID == plan.app.bundleID, !installed.hasStoreReceipt,
                  ReleaseComparison.compare(installed.version, plan.targetVersion) == .orderedSame,
                  installed.version != plan.app.version || installed.build != plan.app.build else { throw UpdaterError("The reviewed vendor path, identity or target version could not be verified.") }
            let currentContext = try context(installed, review: review)
            guard currentContext.1 == plan.platform else { throw UpdaterError("The installed executable architecture differs from the reviewed vendor target.") }
            try plan.signature.validate(at: installed.path)
            return (true, "Verified the exact reviewed version and publisher after the guided vendor handoff. The channel remains user-confirmed. No automatic installation or cleanup was performed.")
        } catch { return (false, Diagnostics.redact(error.localizedDescription)) }
    }
}
