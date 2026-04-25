import Foundation
import ApfelServerKit
import Network
import Darwin

/// Lifecycle edges: start -> stop -> start, zero-timeout, unusual configs.
func runApfelServerLifecycleTests() {

    testAsync("start -> stop -> start again with existing server attaches cleanly") {
        let (port, listener) = try await startLifecycleResponder()
        defer { listener.cancel() }
        let server = ApfelServer(
            portRange: port...port,
            binaryFinder: { "/nonexistent" }
        )
        let p1 = try await server.start()
        try assertEqual(p1, port)
        await server.stop()
        let p2 = try await server.start()
        try assertEqual(p2, port)
        await server.stop()
    }

    testAsync("healthTimeout of zero fails fast when spawned") {
        let (port, fd) = reserveLifecyclePort()
        Darwin.close(fd)
        let server = ApfelServer(
            portRange: port...port,
            healthTimeout: .zero,
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

    testAsync("custom arguments are passed after --port") {
        // We can't inspect the spawned process directly without help - this
        // test simply asserts the config value is remembered.
        let args = ["--cors", "--permissive", "--my-extra-flag"]
        let server = ApfelServer(
            portRange: 15000...15009,
            arguments: args,
            binaryFinder: { nil }
        )
        try assertEqual(server.arguments, args)
    }

    testAsync("empty arguments array is accepted") {
        let server = ApfelServer(
            portRange: 15010...15019,
            arguments: [],
            binaryFinder: { nil }
        )
        try assertEqual(server.arguments, [])
    }

    testAsync("wide port range does not fail the attach scan") {
        // A 100-port range still probes in order and finds the responder.
        let (port, listener) = try await startLifecycleResponder()
        defer { listener.cancel() }
        let lo = max(1024, port - 5)
        let hi = port + 5
        let server = ApfelServer(
            portRange: lo...hi,
            binaryFinder: { "/nonexistent" }
        )
        let got = try await server.start()
        try assertEqual(got, port)
        await server.stop()
    }

    testAsync("custom host value round-trips via public property") {
        let server = ApfelServer(
            portRange: 16000...16010,
            host: "127.0.0.5",
            binaryFinder: { nil }
        )
        try assertEqual(server.host, "127.0.0.5")
    }

    testAsync("stop() after attach-mode start() does not kill the external server") {
        let (port, listener) = try await startLifecycleResponder()
        defer { listener.cancel() }
        let server = ApfelServer(
            portRange: port...port,
            binaryFinder: { "/nonexistent" }
        )
        _ = try await server.start()
        await server.stop()
        // External listener is still ours to cancel - verify it's still up.
        let probe = ApfelClient(port: port)
        try assertTrue(await probe.isHealthy(), "external listener should survive our stop()")
    }

    testAsync("port is nil after a failed start()") {
        let (port, fd) = reserveLifecyclePort()
        defer { Darwin.close(fd) }
        let server = ApfelServer(
            portRange: port...port,
            binaryFinder: { "/bin/sleep" }
        )
        do { _ = try await server.start() } catch { /* expected */ }
        let p = await server.port
        try assertNil(p)
    }

    testAsync("start() is idempotent — second call returns cached port without re-probing") {
        let (port, listener) = try await startLifecycleResponder()
        let server = ApfelServer(
            portRange: port...port,
            binaryFinder: { "/nonexistent" }
        )
        let p1 = try await server.start()
        // Tear down the responder so a fresh probe would necessarily fail.
        listener.cancel()
        try await Task.sleep(for: .milliseconds(150))
        // Idempotent start() must short-circuit on cached _port and skip re-probing.
        let p2 = try await server.start()
        try assertEqual(p1, p2)
        await server.stop()
    }

    testAsync("start() fails fast when the spawned binary exits immediately") {
        // /bin/echo prints its arg list and exits in milliseconds. Without
        // dead-process detection, start() would wait the full healthTimeout
        // (8s) before giving up. We assert it fails in well under 1 second.
        let (port, fd) = reserveLifecyclePort()
        Darwin.close(fd)
        let server = ApfelServer(
            portRange: port...port,
            healthTimeout: .seconds(8),
            binaryFinder: { "/bin/echo" }
        )
        let start = Date()
        do {
            _ = try await server.start()
            throw TestFailure("expected timeout")
        } catch let e as ApfelServerError {
            guard case .healthCheckTimeout = e else {
                throw TestFailure("expected .healthCheckTimeout, got \(e)")
            }
        } catch {
            throw TestFailure("wrong error: \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        try assertTrue(elapsed < 1.0, "should fail fast on dead process, took \(elapsed)s")
        await server.stop()
    }

    testAsync("start() after stop() re-probes cleanly") {
        let (port, listener) = try await startLifecycleResponder()
        defer { listener.cancel() }
        let server = ApfelServer(
            portRange: port...port,
            binaryFinder: { "/nonexistent" }
        )
        let p1 = try await server.start()
        await server.stop()
        // After stop(), cached _port is cleared; start() must probe again.
        let p2 = try await server.start()
        try assertEqual(p1, p2)
        await server.stop()
    }

    testAsync("start()'s cleanup escalates SIGTERM to SIGKILL when the spawned process ignores SIGTERM") {
        // Real-world failure: apfel wedges during model load and ignores SIGTERM.
        // Without escalation, the subprocess keeps holding the port forever,
        // poisoning subsequent attaches. We simulate with a perl script that
        // binds the target port AND ignores SIGTERM. perl is preinstalled on
        // every macOS, so this works on dev machines and macos-14 runners alike.
        let (port, fd) = reserveLifecyclePort()
        Darwin.close(fd)

        // Perl source goes in its own file so shell variable interpolation
        // does not eat $SIG, $s, $! before perl gets a chance to see them.
        let perlPath = NSTemporaryDirectory() + "apfel-kit-hold-port-\(UUID().uuidString).pl"
        let perlScript = """
        $SIG{TERM} = 'IGNORE';
        use IO::Socket::INET;
        my $s = IO::Socket::INET->new(
            LocalAddr => '127.0.0.1',
            LocalPort => \(port),
            Listen    => 1,
            ReuseAddr => 1,
        ) or die "bind failed: $!";
        sleep 30;
        """
        try perlScript.write(toFile: perlPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: perlPath) }

        // sh wrapper that ignores its own --serve/--port args and execs perl.
        let scriptPath = NSTemporaryDirectory() + "apfel-kit-wrap-\(UUID().uuidString).sh"
        let wrapper = "#!/bin/sh\nexec /usr/bin/perl '\(perlPath)'\n"
        try wrapper.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try assertEqual(chmod(scriptPath, 0o755), 0, "chmod failed")
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }

        let server = ApfelServer(
            portRange: port...port,
            healthTimeout: .milliseconds(300), // fast — drives us into the catch path
            arguments: [],
            binaryFinder: { scriptPath }
        )

        do {
            _ = try await server.start()
            throw TestFailure("expected timeout")
        } catch is ApfelServerError {
            // expected — perl bound the port but never answered /health
        }

        // Without SIGKILL escalation, the perl process traps SIGTERM and keeps
        // holding the port for the full sleep(30). With escalation, the port
        // should be freed within ~500ms. We allow 2s headroom.
        let deadline = Date().addingTimeInterval(2.0)
        var freed = false
        while Date() < deadline {
            if PortScanner.isAvailable(port) {
                freed = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try assertTrue(freed, "port \(port) should be freed within 2s after start() catch")
    }

    testAsync("multiple ApfelServer instances with disjoint ranges coexist") {
        let (p1, l1) = try await startLifecycleResponder()
        let (p2, l2) = try await startLifecycleResponder()
        defer { l1.cancel(); l2.cancel() }

        let s1 = ApfelServer(portRange: p1...p1, binaryFinder: { "/nonexistent" })
        let s2 = ApfelServer(portRange: p2...p2, binaryFinder: { "/nonexistent" })
        let g1 = try await s1.start()
        let g2 = try await s2.start()
        try assertEqual(g1, p1)
        try assertEqual(g2, p2)
        try assertFalse(g1 == g2)
        await s1.stop()
        await s2.stop()
    }
}

private func reserveLifecyclePort() -> (Int, Int32) {
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

private func startLifecycleResponder() async throws -> (Int, NWListener) {
    let (port, fd) = reserveLifecyclePort()
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
