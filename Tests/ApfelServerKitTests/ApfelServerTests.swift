import Foundation
import ApfelServerKit
import Network
import Darwin

func runApfelServerTests() {
    testAsync("start throws .binaryNotFound when no binary is discoverable") {
        let server = ApfelServer(
            portRange: 11600...11609,
            healthTimeout: .milliseconds(200),
            binaryFinder: { nil }
        )
        do {
            _ = try await server.start()
            throw TestFailure("expected throw")
        } catch let error as ApfelServerError {
            try assertEqual(error, .binaryNotFound)
        } catch {
            throw TestFailure("wrong error: \(error)")
        }
        let p = await server.port
        try assertNil(p)
        let managed = await server.isManaged
        try assertFalse(managed)
    }

    testAsync("stop is a no-op when not started") {
        let server = ApfelServer(
            portRange: 11610...11619,
            binaryFinder: { nil }
        )
        await server.stop()
        let p = await server.port
        try assertNil(p)
    }

    testAsync("start throws .noPortAvailable when the whole range is bound") {
        // Reserve four adjacent ephemeral sockets and use exactly that range.
        let held = (0..<4).map { _ in reservePort() }
        defer { for (_, fd) in held { Darwin.close(fd) } }
        let ports = held.map { $0.0 }.sorted()
        guard let lo = ports.first, let hi = ports.last, lo <= hi else {
            throw TestFailure("could not reserve ports")
        }
        // Held sockets may leave gaps; still: if we ask for just one held port,
        // it must be reported unavailable.
        let server = ApfelServer(
            portRange: lo...lo,
            healthTimeout: .milliseconds(200),
            binaryFinder: { "/bin/sleep" }
        )
        do {
            _ = try await server.start()
            throw TestFailure("expected throw")
        } catch let error as ApfelServerError {
            guard case .noPortAvailable = error else {
                throw TestFailure("expected .noPortAvailable, got \(error)")
            }
        } catch {
            throw TestFailure("wrong error: \(error)")
        }
    }

    testAsync("start times out when spawned process never answers /health") {
        // /bin/sleep exists on every mac and swallows args. It'll spawn, never
        // answer /health, then we terminate it via stop().
        let (port, fd) = reservePort()
        Darwin.close(fd)
        let server = ApfelServer(
            portRange: port...port,
            healthTimeout: .milliseconds(500),
            binaryFinder: { "/bin/sleep" }
        )
        let start = Date()
        do {
            _ = try await server.start()
            throw TestFailure("expected timeout")
        } catch let error as ApfelServerError {
            guard case .healthCheckTimeout = error else {
                throw TestFailure("expected .healthCheckTimeout, got \(error)")
            }
        } catch {
            throw TestFailure("wrong error: \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        try assertTrue(elapsed < 3.0, "timeout took too long: \(elapsed)s")
        // stop() should terminate the spawned process cleanly.
        await server.stop()
    }

    testAsync("start connects to an existing healthy server without spawning") {
        // Stand up a tiny NWListener that answers GET /health with HTTP 200.
        let (port, listener) = try await startHealthResponder()
        defer { listener.cancel() }

        let server = ApfelServer(
            portRange: port...port,
            healthTimeout: .seconds(2),
            binaryFinder: { "/nonexistent/apfel" } // would fail if we tried to spawn
        )
        let got = try await server.start()
        try assertEqual(got, port)
        let managed = await server.isManaged
        try assertFalse(managed, "should have connected, not spawned")
        await server.stop() // no-op when not managed
    }
}

// MARK: - Helpers

private func reservePort() -> (Int, Int32) {
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
    let port = Int(UInt16(bigEndian: bound.sin_port))
    return (port, fd)
}

/// Spin up a minimal HTTP responder on 127.0.0.1 that returns `200 OK` for any
/// request. Used to simulate an already-running apfel server.
private func startHealthResponder() async throws -> (Int, NWListener) {
    // Pick a free port explicitly so we can tell the caller which one we used.
    let (port, fd) = reservePort()
    Darwin.close(fd)

    let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(port))!)
    listener.newConnectionHandler = { connection in
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
            let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
            connection.send(
                content: response.data(using: .utf8),
                completion: .contentProcessed { _ in
                    connection.cancel()
                }
            )
        }
    }

    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        nonisolated(unsafe) var resumed = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready where !resumed:
                resumed = true
                cont.resume()
            case .failed(let err) where !resumed:
                resumed = true
                cont.resume(throwing: err)
            default:
                break
            }
        }
        listener.start(queue: .global())
    }
    return (port, listener)
}
