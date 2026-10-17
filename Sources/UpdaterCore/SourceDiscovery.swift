import Foundation
import CryptoKit
import Darwin

public struct DiscoveryCatalogConfiguration: Codable, Equatable {
    public var endpoint: URL
    public var keyID: String
    public var publicKey: String
    public var minimumRevision: UInt64
    public init(endpoint: URL, keyID: String, publicKey: String, minimumRevision: UInt64 = 1) {
        self.endpoint = endpoint; self.keyID = keyID; self.publicKey = publicKey; self.minimumRevision = minimumRevision
    }
    public func validate() throws {
        try BoundedMetadataLoader.validateURL(endpoint)
        guard keyID.range(of: #"\A[A-Za-z0-9._-]{1,128}\z"#, options: .regularExpression) != nil,
              let key = Data(base64Encoded: publicKey), key.count == 32, key.base64EncodedString() == publicKey,
              minimumRevision > 0 else { throw UpdaterError("Enter a trusted publisher key ID, canonical base64 Ed25519 public key and positive minimum revision.") }
    }
    public var fingerprint: String {
        SHA256.hash(data: Data(base64Encoded: publicKey) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    var cacheNamespace: String {
        SHA256.hash(data: Data((keyID + ":" + publicKey).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct DiscoveryChannelReview: Codable, Equatable {
    public var path: String
    public var bundleID: String
    public var teamIdentifier: String
    public var channel: String
    public init(path: String, bundleID: String, teamIdentifier: String, channel: String) {
        self.path = path; self.bundleID = bundleID; self.teamIdentifier = teamIdentifier; self.channel = channel
    }
}

public struct CatalogCandidate: Codable, Equatable, Identifiable {
    public enum Assessment: String, Codable { case matched, provisional, conflict }
    public var id: String
    public var source: CatalogSource
    public var packageID: String?
    public var channel: String?
    public var metadataURL: URL?
    public var assessment: Assessment
    public var message: String
    public var catalogRevision: UInt64
    public var expiresAt: Date
}

public struct DiscoveryCatalogStatus: Codable {
    public enum State: String, Codable { case notConfigured, ready, cached, failed }
    public var state: State
    public var message: String
    public var revision: UInt64?
    public var issuedAt: Date?
    public var expiresAt: Date?
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var error: String?
    public init(state: State, message: String) { self.state = state; self.message = message }
}

public struct DiscoveryCatalogResult {
    public var catalog: AuthenticatedSourceMappingCatalog?
    public var status: DiscoveryCatalogStatus
}

public protocol SourceCatalogLoading { func load(_ url: URL) async throws -> Data }
public struct SourceCatalogLoader: SourceCatalogLoading {
    public init() {}
    public func load(_ url: URL) async throws -> Data {
        try await BoundedMetadataLoader().load(url, maximumBytes: 2 * 1024 * 1024, mimeTypes: ["application/json"])
    }
}

public struct SourceDiscoveryService {
    private let configuration: DiscoveryCatalogConfiguration
    private let root: URL
    private let loader: any SourceCatalogLoading
    private struct RefreshState: Codable { var lastAttempt: Date; var lastSuccess: Date?; var succeeded: Bool; var error: String? }
    public init(root: URL, configuration: DiscoveryCatalogConfiguration, loader: any SourceCatalogLoading = SourceCatalogLoader()) {
        self.configuration = configuration; self.root = root.appendingPathComponent(configuration.cacheNamespace); self.loader = loader
    }
    private var catalogStore: SourceMappingCatalogStore {
        SourceMappingCatalogStore(root: root, trustedKeys: [configuration.keyID: Data(base64Encoded: configuration.publicKey) ?? Data()], minimumRevision: configuration.minimumRevision)
    }
    private func refreshState() -> RefreshState? {
        let descriptor = open(root.appendingPathComponent("refresh-state.json").path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 4096,
              let data = try? FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: 4097), data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(RefreshState.self, from: data)
    }
    private func result(now: Date, message: String, state: DiscoveryCatalogStatus.State) -> DiscoveryCatalogResult {
        let validConfiguration = (try? configuration.validate()) != nil
        let cached = validConfiguration ? (try? catalogStore.load(now: now)) : nil
        let refresh = refreshState()
        var status = DiscoveryCatalogStatus(state: cached == nil ? .failed : state, message: message)
        status.revision = cached?.revision; status.issuedAt = cached?.issuedAt; status.expiresAt = cached?.expiresAt
        status.lastAttempt = refresh?.lastAttempt; status.lastSuccess = refresh?.lastSuccess; status.error = refresh?.error
        return DiscoveryCatalogResult(catalog: cached, status: status)
    }
    /// Scans use only a currently authenticated, unexpired local snapshot.
    public func load(now: Date = Date()) -> DiscoveryCatalogResult {
        do {
            try configuration.validate()
            guard try catalogStore.load(now: now) != nil else {
                return result(now: now, message: "No discovery catalog is cached. Choose Refresh Discovery Catalog.", state: .failed)
            }
            return result(now: now, message: "Using an authenticated, unexpired discovery catalog. Candidates are not installation routes.", state: .cached)
        } catch { return result(now: now, message: Diagnostics.redact(error.localizedDescription), state: .failed) }
    }
    public func refresh(now: Date = Date()) async -> DiscoveryCatalogResult {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try configuration.validate()
            guard let ownership = try ApplicationUpdateOwnership.acquire(for: root.appendingPathComponent("refresh-state.json").path) else {
                return result(now: now, message: "Another discovery refresh is active. The valid cache, if any, remains available.", state: .cached)
            }
            defer { ownership.release() }
            let previous = refreshState()
            if let previous {
                // A wall-clock rollback cannot bypass the refresh limit.
                let interval: TimeInterval = previous.succeeded && (try? catalogStore.load(now: now)) != nil ? 3600 : 60
                if now.timeIntervalSince(previous.lastAttempt) < interval {
                    return result(now: now, message: "Discovery refresh is rate limited (one hour after success; one minute after failure). Valid cached candidates remain available.", state: .cached)
                }
            }
            let store = LocalStore(root: root)
            try store.save(RefreshState(lastAttempt: now, lastSuccess: previous?.lastSuccess, succeeded: false, error: nil), file: "refresh-state.json")
            do {
                let bytes = try await loader.load(configuration.endpoint)
                try Task.checkCancellation()
                let completed = now.addingTimeInterval(ProcessInfo.processInfo.systemUptime - started)
                _ = try catalogStore.accept(bytes, now: completed)
                try store.save(RefreshState(lastAttempt: now, lastSuccess: completed, succeeded: true, error: nil), file: "refresh-state.json")
                return result(now: completed, message: "Authenticated discovery catalog refreshed. Candidates cannot authorize installation.", state: .ready)
            } catch {
                let completed = now.addingTimeInterval(ProcessInfo.processInfo.systemUptime - started)
                let diagnostic = String(Diagnostics.redact(error.localizedDescription).prefix(1500))
                try? store.save(RefreshState(lastAttempt: now, lastSuccess: previous?.lastSuccess, succeeded: false, error: diagnostic), file: "refresh-state.json")
                return result(now: completed, message: "Discovery refresh failed. Only a still-valid authenticated cache can be used.", state: .cached)
            }
        } catch {
            let completed = now.addingTimeInterval(ProcessInfo.processInfo.systemUptime - started)
            return result(now: completed, message: "Discovery refresh failed: " + Diagnostics.redact(error.localizedDescription) + ". Only a still-valid authenticated cache can be used.", state: .cached)
        }
    }

    public static func candidates(for app: AppRecord, catalog: AuthenticatedSourceMappingCatalog, review: DiscoveryChannelReview?,
                                  now: Date = Date(), macOS: String? = nil, architecture: CatalogArchitecture? = nil,
                                  teamIdentifier: String? = nil) -> [CatalogCandidate] {
        guard app.state != .systemManaged, catalog.expiresAt > now else { return [] }
        let mappings = catalog.mappings.filter { $0.bundleID == app.bundleID && (!app.hasStoreReceipt || $0.source == .appStore) }
        guard !mappings.isEmpty else { return [] }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let nativeArchitecture = CatalogArchitecture.arm64
        #else
        let nativeArchitecture = CatalogArchitecture.x86_64
        #endif
        let team = teamIdentifier ?? InstalledPublisherIdentity.teamIdentifier(at: app.path)
        let channel = review.flatMap { $0.path == app.path && ToolLocator.canonicalPath(app.path) == app.path && $0.bundleID == app.bundleID && $0.teamIdentifier == team ? $0.channel : nil }
        let identity = SourceIdentity(bundleID: app.bundleID, signingTeamIdentifier: team, channel: channel,
                                      macOS: macOS ?? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: architecture ?? nativeArchitecture,
                                      hasStoreReceipt: app.hasStoreReceipt)
        return mappings.map { mapping in
            var candidate = CatalogCandidate(id: mapping.id, source: mapping.source, packageID: mapping.packageID, channel: mapping.channel,
                                             metadataURL: mapping.metadataURL, assessment: .provisional, message: "Publisher/channel evidence is incomplete. No source ownership or release check is established.", catalogRevision: catalog.revision, expiresAt: catalog.expiresAt)
            do {
                _ = try catalog.evidence(mappingID: mapping.id, identity: identity, now: now)
                candidate.assessment = .matched
                candidate.message = "Signed mapping matches the installed bundle, publisher, reviewed channel and platform. This is a discovery candidate, not an ownership route or a checked release."
            } catch {
                let knownConflict = (mapping.signingTeamIdentifier != nil && team != nil && mapping.signingTeamIdentifier != team)
                    || (mapping.channel != nil && channel != nil && mapping.channel != channel)
                    || !mapping.architectures.contains(identity.architecture)
                    || ReleaseComparison.compare(identity.macOS, mapping.minimumOS) == .orderedAscending
                if knownConflict { candidate.assessment = .conflict; candidate.message = Diagnostics.redact(error.localizedDescription) }
            }
            return candidate
        }
    }
}
