import Foundation

/// A single streamed delta from an OpenAI-compatible `/v1/chat/completions` response.
public struct TextDelta: Sendable, Equatable {
    /// The next chunk of generated text, if any. `nil` for a finish-reason-only delta.
    public let text: String?
    /// The finish reason (`"stop"`, `"length"`, ...), present on the terminating delta.
    public let finishReason: String?

    public init(text: String?, finishReason: String?) {
        self.text = text
        self.finishReason = finishReason
    }
}

/// A parsed Server-Sent Event from an apfel HTTP response stream.
public enum SSEEvent: Sendable, Equatable {
    /// A content or finish-reason delta.
    case delta(TextDelta)
    /// Stream terminator (`data: [DONE]`).
    case done
    /// The server emitted an error event. The payload is the human-readable reason.
    case error(String)
}
