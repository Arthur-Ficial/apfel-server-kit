import Foundation

/// Manages the lifecycle of a local `apfel --serve` process.
///
/// `start()` will either:
/// - **Connect** to an already-running apfel server inside the configured port
///   range by probing `GET /health`. No subprocess is spawned; `isManaged`
///   stays `false` and `stop()` is a no-op.
/// - **Spawn** a new `apfel --serve --port <N> <arguments>` subprocess on the
///   first free port in the range, poll `/health` every 200ms until it
///   answers with HTTP 200, and report success. `isManaged` is `true`.
///
/// If no port is free, spawn fails, or `/health` never answers within
/// `healthTimeout`, `start()` throws an ``ApfelServerError``.
public actor ApfelServer {

    // MARK: - Public API

    /// Port range to probe and, if nothing responds, spawn into.
    public let portRange: ClosedRange<Int>

    /// How long to wait for `/health` to answer HTTP 200 after spawning.
    public let healthTimeout: Duration

    /// Extra arguments appended after `--serve --port <N>`. Defaults to
    /// `["--cors", "--permissive"]` to match the ecosystem tools.
    public let arguments: [String]

    /// The host to bind to. `apfel --serve` always binds `127.0.0.1`; the
    /// host field is used only for `/health` probing and `ApfelClient` wiring.
    public let host: String

    /// The port the server is running (or connected) on. `nil` before `start()`.
    public var port: Int? { _port }

    /// `true` when this instance spawned and owns the subprocess, `false` when
    /// it attached to a pre-existing server or has not been started.
    public var isManaged: Bool { _process != nil }

    // MARK: - Private state

    private var _port: Int?
    private var _process: Process?
    private let binaryFinder: @Sendable () -> String?

    // MARK: - Init

    public init(
        portRange: ClosedRange<Int> = 11450...11459,
        healthTimeout: Duration = .seconds(8),
        arguments: [String] = ["--cors", "--permissive"],
        host: String = "127.0.0.1",
        binaryFinder: @Sendable @escaping () -> String? = { ApfelBinaryFinder.find() }
    ) {
        self.portRange = portRange
        self.healthTimeout = healthTimeout
        self.arguments = arguments
        self.host = host
        self.binaryFinder = binaryFinder
    }

    // MARK: - Lifecycle

    /// Connect to an existing apfel server in the configured range, or spawn
    /// a new one. Returns the port in use.
    public func start() async throws -> Int {
        if let existing = await probeExisting() {
            _port = existing
            return existing
        }

        guard let free = PortScanner.firstAvailable(in: portRange) else {
            throw ApfelServerError.noPortAvailable(portRange)
        }
        guard let binary = binaryFinder() else {
            throw ApfelServerError.binaryNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--serve", "--port", "\(free)"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ApfelServerError.spawnFailed(error.localizedDescription)
        }

        _process = process
        _port = free

        do {
            try await pollHealth(port: free)
        } catch {
            process.terminate()
            _process = nil
            _port = nil
            throw error
        }

        return free
    }

    /// Terminate the managed subprocess, if any. No-op when attached to an
    /// existing server or when `start()` was never called.
    public func stop() {
        if let process = _process, process.isRunning {
            process.terminate()
        }
        _process = nil
        _port = nil
    }

    // MARK: - Helpers

    private func probeExisting() async -> Int? {
        for candidate in portRange where await isHealthy(port: candidate) {
            return candidate
        }
        return nil
    }

    private func pollHealth(port: Int) async throws {
        let pollInterval: Duration = .milliseconds(200)
        let deadline = ContinuousClock.now.advanced(by: healthTimeout)
        while ContinuousClock.now < deadline {
            if await isHealthy(port: port) { return }
            try? await Task.sleep(for: pollInterval)
        }
        throw ApfelServerError.healthCheckTimeout(
            port: port,
            seconds: durationToSeconds(healthTimeout)
        )
    }

    private func isHealthy(port: Int) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/health") else { return false }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.25
        config.timeoutIntervalForResource = 0.5
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func durationToSeconds(_ d: Duration) -> Double {
        let (seconds, attoseconds) = d.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
