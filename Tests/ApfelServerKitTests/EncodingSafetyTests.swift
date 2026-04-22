import Foundation
import ApfelServerKit

/// Tests for string handling, encoding safety, and Unicode correctness
/// across the public types. Catches bugs where a function silently
/// corrupts non-ASCII input.
func runEncodingSafetyTests() {

    test("ChatMessage with leading/trailing whitespace round-trips verbatim") {
        let m = ChatMessage(role: "user", content: "  hello  ")
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ChatMessage.self, from: data)
        try assertEqual(back.content, "  hello  ")
    }

    test("ChatMessage with newlines in content round-trips verbatim") {
        let content = "line1\nline2\nline3"
        let m = ChatMessage(role: "user", content: content)
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ChatMessage.self, from: data)
        try assertEqual(back.content, content)
    }

    test("ChatMessage with embedded quotes round-trips") {
        let content = #"She said "hi" and waved."#
        let m = ChatMessage(role: "user", content: content)
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ChatMessage.self, from: data)
        try assertEqual(back.content, content)
    }

    test("ChatMessage with zero-width joiner sequence round-trips") {
        let zwj = "👨\u{200D}👩\u{200D}👧"
        let m = ChatMessage(role: "user", content: zwj)
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ChatMessage.self, from: data)
        try assertEqual(back.content, zwj)
    }

    test("ChatMessage with RTL text round-trips") {
        // Hebrew, right-to-left markers intact.
        let rtl = "שלום, עולם"
        let m = ChatMessage(role: "user", content: rtl)
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ChatMessage.self, from: data)
        try assertEqual(back.content, rtl)
    }

    test("SSE parser handles a BOM-prefixed content deterministically") {
        // JSONSerialization may or may not strip a leading BOM inside a
        // string value - that's a Foundation implementation detail we do
        // not want to pin. What we DO guarantee: parse(line:) yields the
        // same result on repeated calls with the same input.
        let bom = "\u{FEFF}"
        let line = #"data: {"choices":[{"delta":{"content":"\#(bom)hi"}}]}"#
        let a = SSEParser.parse(line: line)
        let b = SSEParser.parse(line: line)
        try assertEqual(a, b)
        // And the content is definitely non-empty.
        if case .delta(let d) = a {
            try assertTrue((d.text ?? "").contains("hi"))
        } else {
            throw TestFailure("expected .delta")
        }
    }

    test("SSE parser rejects data line with raw null bytes gracefully") {
        // A \0 inside a JSON value is a corrupt payload. Parser should either
        // surface as error or skip - must not crash.
        let line = "data: {\"choices\":[{\"delta\":{\"content\":\"a\\u0000b\"}}]}"
        _ = SSEParser.parse(line: line)
    }

    test("ChatRequest JSON output is valid UTF-8 even with astral codepoints") {
        let req = ChatRequest(
            messages: [ChatMessage(role: "user", content: "𝑴𝒂𝒕𝒉 𝒃𝒐𝒍𝒅")]
        )
        let data = try JSONEncoder().encode(req)
        let decoded = String(data: data, encoding: .utf8)
        try assertNotNil(decoded)
    }

    test("TextDelta inherits Swift's canonical String equality (NFC == NFD)") {
        // Swift String uses canonical equivalence, so an NFC "é" and an NFD
        // "e + combining acute" compare equal even though their byte
        // representations differ. TextDelta's synthesized Equatable follows.
        let nfc = "é"           // one codepoint
        let nfd = "e\u{0301}"  // 'e' + combining acute
        try assertEqual(
            TextDelta(text: nfc, finishReason: nil),
            TextDelta(text: nfd, finishReason: nil)
        )
    }
}
