import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LucidApp

/// Sends one request to a local server and returns the status and body.
func fetch(_ address: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) async throws -> (Int, Data) {
    var request = URLRequest(url: URL(string: address)!)
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = 20
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
}

func localServerTests() async {
    await asyncSuite("Local server") {
        await asyncTest("answers requests, with their path, query, headers and body") {
            let server = try LocalServer { request in
                let summary = [
                    request.method, request.path, request.query["q"] ?? "-", request.headers["x-test"] ?? "-",
                    String(decoding: request.body, as: UTF8.self),
                ]
                return .text(summary.joined(separator: "|"))
            }
            server.start()
            defer { server.stop() }

            let (status, body) = try await fetch(server.address + "/a%20b/c?q=two+words%21&x=1", headers: ["X-Test": "yes"])
            expectEqual(status, 200)
            expectEqual(String(decoding: body, as: UTF8.self), "GET|/a b/c|two words!|yes|")

            let sent = Data(String(repeating: "héllo ", count: 20_000).utf8)
            let (postStatus, echoed) = try await fetch(server.address + "/post", method: "POST", body: sent)
            expectEqual(postStatus, 200)
            expectEqual(String(decoding: echoed, as: UTF8.self), "POST|/post|-|-|" + String(decoding: sent, as: UTF8.self))
        }

        await asyncTest("answers several requests at once") {
            let server = try LocalServer { request in
                try? await Task.sleep(nanoseconds: 100_000_000)
                return .json(["path": request.path])
            }
            server.start()
            defer { server.stop() }
            let began = Date()
            try await withThrowingTaskGroup(of: String.self) { group in
                for index in 0..<8 {
                    group.addTask {
                        let (_, body) = try await fetch(server.address + "/\(index)")
                        return String(decoding: body, as: UTF8.self)
                    }
                }
                var answers: Set<String> = []
                for try await answer in group { answers.insert(answer) }
                expectEqual(answers.count, 8)
                expectTrue(answers.contains(#"{"path":"\/3"}"#) || answers.contains(#"{"path":"/3"}"#), "\(answers)")
            }
            // One after another they would take 0.8 s.
            expectTrue(Date().timeIntervalSince(began) < 0.7, "took \(Date().timeIntervalSince(began)) s")
        }

        await asyncTest("refuses a body that is too large") {
            let server = try LocalServer { _ in .text("ok") }
            server.start()
            defer { server.stop() }
            do {
                let (status, _) = try await fetch(server.address + "/big", method: "POST", body: Data(count: 3 * 1024 * 1024))
                expectEqual(status, 400)
            } catch {
                // The server may hang up before the whole body is sent, which is also a refusal.
                expectTrue(true)
            }
            let (status, _) = try await fetch(server.address + "/still-there")
            expectEqual(status, 200)
        }

        await asyncTest("stops answering when stopped") {
            let server = try LocalServer { _ in .text("ok") }
            server.start()
            let (status, _) = try await fetch(server.address + "/")
            expectEqual(status, 200)
            server.stop()
            server.stop()
            do {
                _ = try await fetch(server.address + "/")
                expectTrue(false, "expected the connection to be refused")
            } catch {
                expectTrue(true)
            }
        }
    }
}
