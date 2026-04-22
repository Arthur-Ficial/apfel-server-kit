import Foundation
import ApfelServerKit

/// Wire-format invariants for the SSE parser. Focuses on real-world things
/// OpenAI-compatible servers emit and malformed frames we must not crash on.
func runSSEWireFormatTests() {

    test("data line with role assistant prefix parses") {
        // OpenAI's first frame usually has `role:"assistant"` and no content.
        let line = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
        try assertNil(SSEParser.parse(line: line))
    }

    test("data line with role assistant and content parses as content") {
        let line = #"data: {"choices":[{"delta":{"role":"assistant","content":"hi"}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "hi")
        default: throw TestFailure("expected .delta")
        }
    }

    test("content_filter finish_reason variant parses") {
        let line = #"data: {"choices":[{"finish_reason":"content_filter"}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.finishReason, "content_filter")
        default: throw TestFailure("expected .delta")
        }
    }

    test("tool_calls finish_reason variant parses") {
        let line = #"data: {"choices":[{"finish_reason":"tool_calls"}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.finishReason, "tool_calls")
        default: throw TestFailure("expected .delta")
        }
    }

    test("choice with index but no delta -> nil") {
        let line = #"data: {"choices":[{"index":0}]}"#
        try assertNil(SSEParser.parse(line: line))
    }

    test("usage payload with included choices -> delta (choices win)") {
        let line = #"data: {"usage":{"prompt_tokens":1},"choices":[{"delta":{"content":"x"}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "x")
        default: throw TestFailure("expected .delta")
        }
    }

    test("data line with numeric 'id' at root is fine") {
        let line = #"data: {"id":"chatcmpl-abc","choices":[{"delta":{"content":"hi"}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "hi")
        default: throw TestFailure("expected .delta")
        }
    }

    test("data line with model field at root is fine") {
        let line = #"data: {"model":"apfel-7b","choices":[{"delta":{"content":"hi"}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "hi")
        default: throw TestFailure("expected .delta")
        }
    }

    test("data line with object chunk (type field) is fine") {
        let line = #"data: {"object":"chat.completion.chunk","choices":[{"delta":{"content":"hi"}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "hi")
        default: throw TestFailure("expected .delta")
        }
    }

    test("content is empty string - treated as delta with empty text") {
        // Empty string is distinct from null. Some servers emit empty deltas.
        let line = #"data: {"choices":[{"delta":{"content":""}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "")
        default: throw TestFailure("expected .delta")
        }
    }

    test("deeply nested JSON in content is preserved") {
        // JSON inside a string is just a string.
        let line = #"data: {"choices":[{"delta":{"content":"{\"k\":\"v\"}"}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, #"{"k":"v"}"#)
        default: throw TestFailure("expected .delta")
        }
    }

    test("forward-slash escape in content is preserved") {
        let line = #"data: {"choices":[{"delta":{"content":"http:\/\/x"}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "http://x")
        default: throw TestFailure("expected .delta")
        }
    }

    test("unicode escape \\u00e9 decodes to é") {
        let line = "data: {\"choices\":[{\"delta\":{\"content\":\"caf\\u00e9\"}}]}"
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "café")
        default: throw TestFailure("expected .delta")
        }
    }

    test("emoji in content (multi-scalar) is preserved") {
        let line = #"data: {"choices":[{"delta":{"content":"👋🏽🤖"}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "👋🏽🤖")
        default: throw TestFailure("expected .delta")
        }
    }

    test("control character in content round-trips") {
        let line = #"data: {"choices":[{"delta":{"content":"a\tb"}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "a\tb")
        default: throw TestFailure("expected .delta")
        }
    }

    test("explicit 'null' string (not JSON null) for content is a string") {
        let line = #"data: {"choices":[{"delta":{"content":"null"}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "null")
        default: throw TestFailure("expected .delta")
        }
    }

    test("parse is a pure function - same input yields same output") {
        let line = #"data: {"choices":[{"delta":{"content":"x"}}]}"#
        let a = SSEParser.parse(line: line)
        let b = SSEParser.parse(line: line)
        try assertEqual(a, b)
    }
}
