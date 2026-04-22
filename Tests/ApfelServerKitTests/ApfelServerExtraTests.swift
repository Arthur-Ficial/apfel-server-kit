import Foundation
import ApfelServerKit
import Network
import Darwin

func runApfelServerExtraTests() {
    testAsync("concurrent stop() calls are safe") {
        let server = ApfelServer(
            portRange: 12000...12009,
            binaryFinder: { nil }
        )
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await server.stop() }
            }
        }
        let p = await server.port
        try assertNil(p)
    }

    testAsync("stop() after health-timeout cleanup is idempotent") {
        let (port, fd) = reserveExtraPort()
        Darwin.close(fd)
        let server = ApfelServer(
            portRange: port...port,
            healthTimeout: .milliseconds(400),
            binaryFinder: { "/bin/sleep" }
        )
        do { _ = try await server.start() } catch { /* expected timeout */ }
        await server.stop()
        await server.stop()  // second call must not crash
    }

    testAsync("start surfaces .spawnFailed when binary is unlaunchable") {
        let (port, fd) = reserveExtraPort()
        Darwin.close(fd)
        // Point to a file that exists but is not executable - Process.run()
        // throws NSError with domain NSCocoaErrorDomain.
        let nonExec = "/etc/hosts"  // exists on every macOS, not executable
        let server = ApfelServer(
            portRange: port...port,
            healthTimeout: .milliseconds(200),
            binaryFinder: { nonExec }
        )
        do {
            _ = try await server.start()
            throw TestFailure("expected spawnFailed")
        } catch let error as ApfelServerError {
            guard case .spawnFailed = error else {
                throw TestFailure("got \(error) not .spawnFailed")
            }
        } catch {
            throw TestFailure("wrong error: \(error)")
        }
    }

    testAsync("port is set to the connected-existing port") {
        let (port, listener) = try await startExtraResponder()
        defer { listener.cancel() }
        let server = ApfelServer(
            portRange: port...port,
            healthTimeout: .seconds(2),
            binaryFinder: { "/nonexistent" }
        )
        _ = try await server.start()
        let actual = await server.port
        try assertEqual(actual, port)
    }

    testAsync("configuration values round-trip through init") {
        let server = ApfelServer(
            portRange: 19000...19010,
            healthTimeout: .seconds(3),
            arguments: ["--cors"],
            host: "127.0.0.2",
            binaryFinder: { nil }
        )
        try assertEqual(server.portRange, 19000...19010)
        try assertEqual(server.arguments, ["--cors"])
        try assertEqual(server.host, "127.0.0.2")
    }

    testAsync("start() twice on an already-attached server reuses the connection") {
        let (port, listener) = try await startExtraResponder()
        defer { listener.cancel() }
        let server = ApfelServer(
            portRange: port...port,
            binaryFinder: { "/nonexistent" }
        )
        let p1 = try await server.start()
        let p2 = try await server.start()
        try assertEqual(p1, p2)
        let managed = await server.isManaged
        try assertFalse(managed)
    }

    testAsync("ApfelServerError LocalizedError messages are non-empty") {
        let cases: [ApfelServerError] = [
            .binaryNotFound,
            .noPortAvailable(11450...11459),
            .spawnFailed("boom"),
            .healthCheckTimeout(port: 11450, seconds: 8.0)
        ]
        for c in cases {
            try assertNotNil(c.errorDescription)
            try assertTrue(!(c.errorDescription ?? "").isEmpty)
        }
    }

    testAsync("health timeout error carries the polled port") {
        let (port, fd) = reserveExtraPort()
        Darwin.close(fd)
        let server = ApfelServer(
            portRange: port...port,
            healthTimeout: .milliseconds(300),
            binaryFinder: { "/bin/sleep" }
        )
        do {
            _ = try await server.start()
            throw TestFailure("expected timeout")
        } catch let error as ApfelServerError {
            guard case .healthCheckTimeout(let p, _) = error else {
                throw TestFailure("got \(error)")
            }
            try assertEqual(p, port)
        } catch {
            throw TestFailure("wrong error: \(error)")
        }
        await server.stop()
    }

    testAsync(".noPortAvailable carries the configured range") {
        let (port, fd) = reserveExtraPort()
        defer { Darwin.close(fd) }
        let server = ApfelServer(
            portRange: port...port,
            binaryFinder: { "/bin/sleep" }
        )
        do {
            _ = try await server.start()
            throw TestFailure("expected throw")
        } catch let error as ApfelServerError {
            guard case .noPortAvailable(let range) = error else {
                throw TestFailure("got \(error)")
            }
            try assertEqual(range, port...port)
        } catch {
            throw TestFailure("wrong: \(error)")
        }
    }
}

// MARK: - Helpers

private func reserveExtraPort() -> (Int, Int32) {
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

private func startExtraResponder() async throws -> (Int, NWListener) {
    let (port, fd) = reserveExtraPort()
    Darwin.close(fd)
    let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(port))!)
    listener.newConnectionHandler = { connection in
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
            let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
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
    return (port, listener)
}
