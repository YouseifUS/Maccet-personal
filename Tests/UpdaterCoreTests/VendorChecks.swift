import Foundation
@_spi(Testing) import UpdaterCore

final class FixtureVendorLoader: MetadataLoading {
    var urls: [URL] = []
    var bytes: Data
    var failure: Error?
    var beforeReturn: (() throws -> Void)?
    init(bytes: Data) { self.bytes = bytes }
    func load(_ url: URL, maximumBytes: Int, mimeTypes: [String]) async throws -> Data {
        urls.append(url)
        if maximumBytes != 512 * 1024 || mimeTypes != ["application/json"] { throw UpdaterError("Unexpected vendor transport policy") }
        try beforeReturn?()
        if let failure { throw failure }
        return bytes
    }
}

func vendorRelease(_ version: String, platform: String = "mac_arm64", channel: String = "stable", fraction: Double = 1, end: String? = nil, start: String = "2020-01-01T00:00:00Z") -> [String: Any] {
    var serving = ["startTime": start]; serving["endTime"] = end
    return ["name": "chrome/platforms/\(platform)/channels/\(channel)/versions/\(version)/releases/1234", "version": version, "fraction": fraction, "serving": serving]
}
func vendorJSON(_ releases: [[String: Any]], token: String? = nil) throws -> Data {
    var object: [String: Any] = ["releases": releases]; object["nextPageToken"] = token
    return try JSONSerialization.data(withJSONObject: object)
}
