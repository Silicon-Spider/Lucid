import Foundation

public enum EngineError: Error, Equatable, CustomStringConvertible {
    /// A binary or a model file is not installed.
    case missing(String)
    case launchFailed(String)
    case notReady(String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .missing(let detail): return "Missing: \(detail)"
        case .launchFailed(let detail): return "Could not start: \(detail)"
        case .notReady(let detail): return "Not ready: \(detail)"
        case .badResponse(let detail): return "Unexpected reply: \(detail)"
        }
    }
}
