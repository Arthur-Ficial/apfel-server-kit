import Foundation
import ApfelServerKit

/// Deeper SSEParser coverage beyond the 17 apfel-quick + 1 apfel-chat cases.
/// Focuses on malformed input, unicode, multiple whitespace forms, unusual
/// JSON shapes that real servers emit, and negative cases that should NOT be
/// treated as errors.
func runSSEParserExtraTests() {

    test("tab-prefixed data is treated as non-data after trim") {
        // SSE spec: field name ends at the first colon. `\tdata:` is NOT a
        // `data:` field - the name is `\tdata`. We reject it.
        try assertNil(SSEParser.parse(line: "\tdata: {\"choices\":[]}"))
    }

    test("leading/trailing whitespace around empty payload -> nil") {
        try assertNil(SSEParser.parse(line: "   data:    "))
    }

    test("payload with only whitespace -> nil") {
        try assertNil(SSEParser.parse(line: "data:    "))
    }

    test("payload with trailing whitespace is still valid JSON") {
        let line = #"data: {"choices":[{"delta":{"content":"hi"}}]}   "#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "hi")
        default: throw TestFailure("expected .delta")
        }
    }

    test("unicode content is preserved byte-for-byte") {
        let line = #"data: {"choices":[{"delta":{"content":"こんにちは 🚀 café"}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "こんにちは 🚀 café")
        default: throw TestFailure("expected .delta")
        }
    }

    test("escaped quotes and newlines inside content are preserved") {
        let line = #"data: {"choices":[{"delta":{"content":"line1\nline2 \"quoted\""}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "line1\nline2 \"quoted\"")
        default: throw TestFailure("expected .delta")
        }
    }

    test("content is a number (non-string) -> treated as nil") {
        // If a server sends `"content": 42`, JSONSerialization gives us
        // NSNumber, not String. We treat that as "no text".
        let line = #"data: {"choices":[{"delta":{"content":42}}]}"#
        try assertNil(SSEParser.parse(line: line))
    }

    test("content is an array (non-string) -> treated as nil") {
        let line = #"data: {"choices":[{"delta":{"content":["hi"]}}]}"#
        try assertNil(SSEParser.parse(line: line))
    }

    test("finish_reason is a number -> treated as nil, no delta") {
        // Invalid OpenAI shape: non-string finish_reason. We refuse to invent one.
        let line = #"data: {"choices":[{"finish_reason":7}]}"#
        try assertNil(SSEParser.parse(line: line))
    }

    test("root is a JSON array, not object -> .error") {
        let line = "data: [1,2,3]"
        switch SSEParser.parse(line: line) {
        case .error: break
        default: throw TestFailure("expected .error")
        }
    }

    test("root is JSON null -> .error") {
        let line = "data: null"
        switch SSEParser.parse(line: line) {
        case .error: break
        default: throw TestFailure("expected .error")
        }
    }

    test("root is JSON string -> .error") {
        let line = "data: \"just a string\""
        switch SSEParser.parse(line: line) {
        case .error: break
        default: throw TestFailure("expected .error")
        }
    }

    test("truncated JSON ({) -> .error") {
        switch SSEParser.parse(line: "data: {") {
        case .error: break
        default: throw TestFailure("expected .error")
        }
    }

    test("[DONE] with trailing whitespace still terminates") {
        try assertEqual(SSEParser.parse(line: "data: [DONE]   "), .done)
    }

    test("case-sensitive [DONE] - lowercase [done] is a payload, not terminator") {
        // We match exactly "[DONE]" (upper-case), matching OpenAI's wire format.
        // Lower-case is invalid JSON -> .error.
        switch SSEParser.parse(line: "data: [done]") {
        case .error: break
        default: throw TestFailure("expected .error for lowercase [done]")
        }
    }

    test("choices with string (not array) -> nil") {
        let line = #"data: {"choices":"nope"}"#
        try assertNil(SSEParser.parse(line: line))
    }

    test("delta present but content missing altogether") {
        // {"delta": {}} - no content key, no finish_reason -> no event
        let line = #"data: {"choices":[{"delta":{}}]}"#
        try assertNil(SSEParser.parse(line: line))
    }

    test("choices element is not an object -> nil") {
        let line = #"data: {"choices":["string"]}"#
        try assertNil(SSEParser.parse(line: line))
    }

    test("additional unknown fields in choice are ignored") {
        let line = #"data: {"choices":[{"delta":{"content":"hi","role":"assistant"},"index":0,"logprobs":null}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "hi")
        default: throw TestFailure("expected .delta")
        }
    }

    test("error: line preserves internal colons in message") {
        switch SSEParser.parse(line: "error: url: https://example.com failed") {
        case .error(let msg): try assertEqual(msg, "url: https://example.com failed")
        default: throw TestFailure("expected .error")
        }
    }

    test("Error: with capital E is matched case-insensitively") {
        switch SSEParser.parse(line: "Error: boom") {
        case .error(let msg): try assertEqual(msg, "boom")
        default: throw TestFailure("expected .error")
        }
    }

    test("DATA: with capital letters is matched case-insensitively") {
        let line = #"DATA: {"choices":[{"delta":{"content":"x"}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "x")
        default: throw TestFailure("expected .delta")
        }
    }

    test("very long content (10k chars) is preserved") {
        let long = String(repeating: "a", count: 10_000)
        let line = #"data: {"choices":[{"delta":{"content":"\#(long)"}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d):
            try assertEqual(d.text?.count, 10_000)
            try assertTrue(d.text?.first == "a")
        default: throw TestFailure("expected .delta")
        }
    }

    test("data: with no payload character after colon -> nil") {
        try assertNil(SSEParser.parse(line: "data:"))
    }

    test("fuzz: 100 random well-formed deltas all parse to .delta") {
        for i in 0..<100 {
            let content = "chunk-\(i)"
            let line = #"data: {"choices":[{"delta":{"content":"\#(content)"}}]}"#
            switch SSEParser.parse(line: line) {
            case .delta(let d): try assertEqual(d.text, content)
            default: throw TestFailure("fuzz #\(i) failed")
            }
        }
    }

    test("fuzz: random garbage strings never crash the parser") {
        let samples = [
            "", " ", "\n", "\t", "  \t  ",
            "data", "data:", "data: ", "data:\t",
            ":", "::", ":::::",
            "event: message", "id: 42", "retry: 1000",
            "{\"broken\":", "data: {\"broken\":",
            "\u{0000}", "data: \u{FFFD}",
            String(repeating: "x", count: 1024)
        ]
        for s in samples {
            _ = SSEParser.parse(line: s)
        }
    }
}
