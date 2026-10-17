import Foundation
import UpdaterCore

final class FixtureCatalogLoader: SourceCatalogLoading {
    var bytes: Data
    var calls = 0
    var failure: Error?
    var delay: UInt64 = 0
    init(bytes: Data) { self.bytes = bytes }
    func load(_ url: URL) async throws -> Data {
        calls += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let failure { throw failure }
        return bytes
    }
}

actor GatedCatalogLoader: SourceCatalogLoading {
    var calls = 0
    var entered = false
    var released = false
    var bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    func release() { released = true }
    func load(_ url: URL) async throws -> Data {
        calls += 1; entered = true
        while !released { try await Task.sleep(nanoseconds: 1_000_000) }
        return bytes
    }
}
