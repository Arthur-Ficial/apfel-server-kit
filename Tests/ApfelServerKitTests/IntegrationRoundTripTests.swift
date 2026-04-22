import Foundation
import ApfelServerKit
import Network
import Darwin

/// End-to-end round-trip: spin a listener that speaks HTTP /health + SSE,
/// have `ApfelServer` attach to it (no real apfel binary needed), then
/// stream through `ApfelClient`, all the way from prompt to reassembled text.
///
/// This is the highest-value test in the package - if all the unit tests
/// pass but this one fails, something in the wiring between pieces broke.
func runIntegrationRoundTripTests() {

    testAsync("end-to-end: attach to existing server, stream, reassemble text") {
        let sseBody = """
        data: {"choices":[{"delta":{"content":"The "}}]}

        data: {"choices":[{"delta":{"content":"quick "}}]}

        data: {"choices":[{"delta":{"content":"brown "}}]}

        data: {"choices":[{"delta":{"content":"fox"}}]}

        data: {"choices":[{"finish_reason":"stop"}]}

        data: [DONE]

        """
        let mock = try await IntegrationMock.start(sse: sseBody)
        defer { mock.listener.cancel() }

        let server = ApfelServer(
            portRange: mock.port...mock.port,
            healthTimeout: .seconds(2),
            binaryFinder: { "/nonexistent/apfel" } // would fail if we tried to spawn
        )
        let port = try await server.start()
        try assertEqual(port, mock.port)
        let managed = await server.isManaged
        try assertFalse(managed, "should have attached, not spawned")

        let client = ApfelClient(port: port)
        let healthy = await client.isHealthy()
        try assertTrue(healthy)

        var text = ""
        var finish: String? = nil
        for try await delta in client.stream(prompt: "write me a fox") {
            if let t = delta.text { text += t }
            if let f = delta.finishReason { finish = f }
        }
        try assertEqual(text, "The quick brown fox")
        try assertEqual(finish, "stop")
        await server.stop()
    }

    testAsync("end-to-end: chatCompletions with full ChatRequest round-trips") {
        let sseBody = """
        data: {"choices":[{"delta":{"content":"ok"}}]}

        data: {"choices":[{"finish_reason":"stop"}]}

        data: [DONE]

        """
        let mock = try await IntegrationMock.start(sse: sseBody)
        defer { mock.listener.cancel() }

        let server = ApfelServer(
            portRange: mock.port...mock.port,
            binaryFinder: { "/nonexistent/apfel" }
        )
        let port = try await server.start()
        let client = ApfelClient(port: port)

        let req = ChatRequest(
            model: "apfel",
            messages: [
                ChatMessage(role: "system", content: "be brief"),
                ChatMessage(role: "user", content: "hi")
            ],
            stream: true,
            temperature: 0.5
        )
        var out = ""
        for try await d in client.chatCompletions(req) {
            if let t = d.text { out += t }
        }
        try assertEqual(out, "ok")
        await server.stop()
    }

    testAsync("end-to-end: starting against a non-responding server yields healthCheckTimeout, and stream against it fails cleanly") {
        // Reserve a port - nothing listens on it. ApfelServer will try to
        // spawn /bin/sleep and wait for /health which never answers.
        let (port, fd) = reserveIntegrationPort()
        Darwin.close(fd)
        let server = ApfelServer(
            portRange: port...port,
            healthTimeout: .milliseconds(300),
            binaryFinder: { "/bin/sleep" }
        )
        do {
            _ = try await server.start()
            throw TestFailure("expected timeout")
        } catch let e as ApfelServerError {
            guard case .healthCheckTimeout = e else {
                throw TestFailure("got \(e)")
            }
        }
        await server.stop()
    }
}

// MARK: - Integration mock

private struct IntegrationMock: Sendable {
    let port: Int
    let listener: NWListener

    static func start(sse: String) async throws -> IntegrationMock {
        let (port, fd) = reserveIntegrationPort()
        Darwin.close(fd)
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let response: String
                if raw.contains("GET /health") {
                    response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                } else {
                    // /v1/chat/completions
                    response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(sse.utf8.count)\r\nConnection: close\r\n\r\n\(sse)"
                }
                connection.send(
                    content: response.data(using: .utf8),
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
        return IntegrationMock(port: port, listener: listener)
    }
}

private func reserveIntegrationPort() -> (Int, Int32) {
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
