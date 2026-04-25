import Foundation

/// Thin HTTP client for a local apfel server's OpenAI-compatible endpoints.
///
/// `ApfelClient` is a value type and is safe to share across concurrency
/// domains. It holds a URL and nothing else - the underlying `URLSession`
/// is created per call so aborts and cancellations are clean.
public struct ApfelClient: Sendable {

    public let host: String
    public let port: Int

    public init(port: Int, host: String = "127.0.0.1") {
        self.host = host
        self.port = port
    }

    /// Return `true` when `GET /health` answers HTTP 200 within a short window.
    public func isHealthy() async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/health") else { return false }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.25
        config.timeoutIntervalForResource = 0.5
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Stream text deltas for a single user-role prompt.
    public func stream(
        prompt: String,
        model: String = "apfel"
    ) -> AsyncThrowingStream<TextDelta, Error> {
        let request = ChatRequest(
            model: model,
            messages: [ChatMessage(role: "user", content: prompt)],
            stream: true
        )
        return chatCompletions(request)
    }

    /// Send a chat request and return the full assistant reply as one string.
    /// Use this when you don't need incremental tokens — it's simpler than the
    /// streaming variant and avoids the SSE parsing path entirely. Forces
    /// `stream = false` regardless of what the caller set on the request.
    public func completeOnce(_ request: ChatRequest) async throws -> String {
        guard let url = URL(string: "http://\(host):\(port)/v1/chat/completions") else {
            throw ApfelClientError.invalidURL
        }
        var req = request
        req.stream = false
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(req)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ApfelClientError.httpStatus(http.statusCode)
        }
        struct Response: Decodable {
            struct Choice: Decodable { let message: ChatMessage }
            let choices: [Choice]
        }
        let parsed = try JSONDecoder().decode(Response.self, from: data)
        return parsed.choices.first?.message.content ?? ""
    }

    /// Send a full chat request and stream the deltas back.
    public func chatCompletions(
        _ request: ChatRequest
    ) -> AsyncThrowingStream<TextDelta, Error> {
        let host = self.host
        let port = self.port
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "http://\(host):\(port)/v1/chat/completions") else {
                        continuation.finish(throwing: ApfelClientError.invalidURL)
                        return
                    }
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.httpBody = try JSONEncoder().encode(request)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        continuation.finish(throwing: ApfelClientError.httpStatus(http.statusCode))
                        return
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        switch SSEParser.parse(line: line) {
                        case .delta(let delta):
                            continuation.yield(delta)
                        case .done:
                            continuation.finish()
                            return
                        case .error(let msg):
                            continuation.finish(throwing: ApfelClientError.stream(msg))
                            return
                        case .none:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Errors thrown into an `ApfelClient` stream.
public enum ApfelClientError: Error, Equatable, Sendable {
    case invalidURL
    case httpStatus(Int)
    case stream(String)
}

extension ApfelClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "apfel client could not construct a valid URL from host/port."
        case .httpStatus(let code):
            return "apfel server returned HTTP \(code)."
        case .stream(let message):
            return "apfel stream error: \(message)."
        }
    }
}
