import Foundation
import ApfelServerKit

func runSSEEventTests() {
    test("TextDelta equality - both fields") {
        try assertEqual(
            TextDelta(text: "hi", finishReason: nil),
            TextDelta(text: "hi", finishReason: nil)
        )
    }

    test("TextDelta equality - finish reason stop") {
        try assertEqual(
            TextDelta(text: nil, finishReason: "stop"),
            TextDelta(text: nil, finishReason: "stop")
        )
    }

    test("TextDelta inequality on text") {
        try assertFalse(
            TextDelta(text: "a", finishReason: nil) == TextDelta(text: "b", finishReason: nil)
        )
    }

    test("SSEEvent .done equality") {
        try assertEqual(SSEEvent.done, SSEEvent.done)
    }

    test("SSEEvent .delta equality") {
        try assertEqual(
            SSEEvent.delta(TextDelta(text: "hi", finishReason: nil)),
            SSEEvent.delta(TextDelta(text: "hi", finishReason: nil))
        )
    }

    test("SSEEvent .error equality") {
        try assertEqual(SSEEvent.error("boom"), SSEEvent.error("boom"))
    }

    test("SSEEvent different cases are unequal") {
        try assertFalse(SSEEvent.done == SSEEvent.error("x"))
    }
}
