import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import WinSDK
#endif

/// One request to Lucid's local page.
public struct HTTPRequest: Sendable {
    public var method: String
    /// The path without its query, such as `/api/state`.
    public var path: String
    public var query: [String: String]
    /// Header names are lower-cased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Reads the body as JSON.
    public func decode<Value: Decodable>(_ type: Value.Type) -> Value? {
        try? JSONDecoder().decode(type, from: body)
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data

    public init(status: Int = 200, contentType: String, body: Data) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    public static func json<Value: Encodable>(_ value: Value, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: body)
    }

    public static func text(_ text: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, contentType: contentType, body: Data(text.utf8))
    }

    /// An error the page can show: `{"error": "..."}`.
    public static func failure(_ message: String, status: Int = 400) -> HTTPResponse {
        json(["error": message], status: status)
    }
}

public enum LocalServerError: Error, CustomStringConvertible {
    case cannotListen(String)

    public var description: String {
        switch self {
        case .cannotListen(let reason): return "Lucid could not open its local page: \(reason)"
        }
    }
}

/// A very small web server that only this computer can reach. It serves Lucid's window.
///
/// It listens on 127.0.0.1 alone, on a port the system picks, answers one request per
/// connection, and takes requests of a limited size. It is not a general web server.
public final class LocalServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    public let port: Int
    private let listener: SocketHandle
    private let handler: Handler
    private let lock = NSLock()
    private var stopped = false

    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 2 * 1024 * 1024

    /// Opens the port. Nothing is answered until `start()`.
    public init(handler: @escaping Handler) throws {
        self.handler = handler
        Sockets.prepare()
        let socket = Sockets.open()
        guard socket != Sockets.invalid else { throw LocalServerError.cannotListen("no socket") }
        guard let port = Sockets.bindLoopback(socket), Sockets.listen(socket) else {
            Sockets.close(socket)
            throw LocalServerError.cannotListen("no free port")
        }
        listener = socket
        self.port = port
    }

    /// The address of the server, such as `http://127.0.0.1:51234`.
    public var address: String { "http://127.0.0.1:\(port)" }

    /// Starts answering, on background threads.
    public func start() {
        let thread = Thread { [self] in
            while true {
                let client = Sockets.accept(listener)
                if isStopped {
                    if client != Sockets.invalid { Sockets.close(client) }
                    break
                }
                guard client != Sockets.invalid else { continue }
                DispatchQueue.global(qos: .userInitiated).async { [self] in serve(client) }
            }
        }
        thread.name = "Lucid local page"
        thread.start()
    }

    public func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        guard !already else { return }
        // Closing a socket does not wake a thread waiting on it on every system. A connection does.
        Sockets.poke(port: port)
        Sockets.close(listener)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func serve(_ client: SocketHandle) {
        defer { Sockets.close(client) }
        Sockets.configure(client, timeoutSeconds: 10)
        let request: HTTPRequest
        switch Self.read(from: client) {
        case .success(let read): request = read
        case .failure(let refusal):
            Sockets.send(client, Self.serialize(.text("Bad request: \(refusal.reason)", status: 400)))
            return
        }
        // The handler is async. This thread is not one of Swift's own, so it may wait.
        let done = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let handler = handler
        Task {
            box.set(await handler(request))
            done.signal()
        }
        done.wait()
        Sockets.send(client, Self.serialize(box.get()))
    }

    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var response = HTTPResponse.text("No answer", status: 500)

        func set(_ value: HTTPResponse) {
            lock.lock()
            response = value
            lock.unlock()
        }

        func get() -> HTTPResponse {
            lock.lock()
            defer { lock.unlock() }
            return response
        }
    }

    // MARK: Reading and writing HTTP

    /// Why a request was not answered, for whoever is working out what went wrong.
    struct Refusal: Error {
        var reason: String
    }

    private static func read(from client: SocketHandle) -> Result<HTTPRequest, Refusal> {
        var buffer = Data()
        var headerEnd: Int?
        let separator = Data("\r\n\r\n".utf8)
        while headerEnd == nil {
            guard buffer.count <= maxHeaderBytes else { return .failure(Refusal(reason: "its headers are too long")) }
            guard let chunk = Sockets.receive(client), !chunk.isEmpty else {
                return .failure(Refusal(reason: "it ended before its headers did"))
            }
            buffer.append(chunk)
            headerEnd = buffer.range(of: separator)?.lowerBound
        }
        guard let headerEnd, var request = parseHead(buffer.prefix(headerEnd)) else {
            return .failure(Refusal(reason: "it is not an HTTP request"))
        }

        let length = Int(request.headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= maxBodyBytes else { return .failure(Refusal(reason: "its body is too large")) }
        var body = Data(buffer.suffix(from: buffer.startIndex + headerEnd + separator.count))
        // Some clients hold a large body back until the server says it wants it.
        if body.count < length, request.headers["expect"]?.lowercased() == "100-continue" {
            Sockets.send(client, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        while body.count < length {
            guard let chunk = Sockets.receive(client), !chunk.isEmpty else {
                return .failure(Refusal(reason: "only \(body.count) of the \(length) bytes of its body arrived"))
            }
            body.append(chunk)
        }
        request.body = Data(body.prefix(length))
        return .success(request)
    }

    /// Parses the request line and the headers.
    static func parseHead(_ head: Data) -> HTTPRequest? {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        let target = String(parts[1])
        guard target.hasPrefix("/") else { return nil }

        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if pieces.count == 2 {
            for pair in pieces[1].split(separator: "&") {
                let sides = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = decodeQuery(String(sides[0]))
                query[name] = sides.count == 2 ? decodeQuery(String(sides[1])) : ""
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let path = String(pieces[0]).removingPercentEncoding ?? String(pieces[0])
        return HTTPRequest(method: String(parts[0]).uppercased(), path: path, query: query, headers: headers)
    }

    private static func decodeQuery(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    static func serialize(_ response: HTTPResponse) -> Data {
        let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 500: "Internal Server Error"]
        var head = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Status")\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        // The page shows live state. Nothing here should be kept by a browser.
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }
}

// MARK: - Sockets

#if os(Windows)
typealias SocketHandle = SOCKET
#else
typealias SocketHandle = Int32
#endif

/// The socket calls the server needs, which differ between Windows and everything else.
enum Sockets {
    #if os(Windows)
    static let invalid: SocketHandle = ~SOCKET(0)
    #else
    static let invalid: SocketHandle = -1
    #endif

    /// 127.0.0.1 as the four bytes a socket address holds.
    private static var loopback: UInt32 { UInt32(0x7F00_0001).bigEndian }

    /// Windows needs its networking started once per program.
    static func prepare() {
        #if os(Windows)
        var data = WSADATA()
        _ = WSAStartup(0x0202, &data)
        #endif
    }

    static func open() -> SocketHandle {
        #if os(Windows) || canImport(Darwin)
        return socket(AF_INET, SOCK_STREAM, 0)
        #else
        return socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
    }

    /// Binds to 127.0.0.1 on a port the system picks, and returns that port.
    static func bindLoopback(_ socket: SocketHandle) -> Int? {
        var address = sockaddr_in()
        #if os(Windows)
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_addr.S_un.S_addr = loopback
        var length = Int32(MemoryLayout<sockaddr_in>.size)
        #else
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: loopback)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_port = 0

        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) }
        }
        guard bound == 0 else { return nil }
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// Connects to a local port and hangs up, to wake whoever is waiting for a connection.
    static func poke(port: Int) {
        let socket = open()
        guard socket != invalid else { return }
        var address = sockaddr_in()
        #if os(Windows)
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_addr.S_un.S_addr = loopback
        let length = Int32(MemoryLayout<sockaddr_in>.size)
        #else
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: loopback)
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_port = UInt16(port).bigEndian
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, length) }
        }
        close(socket)
    }

    static func listen(_ socket: SocketHandle) -> Bool {
        #if os(Windows)
        return WinSDK.listen(socket, 16) == 0
        #elseif canImport(Darwin)
        return Darwin.listen(socket, 16) == 0
        #elseif canImport(Glibc)
        return Glibc.listen(socket, 16) == 0
        #else
        return Musl.listen(socket, 16) == 0
        #endif
    }

    static func accept(_ socket: SocketHandle) -> SocketHandle {
        #if os(Windows)
        return WinSDK.accept(socket, nil, nil)
        #elseif canImport(Darwin)
        return Darwin.accept(socket, nil, nil)
        #elseif canImport(Glibc)
        return Glibc.accept(socket, nil, nil)
        #else
        return Musl.accept(socket, nil, nil)
        #endif
    }

    /// Gives up on a client that sends nothing, and stops a closed connection ending the program.
    static func configure(_ socket: SocketHandle, timeoutSeconds: Int) {
        #if os(Windows)
        var milliseconds = DWORD(timeoutSeconds * 1000)
        _ = withUnsafePointer(to: &milliseconds) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<DWORD>.size) {
                setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, $0, Int32(MemoryLayout<DWORD>.size))
            }
        }
        #else
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var on: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        #endif
    }

    /// Up to 16 KB from the client. Nil when the connection failed or timed out, empty when it closed.
    static func receive(_ socket: SocketHandle) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count: Int = buffer.withUnsafeMutableBytes { raw in
            #if os(Windows)
            return Int(recv(socket, raw.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(raw.count), 0))
            #else
            return recv(socket, raw.baseAddress, raw.count, 0)
            #endif
        }
        guard count >= 0 else { return nil }
        return Data(buffer.prefix(count))
    }

    static func send(_ socket: SocketHandle, _ data: Data) {
        var sent = 0
        let bytes = [UInt8](data)
        while sent < bytes.count {
            let count: Int = bytes.withUnsafeBytes { raw in
                let start = raw.baseAddress?.advanced(by: sent)
                #if os(Windows)
                return Int(WinSDK.send(socket, start?.assumingMemoryBound(to: CChar.self), Int32(min(bytes.count - sent, 1 << 20)), 0))
                #elseif canImport(Darwin)
                return Darwin.send(socket, start, bytes.count - sent, 0)
                #elseif canImport(Glibc)
                // Without this flag, writing to a client that has gone would end the program.
                return Glibc.send(socket, start, bytes.count - sent, Int32(MSG_NOSIGNAL))
                #else
                return Musl.send(socket, start, bytes.count - sent, Int32(MSG_NOSIGNAL))
                #endif
            }
            guard count > 0 else { return }
            sent += count
        }
    }

    static func close(_ socket: SocketHandle) {
        #if os(Windows)
        closesocket(socket)
        #elseif canImport(Darwin)
        Darwin.shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
        #elseif canImport(Glibc)
        Glibc.shutdown(socket, Int32(SHUT_RDWR))
        Glibc.close(socket)
        #else
        Musl.shutdown(socket, Int32(SHUT_RDWR))
        Musl.close(socket)
        #endif
    }
}
