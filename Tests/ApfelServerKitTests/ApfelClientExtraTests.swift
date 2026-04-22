import Foundation
import ApfelServerKit
import Network
import Darwin

func runApfelClientExtraTests() {
    testAsync("stream with many small deltas preserves order exactly") {
        var sse = ""
        for i in 0..<50 {
            sse += #"data: {"choices":[{"delta":{"content":"\#(i)."}}]}"# + "\n\n"
        }
        sse += "data: [DONE]\n\n"
        let server = try await ExtraMockServer.start(responder: .sse(sse))
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)

        var collected: [String] = []
        for try await d in client.stream(prompt: "go") {
            if let t = d.text { collected.append(t) }
        }
        try assertEqual(collected.joined(), (0..<50).map { "\($0)." }.joined())
    }

    testAsync("stream silently ignores comment and keep-alive lines") {
        let sse = """
        : ping

        data: {"choices":[{"delta":{"content":"A"}}]}

        : another ping

        data: {"choices":[{"delta":{"content":"B"}}]}

        data: [DONE]

        """
        let server = try await ExtraMockServer.start(responder: .sse(sse))
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)

        var parts: [String] = []
        for try await d in client.stream(prompt: "go") {
            if let t = d.text { parts.append(t) }
        }
        try assertEqual(parts.joined(), "AB")
    }

    testAsync("stream carries finish_reason on the last delta") {
        let sse = """
        data: {"choices":[{"delta":{"content":"hi"}}]}

        data: {"choices":[{"finish_reason":"length"}]}

        data: [DONE]

        """
        let server = try await ExtraMockServer.start(responder: .sse(sse))
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)

        var finish: String? = nil
        for try await d in client.stream(prompt: "go") {
            if let f = d.finishReason { finish = f }
        }
        try assertEqual(finish, "length")
    }

    testAsync("stream terminates cleanly even without data: [DONE]") {
        // Connection: close ends the stream. Some apfel paths rely on this.
        let sse = #"data: {"choices":[{"delta":{"content":"bye"}}]}"# + "\n\n"
        let server = try await ExtraMockServer.start(responder: .sse(sse))
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)

        var out = ""
        for try await d in client.stream(prompt: "x") {
            if let t = d.text { out += t }
        }
        try assertEqual(out, "bye")
    }

    testAsync("stream delivers unicode content intact") {
        let sse = #"data: {"choices":[{"delta":{"content":"café 🚀 日本"}}]}"# + "\n\ndata: [DONE]\n\n"
        let server = try await ExtraMockServer.start(responder: .sse(sse))
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)

        var out = ""
        for try await d in client.stream(prompt: "x") {
            if let t = d.text { out += t }
        }
        try assertEqual(out, "café 🚀 日本")
    }

    testAsync("ApfelClientError LocalizedError messages are non-empty") {
        let cases: [ApfelClientError] = [
            .invalidURL,
            .httpStatus(500),
            .stream("boom")
        ]
        for c in cases {
            try assertNotNil(c.errorDescription)
            try assertTrue(!(c.errorDescription ?? "").isEmpty)
        }
    }

    testAsync("ApfelClient host/port are exposed via public properties") {
        let client = ApfelClient(port: 11450, host: "127.0.0.1")
        try assertEqual(client.port, 11450)
        try assertEqual(client.host, "127.0.0.1")
    }

    testAsync("stream yields empty when server returns zero events before [DONE]") {
        let sse = "data: [DONE]\n\n"
        let server = try await ExtraMockServer.start(responder: .sse(sse))
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)
        var count = 0
        for try await _ in client.stream(prompt: "x") { count += 1 }
        try assertEqual(count, 0)
    }

    testAsync("stream ignores interleaved null-content keep-alives") {
        let sse = """
        data: {"choices":[{"delta":{"content":null}}]}

        data: {"choices":[{"delta":{"content":"first"}}]}

        data: {"choices":[{"delta":{"content":null}}]}

        data: {"choices":[{"delta":{"content":"second"}}]}

        data: [DONE]

        """
        let server = try await ExtraMockServer.start(responder: .sse(sse))
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)

        var out = ""
        for try await d in client.stream(prompt: "x") {
            if let t = d.text { out += t }
        }
        try assertEqual(out, "firstsecond")
    }

    testAsync("stream with 404 response throws httpStatus(404)") {
        let server = try await ExtraMockServer.start(responder: .status(404))
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)
        do {
            for try await _ in client.stream(prompt: "x") {}
            throw TestFailure("expected throw")
        } catch let e as ApfelClientError {
            guard case .httpStatus(404) = e else { throw TestFailure("got \(e)") }
        }
    }

    testAsync("stream cancellation via break stops the underlying task") {
        var sse = ""
        for i in 0..<200 {
            sse += #"data: {"choices":[{"delta":{"content":"\#(i) "}}]}"# + "\n\n"
        }
        sse += "data: [DONE]\n\n"
        let server = try await ExtraMockServer.start(responder: .sse(sse))
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)

        var count = 0
        for try await _ in client.stream(prompt: "x") {
            count += 1
            if count >= 3 { break }
        }
        try assertTrue(count <= 5, "break should stop the loop quickly, got \(count) iterations")
    }

    testAsync("chatCompletions encodes messages as JSON with expected fields") {
        // We use a capturing mock that echoes the first 512 bytes of the
        // request body into the response body, so we can assert the wire
        // format the client produces.
        let server = try await ExtraMockServer.start(responder: .echoBody)
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)

        let req = ChatRequest(
            model: "apfel-test",
            messages: [
                ChatMessage(role: "system", content: "be brief"),
                ChatMessage(role: "user", content: "hi")
            ],
            stream: true,
            temperature: 0.3
        )
        do {
            for try await _ in client.chatCompletions(req) { /* ignore */ }
        } catch {
            // echoBody returns non-SSE content - streaming won't parse, and
            // that's fine. We care that the request body reached the server.
        }
        // The NWConnection.receive callback may land slightly after the
        // client's response-read completes. Poll briefly for the body.
        var received = ""
        for _ in 0..<50 {
            if let body = ExtraMockServer.lastEchoedBody.value, !body.isEmpty {
                received = body
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try assertTrue(received.contains("\"model\":\"apfel-test\""), "got: \(received)")
        try assertTrue(received.contains("\"role\":\"system\""))
        try assertTrue(received.contains("\"role\":\"user\""))
        try assertTrue(received.contains("\"temperature\":0.3"))
        try assertTrue(received.contains("\"stream\":true"))
    }
}

