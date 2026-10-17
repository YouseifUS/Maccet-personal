import Foundation

/// Shared bounded read-only transport. Publisher authenticity is established by consumers.
public protocol MetadataLoading {
    func load(_ url: URL, maximumBytes: Int, mimeTypes: [String]) async throws -> Data
}

public struct BoundedMetadataLoader: MetadataLoading {
    private var protocolClasses: [AnyClass]?
    public init() {}
    @_spi(Testing) public init(protocolClasses: [AnyClass]) { self.protocolClasses = protocolClasses }
    public static func validateURL(_ url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              url.absoluteString.utf8.count <= 2048, parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443, let host = parts.host?.lowercased(),
              host.range(of: #"\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z"#, options: .regularExpression) != nil,
              !["localhost", "local", "internal", "home", "lan", "test", "invalid"].contains(host.split(separator: ".").last.map(String.init) ?? "") else {
            throw UpdaterError("Metadata requests require a public HTTPS hostname without credentials, a fragment or a custom port.")
        }
    }
    public func load(_ url: URL, maximumBytes: Int, mimeTypes: [String]) async throws -> Data {
        guard maximumBytes > 0, maximumBytes <= 2 * 1024 * 1024, !mimeTypes.isEmpty else { throw UpdaterError("Invalid metadata response policy.") }
        try Self.validateURL(url)
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: NoMetadataRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(mimeTypes.joined(separator: ", "), forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == url, response.expectedContentLength <= Int64(maximumBytes),
              mimeTypes.contains(response.mimeType?.lowercased() ?? "") else {
            throw UpdaterError("Metadata response was redirected, unsuccessful, oversized or had an unsupported content type.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw UpdaterError("Metadata response exceeded its bounded size limit.") }
            data.append(byte)
            if data.count % 4096 == 0 { try Task.checkCancellation() }
        }
        return data
    }
}

private final class NoMetadataRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // TLS uses platform trust; HTTP authentication is never requested from the user.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

