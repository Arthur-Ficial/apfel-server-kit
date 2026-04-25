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
            temperature: 0.2,
            maxTokens: 64
        )
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(ChatRequest.self, from: data)
        try assertEqual(original, back)
    }

    test("ChatRequest JSON omits nil maxTokens") {
        let req = ChatRequest(messages: [ChatMessage(role: "user", content: "hi")])
        let data = try JSONEncoder().encode(req)
        let str = String(data: data, encoding: .utf8) ?? ""
        try assertFalse(str.contains("max_tokens"))
    }

    test("ChatRequest JSON encodes maxTokens as snake_case max_tokens") {
        let req = ChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            maxTokens: 64
        )
        let data = try JSONEncoder().encode(req)
        let str = String(data: data, encoding: .utf8) ?? ""
        try assertTrue(str.contains("\"max_tokens\":64"))
        try assertFalse(str.contains("maxTokens"))
    }

    test("ChatRequest decodes max_tokens from server JSON") {
        let json = """
        {"model":"apfel","messages":[{"role":"user","content":"hi"}],"stream":true,"max_tokens":128}
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(ChatRequest.self, from: json)
        try assertEqual(req.maxTokens, 128)
    }
}
