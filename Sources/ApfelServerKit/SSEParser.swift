import Foundation

/// Parses individual Server-Sent Event lines from an apfel `/v1/chat/completions`
/// response into typed `SSEEvent` values.
///
/// The parser is stateless and operates one line at a time - call it for each
/// `\n`-separated line your `URLSession.bytes(for:)` consumer produces.
/// It returns `nil` for keep-alive lines, comments, and other non-data lines;
/// otherwise it returns a `.delta(...)`, `.done`, or `.error(...)`.
public enum SSEParser: Sendable {

    /// Parse a single SSE line.
    /// - Returns: `nil` when the line contains no actionable event (empty, comment,
    ///   keep-alive, null-content delta, usage-only payload, empty `choices` array),
    ///   otherwise the decoded event.
    public static func parse(line: String) -> SSEEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix(":") { return nil } // comment / keep-alive

        // Explicit error line: "error: <payload>"
        if trimmed.lowercased().hasPrefix("error:") {
            let payload = String(trimmed.dropFirst("error:".count))
                .trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { return nil }
            return .error(payload)
        }

        // Only data: lines carry content. All other SSE fields (event:, id:, retry:)
        // are ignored by apfel clients.
        guard trimmed.lowercased().hasPrefix("data:") else { return nil }
        var payload = String(trimmed.dropFirst("data:".count))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        let stripped = payload.trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty { return nil }
        if stripped == "[DONE]" { return .done }

        guard let data = stripped.data(using: .utf8) else {
            return .error("SSE payload is not valid UTF-8")
        }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .error("SSE payload is not valid JSON: \(error.localizedDescription)")
        }
        guard let root = obj as? [String: Any] else {
            return .error("SSE payload is not a JSON object")
        }

        guard let choices = root["choices"] as? [[String: Any]], !choices.isEmpty else {
            // No choices (e.g. usage-only telemetry frame) - nothing actionable.
            return nil
        }

        let first = choices[0]
        let finishReason = first["finish_reason"] as? String
        let text = (first["delta"] as? [String: Any])?["content"] as? String

        // Null content with no finish reason: keep-alive delta, no event.
        if text == nil && finishReason == nil { return nil }

        return .delta(TextDelta(text: text, finishReason: finishReason))
    }
}
