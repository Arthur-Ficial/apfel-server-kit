import Foundation
import ApfelServerKit

func runChatRequestExtraTests() {
    test("ChatRequest JSON has exactly the OpenAI field names") {
        let req = ChatRequest(
            model: "apfel",
            messages: [ChatMessage(role: "user", content: "hi")],
            stream: false,
            temperature: 0.1
        )
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try assertNotNil(obj)
        try assertNotNil(obj?["model"])
        try assertNotNil(obj?["messages"])
        try assertNotNil(obj?["stream"])
        try assertNotNil(obj?["temperature"])
    }

    test("ChatMessage JSON has role + content and nothing else") {
        let msg = ChatMessage(role: "assistant", content: "ok")
        let data = try JSONEncoder().encode(msg)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try assertEqual(obj?.count, 2)
        try assertEqual(obj?["role"] as? String, "assistant")
        try assertEqual(obj?["content"] as? String, "ok")
    }

    test("ChatRequest with empty messages is allowed (caller responsibility)") {
        // Server will likely reject, but the type itself does not enforce.
        let req = ChatRequest(messages: [])
        try assertEqual(req.messages.count, 0)
    }

    test("ChatMessage supports all common OpenAI roles") {
        for role in ["system", "user", "assistant", "tool"] {
            let m = ChatMessage(role: role, content: "x")
            let data = try JSONEncoder().encode(m)
            let back = try JSONDecoder().decode(ChatMessage.self, from: data)
            try assertEqual(back.role, role)
        }
    }

    test("ChatRequest decoding from an OpenAI-shaped body works") {
        let json = #"""
        {
          "model": "gpt-4o-mini",
          "messages": [
            {"role":"user","content":"ping"}
          ],
          "stream": true,
          "temperature": 0.9
        }
        """#
        let data = Data(json.utf8)
        let req = try JSONDecoder().decode(ChatRequest.self, from: data)
        try assertEqual(req.model, "gpt-4o-mini")
        try assertEqual(req.messages.count, 1)
        try assertEqual(req.messages[0].content, "ping")
        try assertEqual(req.stream, true)
        try assertEqual(req.temperature, 0.9)
    }

    test("ChatRequest decoding tolerates missing optional temperature") {
        let json = #"""
        {
          "model": "apfel",
          "messages": [{"role":"user","content":"hi"}],
          "stream": false
        }
        """#
        let data = Data(json.utf8)
        let req = try JSONDecoder().decode(ChatRequest.self, from: data)
        try assertNil(req.temperature)
    }

    test("ChatRequest decoding fails on missing required messages") {
        let json = #"{"model":"apfel","stream":true}"#
        do {
            _ = try JSONDecoder().decode(ChatRequest.self, from: Data(json.utf8))
            throw TestFailure("expected decoding to throw")
        } catch is DecodingError {
            // ok
        } catch {
            throw TestFailure("wrong error: \(error)")
        }
    }

    test("ChatMessage equatable is by-value") {
        let a = ChatMessage(role: "user", content: "hi")
        let b = ChatMessage(role: "user", content: "hi")
        let c = ChatMessage(role: "user", content: "other")
        try assertEqual(a, b)
        try assertFalse(a == c)
    }

    test("ChatRequest equatable compares messages in order") {
        let a = ChatRequest(messages: [
            ChatMessage(role: "user", content: "a"),
            ChatMessage(role: "user", content: "b")
        ])
        let b = ChatRequest(messages: [
            ChatMessage(role: "user", content: "b"),
            ChatMessage(role: "user", content: "a")
        ])
        try assertFalse(a == b)
    }
}
