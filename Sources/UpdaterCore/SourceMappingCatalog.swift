import Foundation
import CryptoKit
import Darwin

public enum SourceCapability: String, Codable { case checkOnly, assisted, managerUpdate }
public enum SourceEvidenceLevel: String, Codable { case unverified, reviewedMapping, installedManager }
public enum CatalogSource: String, Codable { case homebrew, macPorts, appStore, sparkle, vendor }
public enum CatalogArchitecture: String, Codable { case arm64, x86_64 }

public struct SourceEvidence: Codable, Equatable {
    public var level: SourceEvidenceLevel
    public var capability: SourceCapability
    public var bundleID: String
    public var signingTeamIdentifier: String?
    public var channel: String?
    public var officialHosts: [String]
    public var reviewedAt: Date
    public init(level: SourceEvidenceLevel, capability: SourceCapability, bundleID: String, signingTeamIdentifier: String?, channel: String?, officialHosts: [String], reviewedAt: Date) {
        self.level = level; self.capability = capability; self.bundleID = bundleID
        self.signingTeamIdentifier = signingTeamIdentifier; self.channel = channel
        self.officialHosts = officialHosts; self.reviewedAt = reviewedAt
    }
    public var permitsManagerUpdate: Bool { level == .installedManager && capability == .managerUpdate }
}

/// Identity must be independently established by the caller, not copied from a
/// catalog entry. Unknown signing/channel evidence cannot establish a match.
public struct SourceIdentity {
    public var bundleID: String
    public var signingTeamIdentifier: String?
    public var channel: String?
    public var macOS: String
    public var architecture: CatalogArchitecture
    public var hasStoreReceipt: Bool
    public init(bundleID: String, signingTeamIdentifier: String?, channel: String?, macOS: String, architecture: CatalogArchitecture, hasStoreReceipt: Bool = false) {
        self.bundleID = bundleID; self.signingTeamIdentifier = signingTeamIdentifier
        self.channel = channel; self.macOS = macOS; self.architecture = architecture; self.hasStoreReceipt = hasStoreReceipt
    }
}

