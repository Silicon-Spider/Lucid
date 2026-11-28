import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A model file on Hugging Face that Lucid could download.
public struct RemoteModel: Equatable, Identifiable, Sendable {
    /// The repository, as "owner/name".
    public var repo: String
    /// The branch, tag or commit.
    public var revision: String
    /// The file's path inside the repository.
    public var path: String
    /// The size in bytes, when Hugging Face reports it.
    public var bytes: Int64?
    public var kind: ModelKind

    public init(repo: String, revision: String = "main", path: String, bytes: Int64?, kind: ModelKind) {
        self.repo = repo
        self.revision = revision
        self.path = path
        self.bytes = bytes
        self.kind = kind
    }

    public var id: String { "\(repo)@\(revision)/\(path)" }

    /// The name the file gets in Lucid's models folder.
    public var fileName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// Why a model could not be found or downloaded, in words the user can act on.
public enum DownloadError: Error, Equatable, CustomStringConvertible {
    /// The repository does not exist, or is private or gated. Hugging Face does not say which.
    case unavailable(String)
    /// The file needs a signed-in account, usually to accept the model's licence.
    case needsAccess(String)
    case fileNotFound(String)
    case noModelFiles(String)
    case http(Int)
    /// Hugging Face could not be reached.
    case network(String)
    /// A download stopped part way. It can be continued.
    case interrupted(String)
    /// The file could not be written to the models folder.
    case cannotSave
    /// The file that arrived is not the size Hugging Face said it would be.
    case incomplete
    case notEnoughSpace(needed: Int64, free: Int64)

    public var description: String {
        switch self {
        case .unavailable(let repo):
            return "Hugging Face has no public model called \(repo). Check the name. "
                + "Private and gated models cannot be downloaded in Lucid."
        case .needsAccess(let repo):
            return "\(repo) asks you to sign in on huggingface.co and accept its licence first, and Lucid "
                + "only downloads public models. Download it in your browser, then add the file under Models in Lucid's window."
        case .fileNotFound(let path):
            return "\(path) is not in that model's files, or it is not a file Lucid can use."
        case .noModelFiles(let repo):
            return "\(repo) has no files Lucid can use. Lucid needs a single .gguf file for cleanup, "
                + "or a whisper.cpp ggml .bin file for speech."
        case .http(let code):
            return "Hugging Face answered with an error (HTTP \(code)). Try again later."
        case .network(let reason):
            return "Lucid could not reach Hugging Face. \(reason)"
        case .interrupted(let reason):
            return "The download stopped. \(reason) Downloading again continues where it stopped."
        case .cannotSave:
            return "Lucid could not save the model in its models folder. The disk may be full."
        case .incomplete:
            return "The file that arrived was not complete. Try downloading it again."
        case .notEnoughSpace(let needed, let free):
            let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return "There is not enough free disk space. The model needs \(format(needed)), and \(format(free)) is free."
        }
    }
}

/// Finds model files on Hugging Face. Lucid only reads public files, and sends no account
/// details, token or anything about the user.
public struct HuggingFace: Sendable {
    public static let website = URL(string: "https://huggingface.co")!

    /// The site to talk to. Tests point this at a local server.
    public let baseURL: URL

    public init(baseURL: URL = HuggingFace.website) {
        self.baseURL = baseURL
    }

    /// A repository, and optionally one file in it, as the user typed or pasted it.
    public struct Reference: Equatable, Sendable {
        public var repo: String
        public var revision: String
        public var path: String?

        public init(repo: String, revision: String = "main", path: String? = nil) {
            self.repo = repo
            self.revision = revision
            self.path = path
        }
    }

    private static let hosts: Set<String> = ["huggingface.co", "www.huggingface.co", "hf.co"]

    /// Reads "owner/name", a link to a model on Hugging Face, or a link to one of its files.
    public static func parse(_ input: String) -> Reference? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if hosts.contains(where: { text.lowercased().hasPrefix($0 + "/") }) { text = "https://" + text }

        guard text.contains("://") else {
            let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, parts.allSatisfy(isName) else { return nil }
            return Reference(repo: parts.joined(separator: "/"))
        }

