import Foundation
import ApfelServerKit

func runChatRequestTests() {
    test("ChatMessage round-trips JSON") {
        let msg = ChatMessage(role: "user", content: "hi")
        let data = try JSONEncoder().encode(msg)
        let back = try JSONDecoder().decode(ChatMessage.self, from: data)
        try assertEqual(msg, back)
    }

    test("ChatRequest defaults match OpenAI shape") {
        let req = ChatRequest(messages: [ChatMessage(role: "user", content: "hi")])
        try assertEqual(req.model, "apfel")
        try assertTrue(req.stream)
        try assertNil(req.temperature)
    }

    test("ChatRequest JSON omits nil temperature") {
        let req = ChatRequest(messages: [ChatMessage(role: "user", content: "hi")])
        let data = try JSONEncoder().encode(req)
        let str = String(data: data, encoding: .utf8) ?? ""
        try assertFalse(str.contains("temperature"))
    }

    test("ChatRequest JSON includes non-nil temperature") {
        let req = ChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0.7
        )
        let data = try JSONEncoder().encode(req)
        let str = String(data: data, encoding: .utf8) ?? ""
        try assertTrue(str.contains("\"temperature\":0.7"))
    }

    test("ChatRequest full round-trip") {
        let original = ChatRequest(
            model: "apfel-7b",
            messages: [
                ChatMessage(role: "system", content: "be brief"),
                ChatMessage(role: "user", content: "hi")
            ],
            stream: false,
            temperature: 0.2
        )
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(ChatRequest.self, from: data)
        try assertEqual(original, back)
    }
}
