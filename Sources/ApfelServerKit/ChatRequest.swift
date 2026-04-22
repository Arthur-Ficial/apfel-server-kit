import Foundation

/// A single OpenAI-compatible chat message. Intentionally thin - consumers who
/// need the full OpenAI type tree (tool calls, structured content parts, etc.)
/// should import `ApfelCore` and convert.
public struct ChatMessage: Sendable, Equatable, Codable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// A minimal OpenAI-compatible `/v1/chat/completions` request body.
///
/// `ApfelServerKit` uses this to stream text deltas. If you need tool calls,
/// response formats, or other advanced features, build the JSON yourself or
/// import `ApfelCore`'s richer request types.
public struct ChatRequest: Sendable, Equatable, Codable {
    public var model: String
    public var messages: [ChatMessage]
    public var stream: Bool
    public var temperature: Double?

    public init(
        model: String = "apfel",
        messages: [ChatMessage],
        stream: Bool = true,
        temperature: Double? = nil
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.temperature = temperature
    }
}
