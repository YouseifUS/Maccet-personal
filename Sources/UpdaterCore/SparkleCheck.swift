import Foundation

/// Feed observations never grant a manager route or installation capability.
public struct SparkleObservation: Codable, Equatable {
    public enum State: String, Codable { case updateAvailable, current, unsupported, failed }
    public var state: State
    public var version: String?
    public var build: String?
    public var message: String
    public var date: Date = Date()
}

public protocol SparkleFeedLoading {
    func load(_ url: URL) async throws -> Data
}

public struct SparkleFeedLoader: SparkleFeedLoading {
    public static let maximumBytes = 1024 * 1024
    private var transport = BoundedMetadataLoader()
    public init() {}
    @_spi(Testing) public init(protocolClasses: [AnyClass]) { transport = BoundedMetadataLoader(protocolClasses: protocolClasses) }
    public static func validateURL(_ url: URL) throws { try BoundedMetadataLoader.validateURL(url) }
    public func load(_ url: URL) async throws -> Data {
        try await transport.load(url, maximumBytes: Self.maximumBytes, mimeTypes: ["application/rss+xml", "application/xml", "text/xml"])
    }
}

public struct SparkleCheck {
    public let loader: any SparkleFeedLoading
    public let macOS: String
    public let architecture: String
    public init(loader: any SparkleFeedLoading = SparkleFeedLoader(), macOS: String? = nil, architecture: String? = nil) {
        self.loader = loader
        let os = ProcessInfo.processInfo.operatingSystemVersion
        self.macOS = macOS ?? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(arm64)
        self.architecture = architecture ?? "arm64"
        #else
        self.architecture = architecture ?? "x86_64"
        #endif
    }
    public func check(_ app: AppRecord) async -> SparkleObservation {
        do {
            guard let text = app.sparkleFeed, let url = URL(string: text) else { throw UpdaterError("No valid embedded Sparkle feed URL.") }
            try SparkleFeedLoader.validateURL(url)
            if app.sparkleRequiresSignedFeed == true {
                return SparkleObservation(state: .unsupported, message: "This application requires signed appcasts. Use its built-in updater to authenticate the feed.")
            }
            // Do not claim parity with delegate-provided channels, feeds or custom comparators.
            guard numeric(app.build), numeric(app.version), ["arm64", "x86_64"].contains(architecture) else {
                return SparkleObservation(state: .unsupported, message: "Sparkle's custom version/channel behavior cannot be established from this application's numeric metadata. Use its built-in updater.")
            }
            return try evaluate(await loader.load(url), app: app)
        } catch is CancellationError {
            return SparkleObservation(state: .failed, message: "Sparkle check canceled.")
        } catch {
            return SparkleObservation(state: .failed, message: Diagnostics.redact(error.localizedDescription))
        }
    }
    public func evaluate(_ data: Data, app: AppRecord) throws -> SparkleObservation {
        guard numeric(app.build), numeric(app.version), numeric(macOS), ["arm64", "x86_64"].contains(architecture) else { throw UpdaterError("Unsupported installed version or operating system for Sparkle comparison.") }
        let items = try AppcastParser.read(data)
        var compatible: [AppcastItem] = []
        let channel = app.sourceEvidence?.channel
        // Only an independently established non-default channel can add beta items.
        for item in items {
            if let itemChannel = item.values["channel"], itemChannel != channel { continue }
            if let os = item.enclosure["os"], os != "macos" { continue }
            if let hardware = item.values["hardwareRequirements"] {
                guard hardware == "arm64" else { throw UpdaterError("Unsupported Sparkle hardware requirements. Use the built-in updater.") }
                if architecture != "arm64" { continue }
            }
            if let minimum = item.values["minimumSystemVersion"] {
                guard numeric(minimum), let comparison = ReleaseComparison.compare(macOS, minimum) else { throw UpdaterError("Unsupported minimum Sparkle OS version.") }
                if comparison == .orderedAscending { continue }
            }
            if let maximum = item.values["maximumSystemVersion"] {
                guard numeric(maximum), let comparison = ReleaseComparison.compare(macOS, maximum) else { throw UpdaterError("Unsupported maximum Sparkle OS version.") }
                if comparison == .orderedDescending { continue }
            }
            if let minimum = item.values["minimumUpdateVersion"] {
                guard numeric(minimum), let comparison = ReleaseComparison.compare(app.build, minimum) else { throw UpdaterError("Unsupported minimum Sparkle application build.") }
                if comparison == .orderedAscending { continue }
            }
            guard let build = item.values["version"], numeric(build),
                  item.values["shortVersionString"].map(numeric) ?? true else {
                throw UpdaterError("This Sparkle feed needs a vendor-specific version comparator. Use the built-in updater.")
            }
            guard item.enclosure["url"] != nil || item.link != nil else { throw UpdaterError("Sparkle release has no enclosure or informational link.") }
            if compatible.contains(where: { $0.values["version"] == build && $0.values["shortVersionString"] != item.values["shortVersionString"] }) {
                throw UpdaterError("Conflicting Sparkle releases share a build number.")
            }
            compatible.append(item)
        }
        guard let latest = compatible.max(by: { ReleaseComparison.compare($0.values["version"]!, $1.values["version"]!) == .orderedAscending }) else {
            return SparkleObservation(state: .unsupported, message: "No supported release was found for this OS, architecture and observed channel. Use the application's updater.")
        }
        let build = latest.values["version"]!
        let version = latest.values["shortVersionString"] ?? build
        let scope = channel.map { "default and \($0) channels" } ?? "the default channel"
        let disclaimer = "Read-only embedded-feed observation for \(scope); runtime feed/channel overrides and custom comparators are not observed. Use the application's built-in updater to confirm and install."
        return SparkleObservation(state: ReleaseComparison.compare(app.build, build) == .orderedAscending ? .updateAvailable : .current,
                                  version: version, build: build, message: disclaimer)
    }
    private func numeric(_ value: String) -> Bool {
        value.utf8.count <= 64 && value.range(of: #"\A[0-9]+(?:\.[0-9]+)*\z"#, options: .regularExpression) != nil
    }
}

private struct AppcastItem {
    var values: [String: String] = [:]
    var enclosure: [String: String] = [:]
    var link: String?
}

/// Bounded UTF-8 RSS parser. It never retrieves enclosures, release notes or entities.
private final class AppcastParser: NSObject, XMLParserDelegate {
    private static let sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    private var stack: [(String, String)] = []
    private var text = ""
    private var items: [AppcastItem] = []
    private var current: AppcastItem?
    private var elementCount = 0
    private var problem: String?
    static func read(_ data: Data) throws -> [AppcastItem] {
        guard data.count <= SparkleFeedLoader.maximumBytes, let string = String(data: data, encoding: .utf8),
              !string.contains("\0"), !string.localizedCaseInsensitiveContains("<!DOCTYPE"), !string.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw UpdaterError("Sparkle feeds must be bounded UTF-8 XML without document types or entity declarations.")
        }
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), delegate.problem == nil, !delegate.items.isEmpty else {
            throw UpdaterError(delegate.problem ?? "Malformed or empty Sparkle appcast.")
        }
        return delegate.items
    }
    private func fail(_ parser: XMLParser, _ message: String) { problem = message; parser.abortParsing() }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        elementCount += 1
        guard elementCount <= 20000, stack.count < 16, name.utf8.count <= 256, (namespaceURI ?? "").utf8.count <= 512, attributes.count <= 16,
              attributes.allSatisfy({ $0.key.utf8.count <= 256 && $0.value.utf8.count <= 4096 }) else { fail(parser, "Sparkle XML complexity limit exceeded."); return }
        stack.append((name, namespaceURI ?? "")); text = ""
        if stack.count == 1 && (name != "rss" || !(namespaceURI ?? "").isEmpty) { fail(parser, "Only RSS Sparkle appcasts are supported."); return }
        if name == "item" && (namespaceURI ?? "").isEmpty && stack.count == 3 && stack[1].0 == "channel" && stack[1].1.isEmpty {
            guard items.count < 256 else { fail(parser, "Sparkle item limit exceeded."); return }
            current = AppcastItem()
        }
        guard current != nil else { return }
        if stack.count > 4 && stack[3].1 == Self.sparkle && ["version", "shortVersionString", "channel", "minimumSystemVersion", "maximumSystemVersion", "minimumUpdateVersion", "hardwareRequirements"].contains(stack[3].0) {
            fail(parser, "Nested Sparkle release metadata is unsupported."); return
        }
        if stack.count == 4 && name == "enclosure" && (namespaceURI ?? "").isEmpty {
            guard current!.enclosure.isEmpty else { fail(parser, "Ambiguous multiple Sparkle enclosures."); return }
            current!.enclosure = attributes.filter { !$0.key.contains(":") }
            for attribute in attributes.keys where attribute.contains(":") {
                let pieces = attribute.split(separator: ":", maxSplits: 1).map(String.init)
                if namespaces[pieces[0]] == Self.sparkle && !["version", "shortVersionString", "os", "edSignature", "dsaSignature", "installationType"].contains(pieces[1]) {
                    fail(parser, "Unsupported Sparkle enclosure rule."); return
                }
            }
            for key in ["version", "shortVersionString", "os"] {
                // XMLParser retains qualified attribute names. Resolve their prefix below.
                for (attribute, value) in attributes where attribute.hasSuffix(":" + key) {
                    let prefix = String(attribute.split(separator: ":")[0])
                    if namespaces[prefix] == Self.sparkle {
                        if key == "os" { current!.enclosure[key] = value }
                        else { current!.values[key] = value }
                    }
                }
            }
        }
        if stack.count == 4 && namespaceURI == Self.sparkle {
            let supported = ["version", "shortVersionString", "channel", "minimumSystemVersion", "maximumSystemVersion", "minimumUpdateVersion", "hardwareRequirements", "releaseNotesLink", "fullReleaseNotesLink", "criticalUpdate", "informationalUpdate", "phasedRolloutInterval", "tags", "deltas", "descriptionFormat"]
            if !supported.contains(name) { fail(parser, "Unsupported Sparkle release rule: \(name)."); return }
        }
    }
    private var namespaces: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { namespaces[prefix] = namespaceURI }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { namespaces.removeValue(forKey: prefix) }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard text.utf8.count + string.utf8.count <= 16384 else { fail(parser, "Sparkle text limit exceeded."); return }
        text += string
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let value = String(data: CDATABlock, encoding: .utf8) else { fail(parser, "Unsupported Sparkle text encoding."); return }
        self.parser(parser, foundCharacters: value)
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if current != nil && stack.count == 4 {
            let keys = ["version", "shortVersionString", "channel", "minimumSystemVersion", "maximumSystemVersion", "minimumUpdateVersion", "hardwareRequirements"]
            if namespaceURI == Self.sparkle && keys.contains(name) {
                guard !value.isEmpty, current!.values[name] == nil || current!.values[name] == value else { fail(parser, "Conflicting Sparkle release metadata."); return }
                current!.values[name] = value
            } else if name == "link" && (namespaceURI ?? "").isEmpty { current!.link = value }
        }
        if name == "item" && (namespaceURI ?? "").isEmpty && stack.count == 3, let item = current { items.append(item); current = nil }
        if !stack.isEmpty { stack.removeLast() }
        text = ""
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        fail(parser, "External Sparkle XML entities are prohibited."); return nil
    }
}
