import Foundation
import ApfelServerKit

func runSSEParserTests() {
    // 1. data line with text content
    test("parseDataLineWithText") {
        let line = #"data: {"choices":[{"delta":{"content":"hi"}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d):
            try assertEqual(d.text, "hi")
            try assertNil(d.finishReason)
        default:
            throw TestFailure("expected .delta")
        }
    }

    // 2. data: [DONE]
    test("parseDataDone") {
        try assertEqual(SSEParser.parse(line: "data: [DONE]"), .done)
    }

    // 3. empty line
    test("parseEmptyLine") {
        try assertNil(SSEParser.parse(line: ""))
    }

    // 4. comment line (starts with ':')
    test("parseCommentLine") {
        try assertNil(SSEParser.parse(line: ": keep-alive"))
    }

    // 5. finish_reason only -> delta(text: nil, finishReason: "stop")
    test("parseFinishReason") {
        let line = #"data: {"choices":[{"finish_reason":"stop"}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d):
            try assertNil(d.text)
            try assertEqual(d.finishReason, "stop")
        default:
            throw TestFailure("expected .delta")
        }
    }

    // 6. text + finish_reason together
    test("parseTextAndFinishReason") {
        let line = #"data: {"choices":[{"delta":{"content":"bye"},"finish_reason":"stop"}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d):
            try assertEqual(d.text, "bye")
            try assertEqual(d.finishReason, "stop")
        default:
            throw TestFailure("expected .delta")
        }
    }

    // 7. invalid JSON -> .error(...)
    test("parseInvalidJSON") {
        switch SSEParser.parse(line: "data: not-json{") {
        case .error(let msg):
            try assertTrue(!msg.isEmpty)
        default:
            throw TestFailure("expected .error for invalid JSON")
        }
    }

    // 8. non-data line -> nil
    test("parseNonDataLine") {
        try assertNil(SSEParser.parse(line: "event: message"))
    }

    // 9. explicit error line
    test("parseErrorLine") {
        try assertEqual(
            SSEParser.parse(line: "error: something broke"),
            .error("something broke")
        )
    }

    // 10. null content, no finish_reason -> nil (keep-alive delta)
    test("parseNullContent") {
        let line = #"data: {"choices":[{"delta":{"content":null}}]}"#
        try assertNil(SSEParser.parse(line: line))
    }

    // 11. whitespace-only -> nil
    test("parseWhitespaceOnlyLine") {
        try assertNil(SSEParser.parse(line: "   "))
    }

    // 12. data:<space-optional> before payload
    test("parseDataLineWithLeadingSpaceAfterColon") {
        let noSpace = #"data:{"choices":[{"delta":{"content":"x"}}]}"#
        let withSpace = #"data: {"choices":[{"delta":{"content":"x"}}]}"#
        switch SSEParser.parse(line: noSpace) {
        case .delta(let d): try assertEqual(d.text, "x")
        default: throw TestFailure("expected .delta (no space)")
        }
        switch SSEParser.parse(line: withSpace) {
        case .delta(let d): try assertEqual(d.text, "x")
        default: throw TestFailure("expected .delta (space)")
        }
    }

    // 13. first choice wins when multiple present
    test("parseFirstChoiceDeltaUsed") {
        let line = #"data: {"choices":[{"delta":{"content":"first"}},{"delta":{"content":"second"}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.text, "first")
        default: throw TestFailure("expected .delta")
        }
    }

    // 14. empty choices array -> nil
    test("parseEmptyChoicesArray") {
        let line = #"data: {"choices":[]}"#
        try assertNil(SSEParser.parse(line: line))
    }

    // 15. non-error line starting with 'error' word but not prefix -> nil
    test("parseErrorOnNonErrorLineReturnsNil") {
        try assertNil(SSEParser.parse(line: "errors-plural: x"))
    }

    // 16. "error:" with empty payload -> nil (not an error we can surface)
    test("parseErrorOnEmptyLineReturnsNil") {
        try assertNil(SSEParser.parse(line: "error:"))
    }

    // 17. finish_reason length variant
    test("parseFinishReasonLength") {
        let line = #"data: {"choices":[{"finish_reason":"length"}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d): try assertEqual(d.finishReason, "length")
        default: throw TestFailure("expected .delta")
        }
    }

    // 18. usage-only payload (from apfel-chat) -> nil
    test("parseUsageOnlyPayload") {
        let line = #"data: {"usage":{"prompt_tokens":5,"completion_tokens":3}}"#
        try assertNil(SSEParser.parse(line: line))
    }
}
