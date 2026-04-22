import Foundation
import ApfelServerKit

/// Lock down the shape of the public API so silent drift is caught
/// before it ships. These tests exist to fail loudly when someone changes
/// a case label, removes a field, renames a parameter, or drops a
/// Sendable conformance.
func runPublicAPIStabilityTests() {

    test("ApfelServerKit.version is present and semver-shaped") {
        let v = ApfelServerKit.version
        let parts = v.split(separator: ".")
        try assertEqual(parts.count, 3, "version should be MAJOR.MINOR.PATCH")
        for p in parts {
            try assertNotNil(Int(p), "each segment must be numeric, got \(p)")
        }
    }

    test("TextDelta is Sendable + Equatable") {
        func requireSendable<T: Sendable & Equatable>(_: T.Type) {}
        requireSendable(TextDelta.self)
    }

    test("SSEEvent is Sendable + Equatable") {
        func requireSendable<T: Sendable & Equatable>(_: T.Type) {}
        requireSendable(SSEEvent.self)
    }

    test("ChatRequest is Sendable + Equatable + Codable") {
        func requireConformances<T: Sendable & Equatable & Codable>(_: T.Type) {}
        requireConformances(ChatRequest.self)
    }

    test("ChatMessage is Sendable + Equatable + Codable") {
        func requireConformances<T: Sendable & Equatable & Codable>(_: T.Type) {}
        requireConformances(ChatMessage.self)
    }

    test("ApfelServerError is Error + Equatable + Sendable") {
        func requireConformances<T: Error & Equatable & Sendable>(_: T.Type) {}
        requireConformances(ApfelServerError.self)
    }

    test("ApfelClientError is Error + Equatable + Sendable") {
        func requireConformances<T: Error & Equatable & Sendable>(_: T.Type) {}
        requireConformances(ApfelClientError.self)
    }

    test("ApfelClient is Sendable") {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(ApfelClient.self)
    }

    test("ApfelServerError.binaryNotFound == .binaryNotFound") {
        try assertEqual(ApfelServerError.binaryNotFound, .binaryNotFound)
    }

    test("ApfelServerError LocalizedError description is human-readable") {
        try assertTrue(ApfelServerError.binaryNotFound.errorDescription?.contains("apfel") ?? false)
        try assertTrue(
            (ApfelServerError.noPortAvailable(11450...11459).errorDescription ?? "").contains("11450")
        )
        try assertTrue(
            (ApfelServerError.spawnFailed("boom").errorDescription ?? "").contains("boom")
        )
        try assertTrue(
            (ApfelServerError.healthCheckTimeout(port: 42, seconds: 1.5).errorDescription ?? "").contains("42")
        )
    }

    test("ApfelClientError LocalizedError description is human-readable") {
        try assertNotNil(ApfelClientError.invalidURL.errorDescription)
        try assertTrue(
            (ApfelClientError.httpStatus(500).errorDescription ?? "").contains("500")
        )
        try assertTrue(
            (ApfelClientError.stream("boom").errorDescription ?? "").contains("boom")
        )
    }

    test("SSEEvent pattern matching is exhaustive in caller switches") {
        // If you add a new case, this switch forces callers to update.
        let events: [SSEEvent] = [
            .delta(TextDelta(text: "a", finishReason: nil)),
            .done,
            .error("x")
        ]
        for e in events {
            switch e {
            case .delta: break
            case .done: break
            case .error: break
            }
        }
    }

    test("ApfelServer public config fields exist with correct defaults") {
        let server = ApfelServer(binaryFinder: { nil })
        try assertEqual(server.portRange.lowerBound, 11450)
        try assertEqual(server.portRange.upperBound, 11459)
        try assertEqual(server.arguments, ["--cors", "--permissive"])
        try assertEqual(server.host, "127.0.0.1")
    }

    test("ChatRequest default init uses model=apfel and stream=true") {
        let req = ChatRequest(messages: [])
        try assertEqual(req.model, "apfel")
        try assertTrue(req.stream)
    }

    test("ApfelBinaryFinder.find accepts the documented parameter defaults") {
        // Smoke: default args do not crash. Result depends on the host.
        _ = ApfelBinaryFinder.find()
    }

    test("PortScanner.isAvailable and .firstAvailable exist with Int signatures") {
        _ = PortScanner.isAvailable(0)
        _ = PortScanner.firstAvailable(in: 1...1)
    }

    test("SSEParser.parse signature returns optional SSEEvent") {
        let result: SSEEvent? = SSEParser.parse(line: "data: [DONE]")
        try assertEqual(result, .done)
    }
}