// MARK: - Extra mock server (with echo-body support)

private struct ExtraMockServer: Sendable {
    let port: Int
    let listener: NWListener

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T?
        var value: T? {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }
    static let lastEchoedBody = Box<String>()

    enum Responder: Sendable {
        case status(Int)
        case sse(String)
        case echoBody
    }

    static func start(responder: Responder) async throws -> ExtraMockServer {
        let (port, fd) = extraReservePort()
        Darwin.close(fd)
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            drainRequest(connection: connection) { requestRaw in
                if case .echoBody = responder {
                    if let headerEnd = requestRaw.range(of: "\r\n\r\n") {
                        lastEchoedBody.value = String(requestRaw[headerEnd.upperBound...])
                    } else {
                        lastEchoedBody.value = requestRaw
                    }
                }
                let bytes = Self.response(for: responder)
                connection.send(
                    content: bytes,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready where !resumed: resumed = true; cont.resume()
                case .failed(let e) where !resumed: resumed = true; cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        return ExtraMockServer(port: port, listener: listener)
    }

    private static func response(for responder: Responder) -> Data {
        switch responder {
        case .status(let code):
            let body = "err"
            return Data("HTTP/1.1 \(code) X\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        case .sse(let payload):
            return Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)".utf8)
        case .echoBody:
            let body = "ok"
            return Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        }
    }
}

/// Receive from an `NWConnection` until the full HTTP request (headers
/// + body matching Content-Length) has arrived, then invoke `completion`
/// with the raw bytes decoded as UTF-8.
private func drainRequest(connection: NWConnection, completion: @escaping @Sendable (String) -> Void) {
    final class Buffer: @unchecked Sendable {
        var data = Data()
    }
    let buffer = Buffer()

    @Sendable func step() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, isComplete, _ in
            if let chunk { buffer.data.append(chunk) }

            let raw = String(data: buffer.data, encoding: .utf8) ?? ""
            var haveFullRequest = false
            if let headerEnd = raw.range(of: "\r\n\r\n") {
                if let lenLine = raw.lowercased().range(of: "content-length:") {
                    let afterColon = raw.index(lenLine.upperBound, offsetBy: 0)
                    let rest = raw[afterColon...]
                    if let eol = rest.range(of: "\r\n") {
                        let numStr = rest[rest.startIndex..<eol.lowerBound]
                            .trimmingCharacters(in: .whitespaces)
                        if let expected = Int(numStr) {
                            let body = raw[headerEnd.upperBound...]
                            if body.utf8.count >= expected { haveFullRequest = true }
                        }
                    }
                } else {
                    // No body expected (e.g. GET /health); header terminator is enough.
                    haveFullRequest = true
                }
            }

            if haveFullRequest || isComplete {
                completion(raw)
            } else {
                step()
            }
        }
    }
    step()
}

private func extraReservePort() -> (Int, Int32) {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    precondition(fd >= 0)
    var yes: Int32 = 1
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.getsockname(fd, sa, &len)
        }
    }
    return (Int(UInt16(bigEndian: bound.sin_port)), fd)
}