public struct SourceMapping: Codable, Equatable {
    public var id: String
    public var source: CatalogSource
    public var packageID: String?
    public var bundleID: String
    public var signingTeamIdentifier: String?
    public var channel: String?
    public var officialHosts: [String]
    public var metadataURL: URL?
    public var reviewedAt: Date
    public var capability: SourceCapability
    public var minimumOS: String
    public var architectures: [CatalogArchitecture]
    public init(id: String, source: CatalogSource, packageID: String? = nil, bundleID: String, signingTeamIdentifier: String?, channel: String?, officialHosts: [String], metadataURL: URL?, reviewedAt: Date, capability: SourceCapability = .checkOnly, minimumOS: String = "13.0", architectures: [CatalogArchitecture] = [.arm64, .x86_64]) {
        self.id = id; self.source = source; self.packageID = packageID; self.bundleID = bundleID
        self.signingTeamIdentifier = signingTeamIdentifier; self.channel = channel; self.officialHosts = officialHosts
        self.metadataURL = metadataURL; self.reviewedAt = reviewedAt; self.capability = capability
        self.minimumOS = minimumOS; self.architectures = architectures
    }
    fileprivate func validate(issuedAt: Date) throws {
        func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
        guard matches(id, #"\A[a-z0-9][a-z0-9._-]{0,127}\z"#),
              matches(bundleID, #"\A[A-Za-z0-9][A-Za-z0-9.-]{0,254}\z"#),
              signingTeamIdentifier.map({ matches($0, #"\A[A-Z0-9]{10}\z"#) }) ?? true,
              channel.map({ matches($0, #"\A[a-z0-9][a-z0-9._-]{0,31}\z"#) }) ?? true,
              reviewedAt <= issuedAt, reviewedAt.timeIntervalSince1970 > 0,
              minimumOS.utf8.count <= 64, ReleaseComparison.compare(minimumOS, minimumOS) != nil,
              !architectures.isEmpty, architectures.count <= 2,
              Set(architectures).count == architectures.count, officialHosts.count <= 8,
              Set(officialHosts).count == officialHosts.count else { throw UpdaterError("Invalid source-mapping identity, review date or compatibility evidence.") }
        for host in officialHosts {
            guard host.utf8.count <= 253, matches(host, #"\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z"#) else { throw UpdaterError("Mapping domains must be exact public DNS hostnames.") }
        }
        if let url = metadataURL {
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard url.absoluteString.utf8.count <= 2048, parts?.scheme == "https", parts?.user == nil, parts?.password == nil,
                  parts?.fragment == nil, parts?.port == nil || parts?.port == 443,
                  let host = parts?.host?.lowercased(), officialHosts.contains(host) else { throw UpdaterError("Mapping metadata URL conflicts with reviewed HTTPS/domain evidence.") }
        }
        if let packageID {
            switch source {
            case .homebrew: try ToolLocator.validatePackageID(packageID)
            case .macPorts: try MacPortsAdapter.validateName(packageID)
            case .appStore: try ToolLocator.validateStoreID(packageID)
            default: throw UpdaterError("This mapping source cannot declare a manager package identity.")
            }
        }
        if capability == .managerUpdate {
            guard packageID != nil, [.homebrew, .macPorts, .appStore].contains(source) else { throw UpdaterError("Mapping capability has no constrained manager route.") }
        }
    }
    fileprivate func evidence(for identity: SourceIdentity) throws -> SourceEvidence {
        guard bundleID == identity.bundleID else { throw UpdaterError("Mapping bundle identity conflicts with the installed application.") }
        guard let team = signingTeamIdentifier, let installedTeam = identity.signingTeamIdentifier,
              let channel, let installedChannel = identity.channel, metadataURL != nil, !officialHosts.isEmpty else {
            throw UpdaterError("Signing identity, channel or official-domain evidence is unknown; this mapping is provisional.")
        }
        guard team == installedTeam, channel == installedChannel else { throw UpdaterError("Mapping signing identity or release channel conflicts with the installed application.") }
        guard architectures.contains(identity.architecture),
              let comparison = ReleaseComparison.compare(identity.macOS, minimumOS), comparison != .orderedAscending else { throw UpdaterError("Mapping does not support the installed OS/architecture.") }
        if identity.hasStoreReceipt && source != .appStore { throw UpdaterError("Store ownership conflicts with this mapping source.") }
        if source == .appStore && !identity.hasStoreReceipt { throw UpdaterError("A store mapping requires independent receipt evidence.") }
        return SourceEvidence(level: .reviewedMapping, capability: capability, bundleID: bundleID, signingTeamIdentifier: team, channel: channel, officialHosts: officialHosts, reviewedAt: reviewedAt)
    }
}

public struct SourceMappingCatalog: Codable {
    public var schemaVersion: Int
    public var revision: UInt64
    public var issuedAt: Date
    public var expiresAt: Date
    public var mappings: [SourceMapping]
    public init(schemaVersion: Int = 1, revision: UInt64, issuedAt: Date, expiresAt: Date, mappings: [SourceMapping]) {
        self.schemaVersion = schemaVersion; self.revision = revision; self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.mappings = mappings
    }
    fileprivate func validate(now: Date, allowExpired: Bool = false) throws {
        guard schemaVersion == 1, revision > 0, issuedAt <= now.addingTimeInterval(300), expiresAt > issuedAt,
              allowExpired || expiresAt > now, mappings.count <= 4096,
              Set(mappings.map(\.id)).count == mappings.count else { throw UpdaterError("Unsupported, expired or invalid mapping catalog.") }
        var identities = Set<String>()
        for entry in mappings {
            try entry.validate(issuedAt: issuedAt)
            let key = [entry.source.rawValue, entry.bundleID, entry.signingTeamIdentifier ?? "?", entry.channel ?? "?"].joined(separator: ":")
            guard identities.insert(key).inserted else { throw UpdaterError("Conflicting duplicate source-mapping identity.") }
        }
    }
    fileprivate func evidence(mappingID: String, identity: SourceIdentity, now: Date) throws -> SourceEvidence {
        try validate(now: now)
        guard let entry = mappings.first(where: { $0.id == mappingID }) else { throw UpdaterError("No reviewed mapping matches this identifier.") }
        return try entry.evidence(for: identity)
    }
}

/// A value snapshot produced only after publisher authentication. Mutating a
/// copy of the authoring DTO cannot alter this catalog's accepted evidence.
public struct AuthenticatedSourceMappingCatalog {
    private let catalog: SourceMappingCatalog
    fileprivate init(_ catalog: SourceMappingCatalog) { self.catalog = catalog }
    public var revision: UInt64 { catalog.revision }
    public var issuedAt: Date { catalog.issuedAt }
    public var expiresAt: Date { catalog.expiresAt }
    public var mappings: [SourceMapping] { catalog.mappings }
    public func evidence(mappingID: String, identity: SourceIdentity, now: Date = Date()) throws -> SourceEvidence {
        try catalog.evidence(mappingID: mappingID, identity: identity, now: now)
    }
}

/// Keys are pinned by trusted client configuration, never accepted from the
/// envelope. This component performs no network requests or installations.
public struct SourceMappingCatalogStore {
    public static let signatureDomain = Data("Maccet Source Mapping Catalog v1\0".utf8)
    private struct Envelope: Codable { var keyID: String; var payload: String; var signature: String }
    private let store: LocalStore
    private let trustedKeys: [String: Data]
    private let minimumRevision: UInt64
    private let filename = "source-mapping-catalog.json"
    private let envelopeLimit = 2 * 1024 * 1024
    public init(root: URL, trustedKeys: [String: Data], minimumRevision: UInt64 = 1) {
        store = LocalStore(root: root); self.trustedKeys = trustedKeys; self.minimumRevision = minimumRevision
    }
    private func verified(_ bytes: Data, now: Date, allowExpired: Bool = false) throws -> (Envelope, SourceMappingCatalog) {
        guard bytes.count <= envelopeLimit,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == ["keyID", "payload", "signature"] else { throw UpdaterError("Unsupported mapping envelope.") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard envelope.keyID.utf8.count <= 128, let key = trustedKeys[envelope.keyID], key.count == 32,
              let payload = Data(base64Encoded: envelope.payload), payload.count <= 1024 * 1024,
              let signature = Data(base64Encoded: envelope.signature), signature.count == 64 else { throw UpdaterError("Mapping signature or trusted publisher key is unavailable.") }
        var signed = Self.signatureDomain; signed.append(payload)
        guard try Curve25519.Signing.PublicKey(rawRepresentation: key).isValidSignature(signature, for: signed) else { throw UpdaterError("Mapping signature verification failed.") }
        // Unknown execution/configuration fields are rejected, not ignored by
        // Codable. The format contains no executable paths, scripts or arguments.
        guard let body = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              Set(body.keys) == ["schemaVersion", "revision", "issuedAt", "expiresAt", "mappings"],
              let entries = body["mappings"] as? [[String: Any]], entries.count <= 4096 else { throw UpdaterError("Unsupported mapping catalog fields.") }
        let allowed: Set<String> = ["id", "source", "packageID", "bundleID", "signingTeamIdentifier", "channel", "officialHosts", "metadataURL", "reviewedAt", "capability", "minimumOS", "architectures"]
        guard entries.allSatisfy({ Set($0.keys).isSubset(of: allowed) }) else { throw UpdaterError("Unknown mapping fields are not executable capabilities.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(SourceMappingCatalog.self, from: payload)
        try catalog.validate(now: now, allowExpired: allowExpired)
        guard allowExpired || catalog.revision >= minimumRevision else { throw UpdaterError("Mapping revision is older than the client's trusted minimum.") }
        return (envelope, catalog)
    }
    private func cachedBytes() throws -> Data? {
        let url = store.root.appendingPathComponent(filename)
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 && errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw UpdaterError("Mapping cache could not be opened safely.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= envelopeLimit else { throw UpdaterError("Mapping cache is not a bounded regular file.") }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: envelopeLimit + 1) ?? Data()
        guard data.count <= envelopeLimit else { throw UpdaterError("Mapping cache exceeded its size limit.") }
        return data
    }
    public func load(now: Date = Date()) throws -> AuthenticatedSourceMappingCatalog? {
        try cachedBytes().map { AuthenticatedSourceMappingCatalog(try verified($0, now: now).1) }
    }
    @discardableResult public func accept(_ bytes: Data, now: Date = Date()) throws -> AuthenticatedSourceMappingCatalog {
        let (envelope, catalog) = try verified(bytes, now: now)
        guard let ownership = try ApplicationUpdateOwnership.acquire(for: store.root.appendingPathComponent(filename).path) else { throw UpdaterError("Another source-catalog acceptance is active. Retry after it finishes.") }
        defer { ownership.release() }
        if let cached = try cachedBytes() {
            let (oldEnvelope, old) = try verified(cached, now: now, allowExpired: true)
            guard catalog.revision > old.revision || (catalog.revision == old.revision && envelope.payload == oldEnvelope.payload) else { throw UpdaterError("Mapping rollback or same-revision replacement was rejected.") }
        }
        try store.save(envelope, file: filename)
        return AuthenticatedSourceMappingCatalog(catalog)
    }
}