        guard let url = URL(string: text),
              url.scheme == "https" || url.scheme == "http",
              let host = url.host?.lowercased(), hosts.contains(host) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        // Datasets and Spaces share the site but hold no models Lucid can use.
        guard parts.count >= 2, parts.prefix(2).allSatisfy(isName), !["datasets", "spaces"].contains(parts[0]) else {
            return nil
        }
        var reference = Reference(repo: "\(parts[0])/\(parts[1])")
        let rest = Array(parts.dropFirst(2))
        if rest.count >= 2, ["blob", "resolve", "tree"].contains(rest[0]) {
            reference.revision = rest[1]
            if rest[0] != "tree", rest.count >= 3 {
                reference.path = rest.dropFirst(2).joined(separator: "/")
            }
        }
        return reference
    }

    /// Letters, digits, and the punctuation Hugging Face allows in names.
    private static func isName(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 96
            && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
            && text != "." && text != ".."
    }

    /// Which kind of model a file looks like, from its name alone. Nil for files Lucid cannot
    /// use: weights for other tools, vision add-ons, and models split into several files.
    public static func kind(ofPath path: String) -> ModelKind? {
        let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        if name.hasSuffix(".gguf") {
            if name.contains("mmproj") { return nil }
            if name.range(of: #"-\d{5}-of-\d{5}\.gguf$"#, options: .regularExpression) != nil { return nil }
            return .cleanup
        }
        // whisper.cpp's models are named ggml-something.bin. Other .bin files are PyTorch weights.
        if name.hasSuffix(".bin"), name.hasPrefix("ggml") { return .speech }
        return nil
    }

    /// The model's page, where its description and licence are.
    public func pageURL(repo: String) -> URL {
        baseURL.appendingPathComponent(repo)
    }

    public func downloadURL(for model: RemoteModel) -> URL {
        var url = baseURL.appendingPathComponent(model.repo).appendingPathComponent("resolve")
            .appendingPathComponent(model.revision)
        for part in model.path.split(separator: "/") { url.appendPathComponent(String(part)) }
        return url
    }

    private struct Entry: Decodable {
        struct LFS: Decodable {
            let size: Int64?
        }

        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?
    }

    /// The files Lucid could use in a repository, or just the one file the reference names.
    public func modelFiles(in reference: Reference) async throws -> [RemoteModel] {
        let revision = reference.revision.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? reference.revision
        var next = URL(string: "\(baseURL.absoluteString)/api/models/\(reference.repo)/tree/\(revision)?recursive=true")
        var entries: [Entry] = []
        var pages = 0
        while let url = next, pages < 20 {
            pages += 1
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("Lucid", forHTTPHeaderField: "User-Agent")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw DownloadError.network(error.localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: break
            case 401, 403, 404: throw DownloadError.unavailable(reference.repo)
            default: throw DownloadError.http(status)
            }
            guard let page = try? JSONDecoder().decode([Entry].self, from: data) else {
                throw DownloadError.http(status)
            }
            entries += page
            next = (response as? HTTPURLResponse).flatMap { Self.nextPage($0.value(forHTTPHeaderField: "Link")) }
        }

        var files = entries.compactMap { entry -> RemoteModel? in
            guard entry.type == "file", let kind = Self.kind(ofPath: entry.path) else { return nil }
            return RemoteModel(
                repo: reference.repo, revision: reference.revision, path: entry.path,
                bytes: entry.lfs?.size ?? entry.size, kind: kind
            )
        }
        if let path = reference.path {
            files = files.filter { $0.path == path }
            if files.isEmpty { throw DownloadError.fileNotFound(path) }
        }
        if files.isEmpty { throw DownloadError.noModelFiles(reference.repo) }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The `rel="next"` address in a `Link` header, which Hugging Face sends when a list continues.
    public static func nextPage(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") where part.contains("rel=\"next\"") {
            guard let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">"), open < close else { continue }
            return URL(string: String(part[part.index(after: open)..<close]))
        }
        return nil
    }
}
