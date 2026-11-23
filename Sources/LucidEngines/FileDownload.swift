import Foundation

/// Downloads one file into a `.part` file, continuing from whatever is already in it.
///
/// The `.part` file is kept when the download stops early, so the next download of the same
/// file asks only for the rest. `scripts/setup.sh` names its partial downloads the same way,
/// so either can finish what the other started.
final class FileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    let partial: URL
    private let expectedBytes: Int64?
    private let progress: @Sendable (Int64, Int64?) -> Void

    // Everything below is touched only on `queue`, which runs one operation at a time.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var task: URLSessionDataTask?
    /// The latest response, acted on when its data arrives.
    private var response: HTTPURLResponse?
    /// Open once the response carrying the file has been accepted.
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    /// What was already on disk when this request began.
    private var offset: Int64 = 0
    private var received: Int64 = 0
    private var total: Int64?
    private var failure: Error?
    private var cancelled = false
    private var lastReport = Date.distantPast

    /// `progress` is called about ten times a second with the bytes on disk and the full size, if known.
    init(url: URL, partial: URL, expectedBytes: Int64?, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.url = url
        self.partial = partial
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    /// A session that keeps nothing: no cookies, no cache of a multi-gigabyte file.
    private static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        // How long to wait for the next piece of data, not for the whole file.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 3600
        return configuration
    }

    /// Runs the download to the end. Throws `CancellationError` when the task is cancelled.
    func run() async throws {
        let session = URLSession(configuration: Self.configuration, delegate: self, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        let queue = queue
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    self.continuation = continuation
                    if self.cancelled {
                        self.finish(CancellationError())
                    } else {
                        self.begin(session)
                    }
                }
            }
        } onCancel: {
            queue.addOperation {
                self.cancelled = true
                self.task?.cancel()
            }
        }
    }

    private func begin(_ session: URLSession) {
        let files = FileManager.default
        offset = ((try? files.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if let expectedBytes, offset > expectedBytes {
            try? files.removeItem(at: partial)
            offset = 0
        }
        received = offset
        if let expectedBytes, offset == expectedBytes, offset > 0 {
            // An earlier download got all of it.
            finish(nil)
            return
        }
        if offset == 0, !files.createFile(atPath: partial.path, contents: nil) {
            finish(DownloadError.cannotSave)
            return
        }
        task = session.dataTask(with: request())
        task?.resume()
    }

    private func request(to target: URL? = nil, from original: URLRequest? = nil) -> URLRequest {
        var request = original ?? URLRequest(url: target ?? url)
        request.setValue("Lucid", forHTTPHeaderField: "User-Agent")
        // A compressed reply would not match the sizes Lucid checks.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        return request
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    // MARK: URLSessionDataDelegate

    /// Hugging Face sends file downloads on to its storage servers. The range must go along.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(self.request(from: request))
    }

    /// Notes the response, and waits for its data before acting on it. A proxy's or a
    /// redirect's response can arrive first, and only the last one carries the file.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        if handle == nil, !accept() {
            dataTask.cancel()
            return
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = DownloadError.cannotSave
            dataTask.cancel()
            return
        }
        received += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 0.1 {
            lastReport = now
            progress(received, total)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A response with no body, such as an error, has not been looked at yet.
        if failure == nil, error == nil, handle == nil { _ = accept() }
        try? handle?.close()
        handle = nil
        if let failure {
            finish(failure)
            return
        }
        if let error {
            if cancelled || (error as? URLError)?.code == .cancelled {
                finish(CancellationError())
            } else {
                finish(DownloadError.interrupted(error.localizedDescription))
            }
            return
        }
        progress(received, total)
        if let expected = expectedBytes ?? total, received != expected {
            // Too long means it is not the file Lucid asked for. Too short can be continued.
            if received > expected { truncatePartial() }
            finish(DownloadError.incomplete)
            return
        }
        finish(nil)
    }

    /// Acts on the response that carries the data, and opens the file for it. Returns false,
    /// with `failure` set, when the response is not the file or its rest.
    private func accept() -> Bool {
        guard let http = response else {
            failure = DownloadError.interrupted("Hugging Face sent something that was not a file.")
            return false
        }
        var startOver = false
        switch http.statusCode {
        case 206:
            // The rest of the file. Make sure it starts where the file on disk ends.
            if let range = http.value(forHTTPHeaderField: "Content-Range"), !range.hasPrefix("bytes \(offset)-") {
                startOver = true
                failure = DownloadError.incomplete
            }
        case 200:
            // The whole file, because the server ignored the range or there was none.
            startOver = offset > 0
        case 416:
            // The file on disk is longer than the one on the server, so it is not the same file.
            startOver = true
            failure = DownloadError.incomplete
        default:
            failure = DownloadError.http(http.statusCode)
        }
        if startOver { truncatePartial() }
        if failure != nil { return false }
        let length = http.expectedContentLength
        total = length >= 0 ? received + length : expectedBytes
        do {
            let handle = try FileHandle(forWritingTo: partial)
            try handle.seekToEnd()
            self.handle = handle
        } catch {
            failure = DownloadError.cannotSave
            return false
        }
        return true
    }

    private func truncatePartial() {
        try? handle?.close()
        handle = nil
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        offset = 0
        received = 0
    }
}
