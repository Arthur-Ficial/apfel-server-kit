import Foundation
import ApfelServerKit

/// Lock the exact user-facing wording of each error message so silent
/// copy drift gets caught in PR review. If you deliberately rewrite a
/// message, update the snapshot; the change is documented in the diff.
func runErrorMessageSnapshotTests() {

    test("ApfelServerError.binaryNotFound message") {
        try assertEqual(
            ApfelServerError.binaryNotFound.errorDescription,
            "apfel binary not found. Install with `brew install apfel` or ensure apfel is on PATH."
        )
    }

    test("ApfelServerError.noPortAvailable message") {
        try assertEqual(
            ApfelServerError.noPortAvailable(11450...11459).errorDescription,
            "no ports available in 11450-11459. Close other apfel processes or pass a different portRange."
        )
    }

    test("ApfelServerError.spawnFailed message") {
        try assertEqual(
            ApfelServerError.spawnFailed("permission denied").errorDescription,
            "failed to spawn apfel: permission denied"
        )
    }

    test("ApfelServerError.healthCheckTimeout message") {
        try assertEqual(
            ApfelServerError.healthCheckTimeout(port: 11450, seconds: 8.0).errorDescription,
            "apfel did not answer /health on port 11450 within 8.0s. The process may be stuck loading the model; try raising healthTimeout."
        )
    }

    test("ApfelClientError.invalidURL message") {
        try assertEqual(
            ApfelClientError.invalidURL.errorDescription,
            "apfel client could not construct a valid URL from host/port."
        )
    }

    test("ApfelClientError.httpStatus message") {
        try assertEqual(
            ApfelClientError.httpStatus(503).errorDescription,
            "apfel server returned HTTP 503."
        )
    }

    test("ApfelClientError.stream message") {
        try assertEqual(
            ApfelClientError.stream("model went away").errorDescription,
            "apfel stream error: model went away."
        )
    }

    test("every ApfelServerError message is human-readable (actionable phrasing)") {
        // Quick smoke: messages must NOT contain placeholder tokens.
        let banned = ["TODO", "FIXME", "XXX", "nil", "optional("]
        let cases: [ApfelServerError] = [
            .binaryNotFound,
            .noPortAvailable(1...2),
            .spawnFailed("x"),
            .healthCheckTimeout(port: 1, seconds: 1)
        ]
        for c in cases {
            let m = (c.errorDescription ?? "").lowercased()
            for b in banned {
                try assertFalse(m.contains(b.lowercased()), "found '\(b)' in: \(m)")
            }
        }
    }

    test("every ApfelClientError message is human-readable") {
        let cases: [ApfelClientError] = [.invalidURL, .httpStatus(500), .stream("x")]
        for c in cases {
            try assertNotNil(c.errorDescription)
            try assertTrue(!(c.errorDescription ?? "").isEmpty)
        }
    }
}
