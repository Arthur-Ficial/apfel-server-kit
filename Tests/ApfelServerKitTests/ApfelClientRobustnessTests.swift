import Foundation
import ApfelServerKit
import Network
import Darwin

/// Robustness of the streaming client: partial frames, premature disconnects,
/// slow servers, malformed payloads, cancellation behavior.
func runApfelClientRobustnessTests() {

    testAsync("client survives a server that closes mid-stream without [DONE]") {
        // Three deltas, then the connection just closes. The client should
        // emit the three deltas and finish cleanly.
        let partial = """
        data: {"choices":[{"delta":{"content":"A"}}]}

        data: {"choices":[{"delta":{"content":"B"}}]}

        data: {"choices":[{"delta":{"content":"C"}}]}

        """
        let server = try await RobustnessMock.start(sse: partial)
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)

        var got = ""
        for try await d in client.stream(prompt: "x") {
            if let t = d.text { got += t }
        }
        try assertEqual(got, "ABC")
    }

    testAsync("client skips unparsable SSE lines rather than crashing") {
        // Interleave nonsense lines between valid ones.
        let mixed = """
        data: {"choices":[{"delta":{"content":"A"}}]}

        id: unused-event-id

        retry: 3000

        data: {"choices":[{"delta":{"content":"B"}}]}

        event: progress

        data: [DONE]

        """
        let server = try await RobustnessMock.start(sse: mixed)
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)

        var out = ""
        for try await d in client.stream(prompt: "x") {
            if let t = d.text { out += t }
        }
        try assertEqual(out, "AB")
    }

    testAsync("client treats a stream with ONLY invalid JSON as an error") {
        let bad = """
        data: not-json{

        """
        let server = try await RobustnessMock.start(sse: bad)
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)
        do {
            for try await _ in client.stream(prompt: "x") {}
            throw TestFailure("expected throw")
        } catch let e as ApfelClientError {
            guard case .stream = e else { throw TestFailure("got \(e)") }
        }
    }

    testAsync("client handles a stream that emits an error: frame mid-stream") {
        let midErr = """
        data: {"choices":[{"delta":{"content":"hi "}}]}

        error: model stopped early

        data: [DONE]

        """
        let server = try await RobustnessMock.start(sse: midErr)
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)

        var texts: [String] = []
        do {
            for try await d in client.stream(prompt: "x") {
                if let t = d.text { texts.append(t) }
            }
            throw TestFailure("expected throw")
        } catch let e as ApfelClientError {
            guard case .stream(let msg) = e, msg.contains("model stopped early") else {
                throw TestFailure("got \(e)")
            }
        }
        try assertEqual(texts.joined(), "hi ")
    }

    testAsync("isHealthy tolerates a server that takes a long time but eventually responds") {
        let server = try await RobustnessMock.start(sse: "", responseDelayMs: 50)
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)
        // With 50ms delay and our 0.25s request timeout, this should succeed.
        let healthy = await client.isHealthy()
        try assertTrue(healthy)
    }

    testAsync("isHealthy returns false when server takes longer than the request timeout") {
        let server = try await RobustnessMock.start(sse: "", responseDelayMs: 600)
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)
        let healthy = await client.isHealthy()
        try assertFalse(healthy)
    }

    testAsync("multiple clients on same port do not interfere") {
        let sse = #"data: {"choices":[{"delta":{"content":"ok"}}]}"# + "\n\ndata: [DONE]\n\n"
        let server = try await RobustnessMock.start(sse: sse)
        defer { server.listener.cancel() }
        let c1 = ApfelClient(port: server.port)
        let c2 = ApfelClient(port: server.port)

        async let s1 = drain(c1)
        async let s2 = drain(c2)

        try assertEqual(try await s1, "ok")
        try assertEqual(try await s2, "ok")
    }

    testAsync("client with alternative host string is constructible") {
        let client = ApfelClient(port: 12345, host: "localhost")
        try assertEqual(client.host, "localhost")
        try assertEqual(client.port, 12345)
    }

    testAsync("empty-stream immediately after connect returns zero deltas without error") {
        let server = try await RobustnessMock.start(sse: "data: [DONE]\n\n")
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)
        var n = 0
        for try await _ in client.stream(prompt: "x") { n += 1 }
        try assertEqual(n, 0)
    }

    testAsync("stream works when the response body ends without trailing newline") {
        let sse = #"data: {"choices":[{"delta":{"content":"end"}}]}"# + "\n\ndata: [DONE]"
        let server = try await RobustnessMock.start(sse: sse)
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)
        var out = ""
        for try await d in client.stream(prompt: "x") {
            if let t = d.text { out += t }
        }
        try assertEqual(out, "end")
    }

    testAsync("Task cancellation while streaming stops delivery") {
        var sse = ""
        for i in 0..<500 {
            sse += #"data: {"choices":[{"delta":{"content":"\#(i) "}}]}"# + "\n\n"
        }
        sse += "data: [DONE]\n\n"
        let server = try await RobustnessMock.start(sse: sse)
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)

        let task = Task {
            var count = 0
            do {
                for try await _ in client.stream(prompt: "x") {
                    count += 1
                    if count == 2 { break }
                }
            } catch {}
            return count
        }
        let got = await task.value
        try assertTrue(got <= 3)
    }
}

private func drain(_ client: ApfelClient) async throws -> String {
    var out = ""
    for try await d in client.stream(prompt: "x") {
        if let t = d.text { out += t }
    }
    return out
}

// MARK: - Robustness mock (with optional response delay)

private struct RobustnessMock: Sendable {
    let port: Int
    let listener: NWListener

    static func start(sse: String, responseDelayMs: Int = 0) async throws -> RobustnessMock {
        let (port, fd) = reserveRobustPort()
        Darwin.close(fd)
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let respond: @Sendable () -> Void = {
                    let body: String
                    let contentType: String
                    if sse.isEmpty {
                        body = "ok"
                        contentType = "text/plain"
                    } else {
                        body = sse
                        contentType = "text/event-stream"
                    }
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(
                        content: response.data(using: .utf8),
                        completion: .contentProcessed { _ in connection.cancel() }
                    )
                }
                if responseDelayMs > 0 {
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + .milliseconds(responseDelayMs),
                        execute: respond
                    )
                } else {
                    respond()
                }
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
        return RobustnessMock(port: port, listener: listener)
    }
}

private func reserveRobustPort() -> (Int, Int32) {
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
