import Foundation
import ApfelServerKit
import Network
import Darwin

/// Hammer the actor and client with many concurrent operations to surface
/// race conditions, dropped events, or state leaks.
func runConcurrencyStressTests() {

    testAsync("100 concurrent ApfelBinaryFinder.find calls return stable results") {
        // ApfelBinaryFinder is stateless but still gets hammered in real apps.
        let env: [String: String] = ["PATH": "/one:/two", "HOME": "/Users/stub"]
        let existing: Set<String> = ["/two/apfel"]
        try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    ApfelBinaryFinder.find(
                        name: "apfel",
                        environment: env,
                        bundleExecutableURL: nil,
                        fileExists: { existing.contains($0) }
                    )
                }
            }
            for try await result in group {
                try assertEqual(result, "/two/apfel")
            }
        }
    }

    testAsync("100 concurrent PortScanner.isAvailable calls do not leak FDs") {
        // Sanity: the socket+close probe must not run us out of FDs.
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask { PortScanner.isAvailable(0) }
            }
            for try await _ in group {}
        }
    }

    testAsync("concurrent ApfelServer.stop() under load is safe") {
        let server = ApfelServer(
            portRange: 13000...13009,
            binaryFinder: { nil }
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask { await server.stop() }
            }
        }
        let p = await server.port
        try assertNil(p)
    }

    testAsync("concurrent SSEParser.parse calls with different inputs all succeed") {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            let lines = [
                "data: [DONE]",
                #"data: {"choices":[{"delta":{"content":"hi"}}]}"#,
                ": ping",
                "",
                #"data: {"choices":[{"finish_reason":"stop"}]}"#
            ]
            for _ in 0..<200 {
                for line in lines {
                    group.addTask {
                        _ = SSEParser.parse(line: line)
                        return true
                    }
                }
            }
            var n = 0
            for try await _ in group { n += 1 }
            try assertEqual(n, 200 * 5)
        }
    }

    testAsync("10 concurrent ApfelClient.stream calls each receive their deltas") {
        let sse = """
        data: {"choices":[{"delta":{"content":"A"}}]}

        data: {"choices":[{"delta":{"content":"B"}}]}

        data: [DONE]

        """
        let server = try await StressMockServer.start(sse: sse)
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)

        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    var buf = ""
                    do {
                        for try await d in client.stream(prompt: "x") {
                            if let t = d.text { buf += t }
                        }
                    } catch {
                        buf = "ERR: \(error)"
                    }
                    return buf
                }
            }
            for try await out in group {
                try assertEqual(out, "AB")
            }
        }
    }

    testAsync("ApfelServer config values are safe to read concurrently while other tasks call stop()") {
        let server = ApfelServer(
            portRange: 14000...14010,
            healthTimeout: .seconds(1),
            arguments: ["--cors"],
            binaryFinder: { nil }
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    // These are `nonisolated let` so this is safe without await.
                    _ = server.portRange
                    _ = server.arguments
                    _ = server.host
                    _ = server.healthTimeout
                }
            }
            for _ in 0..<20 {
                group.addTask { await server.stop() }
            }
        }
    }
}

// MARK: - Stress mock server

private struct StressMockServer: Sendable {
    let port: Int
    let listener: NWListener

    static func start(sse: String) async throws -> StressMockServer {
        let (port, fd) = reserveStressPort()
        Darwin.close(fd)
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let body = sse
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
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
        return StressMockServer(port: port, listener: listener)
    }
}

private func reserveStressPort() -> (Int, Int32) {
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
