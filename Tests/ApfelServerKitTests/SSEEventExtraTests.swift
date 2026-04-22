import Foundation
import ApfelServerKit

func runSSEEventExtraTests() {
    test("TextDelta with nil text + nil finishReason is valid (keep-alive)") {
        let d = TextDelta(text: nil, finishReason: nil)
        try assertNil(d.text)
        try assertNil(d.finishReason)
    }

    test("TextDelta distinguishes nil text from empty text") {
        try assertFalse(
            TextDelta(text: nil, finishReason: nil)
                == TextDelta(text: "", finishReason: nil)
        )
    }

    test("SSEEvent .delta vs .done are never equal") {
        try assertFalse(SSEEvent.delta(TextDelta(text: "a", finishReason: nil)) == .done)
    }

    test("SSEEvent .delta vs .error are never equal") {
        try assertFalse(
            SSEEvent.delta(TextDelta(text: "a", finishReason: nil))
                == SSEEvent.error("x")
        )
    }

    test("SSEEvent .error with different messages are unequal") {
        try assertFalse(SSEEvent.error("a") == SSEEvent.error("b"))
    }

    test("SSEEvent .delta with different finishReasons are unequal") {
        try assertFalse(
            SSEEvent.delta(TextDelta(text: nil, finishReason: "stop"))
                == SSEEvent.delta(TextDelta(text: nil, finishReason: "length"))
        )
    }
}
