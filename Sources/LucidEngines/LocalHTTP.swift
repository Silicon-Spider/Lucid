import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP to the engines on this machine.
enum LocalHTTP {
    /// A session that never uses a system proxy, so local requests stay local.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }()
}
