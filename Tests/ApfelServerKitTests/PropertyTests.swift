import Foundation
import ApfelServerKit

/// Property-based tests: generate many random inputs and assert invariants
/// hold. These catch bugs that hand-picked examples miss.
func runPropertyTests() {

    test("SSEParser.parse never returns inconsistent event for any ASCII garbage") {
        // For any random ASCII-ish string, parse() must return a stable
        // event: nil, or .delta, or .done, or .error. The key invariant:
        // calling twice with the same input yields the same output.
        var rng = SeededPRNG(seed: 0xBADF00D)
        for _ in 0..<500 {
            let input = rng.asciiString(length: rng.nextInt(in: 0...80))
            let a = SSEParser.parse(line: input)
            let b = SSEParser.parse(line: input)
            try assertEqual(a, b, "parser not deterministic for: \(input.debugDescription)")
        }
    }

    test("SSEParser.parse on any input never contains raw JSON braces in text") {
        // If parsing a data: line returns .delta(text: X), X must be the
        // decoded string - never the raw JSON including braces. Catches
        // accidental JSON escaping mishandling.
        var rng = SeededPRNG(seed: 0x1234_5678)
        for _ in 0..<200 {
            let word = rng.asciiString(length: rng.nextInt(in: 1...10), alphanumericOnly: true)
            let line = #"data: {"choices":[{"delta":{"content":"\#(word)"}}]}"#
            switch SSEParser.parse(line: line) {
            case .delta(let d):
                try assertEqual(d.text, word)
                try assertFalse(d.text?.contains("{") ?? false)
            default:
                throw TestFailure("expected .delta for \(word)")
            }
        }
    }

    test("ChatMessage JSON round-trip is idempotent across random role+content pairs") {
        var rng = SeededPRNG(seed: 0xA5A5)
        for _ in 0..<100 {
            let role = ["user", "system", "assistant", "tool"].randomElement(using: &rng)!
            let content = rng.asciiString(length: rng.nextInt(in: 0...200))
            let m = ChatMessage(role: role, content: content)
            let data = try JSONEncoder().encode(m)
            let back = try JSONDecoder().decode(ChatMessage.self, from: data)
            try assertEqual(m, back)
        }
    }

    test("ChatRequest JSON round-trip preserves message ordering") {
        var rng = SeededPRNG(seed: 0xDEAD_BEEF)
        for _ in 0..<50 {
            let count = rng.nextInt(in: 0...20)
            var msgs: [ChatMessage] = []
            for _ in 0..<count {
                msgs.append(ChatMessage(
                    role: "user",
                    content: rng.asciiString(length: rng.nextInt(in: 0...30))
                ))
            }
            let req = ChatRequest(messages: msgs)
            let data = try JSONEncoder().encode(req)
            let back = try JSONDecoder().decode(ChatRequest.self, from: data)
            try assertEqual(req.messages.map(\.content), back.messages.map(\.content))
        }
    }

    test("ApfelBinaryFinder returns nil for randomly generated non-existent paths") {
        var rng = SeededPRNG(seed: 0xFEED_FACE)
        for _ in 0..<50 {
            let path = "/no/" + rng.asciiString(length: 10, alphanumericOnly: true)
            let result = ApfelBinaryFinder.find(
                name: "apfel",
                environment: ["PATH": path],
                bundleExecutableURL: nil,
                fileExists: { _ in false }
            )
            try assertNil(result)
        }
    }

    test("PortScanner.firstAvailable is deterministic across repeat calls") {
        // Given the same range and host state, same result.
        let range = 50_000...50_005
        let a = PortScanner.firstAvailable(in: range)
        let b = PortScanner.firstAvailable(in: range)
        try assertEqual(a, b)
    }

    test("TextDelta equality is symmetric and reflexive") {
        var rng = SeededPRNG(seed: 42)
        for _ in 0..<100 {
            let text: String? = rng.bool() ? rng.asciiString(length: 10) : nil
            let reason: String? = rng.bool() ? "stop" : nil
            let a = TextDelta(text: text, finishReason: reason)
            let b = TextDelta(text: text, finishReason: reason)
            try assertEqual(a, b)       // reflexive-ish (same values)
            try assertTrue(a == b)
            try assertTrue(b == a)       // symmetric
        }
    }

    test("SSEEvent equality is symmetric") {
        let events: [SSEEvent] = [
            .done,
            .delta(TextDelta(text: "a", finishReason: nil)),
            .delta(TextDelta(text: nil, finishReason: "stop")),
            .error("x")
        ]
        for i in 0..<events.count {
            for j in 0..<events.count {
                try assertEqual(events[i] == events[j], events[j] == events[i])
            }
        }
    }
}

// MARK: - Deterministic seeded PRNG so property tests are reproducible

private struct SeededPRNG: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { self.state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func bool() -> Bool { (next() & 1) == 0 }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    mutating func asciiString(length: Int, alphanumericOnly: Bool = false) -> String {
        let alphabet: [Character]
        if alphanumericOnly {
            alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        } else {
            // Printable ASCII minus quote/backslash to keep JSON-safe here.
            alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 !#$%&()*+,-./:;<=>?@[]^_`{|}~")
        }
        var out = ""
        out.reserveCapacity(length)
        for _ in 0..<length {
            out.append(alphabet[Int(next() % UInt64(alphabet.count))])
        }
        return out
    }
}
