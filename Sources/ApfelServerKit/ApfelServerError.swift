import Foundation

/// Typed errors thrown by ``ApfelServer`` and ``ApfelClient``.
///
/// Case names are stable API; the associated `String` values may improve
/// across releases to give better diagnostics.
public enum ApfelServerError: Error, Equatable, Sendable {
    /// No `apfel` (or alternate-named) binary was found on `PATH`, in the
    /// current bundle, or in any of the fallback locations.
    case binaryNotFound

    /// Every port in the configured range was already bound.
    case noPortAvailable(ClosedRange<Int>)

    /// `Process.run()` threw while attempting to spawn `apfel --serve`.
    /// The associated message is the underlying system error.
    case spawnFailed(String)

    /// The spawned apfel process never answered `GET /health` with HTTP 200
    /// within the configured timeout.
    case healthCheckTimeout(port: Int, seconds: Double)
}

extension ApfelServerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "apfel binary not found. Install with `brew install apfel` or ensure apfel is on PATH."
        case .noPortAvailable(let range):
            return "no ports available in \(range.lowerBound)-\(range.upperBound). Close other apfel processes or pass a different portRange."
        case .spawnFailed(let message):
            return "failed to spawn apfel: \(message)"
        case .healthCheckTimeout(let port, let seconds):
            return "apfel did not answer /health on port \(port) within \(seconds)s. The process may be stuck loading the model; try raising healthTimeout."
        }
    }
}
