import Foundation
import ApfelServerKit
import Network
import Darwin

func runApfelClientTests() {
    testAsync("isHealthy returns true when /health answers 200") {
        let listener = try await MockApfelServer.start(
            responder: .health200
        )
        defer { listener.listener.cancel() }
        let client = ApfelClient(port: listener.port)
        let healthy = await client.isHealthy()
        try assertTrue(healthy)
    }

    testAsync("isHealthy returns false when nothing is listening") {
        let client = ApfelClient(port: 1)  // reserved, no listener
        let healthy = await client.isHealthy()
        try assertFalse(healthy)
    }

    testAsync("isHealthy returns false on non-200 status") {
        let listener = try await MockApfelServer.start(
            responder: .status(503)
        )
        defer { listener.listener.cancel() }
        let client = ApfelClient(port: listener.port)
        let healthy = await client.isHealthy()
        try assertFalse(healthy)
    }

    testAsync("stream emits deltas in order and finishes on [DONE]") {
        let sse = """
        data: {"choices":[{"delta":{"content":"Hello"}}]}

        data: {"choices":[{"delta":{"content":", world"}}]}

        data: {"choices":[{"finish_reason":"stop"}]}

        data: [DONE]

        """
        let listener = try await MockApfelServer.start(
            responder: .sse(sse)
        )
        defer { listener.listener.cancel() }
        let client = ApfelClient(port: listener.port)

        var collected: [String] = []
        var finish: String? = nil
        for try await delta in client.stream(prompt: "hi") {
            if let t = delta.text { collected.append(t) }
            if let f = delta.finishReason { finish = f }
        }
        try assertEqual(collected.joined(), "Hello, world")
        try assertEqual(finish, "stop")
    }

    testAsync("stream throws ApfelClientError.httpStatus on 4xx") {
        let listener = try await MockApfelServer.start(
            responder: .status(500)
        )
        defer { listener.listener.cancel() }
        let client = ApfelClient(port: listener.port)

        do {
            for try await _ in client.stream(prompt: "hi") {}
            throw TestFailure("expected throw")
        } catch let error as ApfelClientError {
            guard case .httpStatus(500) = error else {
                throw TestFailure("wrong error: \(error)")
            }
        } catch {
            throw TestFailure("wrong error: \(error)")
        }
    }

    testAsync("chatCompletions forwards multi-message requests") {
        let sse = """
        data: {"choices":[{"delta":{"content":"ok"}}]}

        data: [DONE]

        """
        let listener = try await MockApfelServer.start(
            responder: .sse(sse)
        )
        defer { listener.listener.cancel() }
        let client = ApfelClient(port: listener.port)

        let req = ChatRequest(messages: [
            ChatMessage(role: "system", content: "be brief"),
            ChatMessage(role: "user", content: "hi")
        ])
        var texts: [String] = []
        for try await d in client.chatCompletions(req) {
            if let t = d.text { texts.append(t) }
        }
        try assertEqual(texts.joined(), "ok")
    }

    testAsync("stream surfaces SSE .error frames as ApfelClientError.stream") {
        let sse = """
        error: model unavailable

        """
        let listener = try await MockApfelServer.start(
            responder: .sse(sse)
        )
        defer { listener.listener.cancel() }
        let client = ApfelClient(port: listener.port)

        do {
            for try await _ in client.stream(prompt: "hi") {}
            throw TestFailure("expected throw")
        } catch let error as ApfelClientError {
            guard case .stream(let msg) = error, msg.contains("model unavailable") else {
                throw TestFailure("wrong error: \(error)")
            }
        } catch {
            throw TestFailure("wrong error: \(error)")
        }
    }
}

// MARK: - Mock apfel HTTP server

enum MockResponder: Sendable {
    case health200
    case status(Int)
    case sse(String)
}

struct MockApfelServer: Sendable {
    let port: Int
    let listener: NWListener

    static func start(responder: MockResponder) async throws -> MockApfelServer {
        let (port, fd) = reserveMockPort()
        Darwin.close(fd)
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
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
                case .failed(let err) where !resumed: resumed = true; cont.resume(throwing: err)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        return MockApfelServer(port: port, listener: listener)
    }

    private static func response(for responder: MockResponder) -> Data {
        switch responder {
        case .health200:
            return Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
        case .status(let code):
            let body = "err"
            return Data("HTTP/1.1 \(code) X\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        case .sse(let payload):
            let body = payload
            return Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        }
    }
}

private func reserveMockPort() -> (Int, Int32) {
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
