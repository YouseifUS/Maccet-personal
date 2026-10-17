import Foundation
@_spi(Testing) import UpdaterCore

final class FixtureFeedLoader: SparkleFeedLoading {
    var requested: [URL] = []
    var bytes: Data
    init(_ text: String) { bytes = Data(text.utf8) }
    func load(_ url: URL) async throws -> Data { requested.append(url); return bytes }
}

final class FixtureFeedProtocol: URLProtocol {
    static var responseStatus = 200
    static var responseHeaders = ["Content-Type": "application/rss+xml"]
    static var responseData = Data("<rss/>".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseStatus, httpVersion: "HTTP/1.1", headerFields: Self.responseHeaders)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func appcast(_ items: String) -> Data {
    Data(("<rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel>" + items + "</channel></rss>").utf8)
}
func feedItem(_ build: String = "20", version: String = "2.0", rules: String = "") -> String {
    "<item><sparkle:version>\(build)</sparkle:version><sparkle:shortVersionString>\(version)</sparkle:shortVersionString>\(rules)<enclosure url=\"https://downloads.example.com/app.zip\"/></item>"
}
