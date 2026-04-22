import Foundation
import ApfelServerKit
import Network
import Darwin

/// Large-payload and many-frame coverage to catch buffering bugs,
/// byte-accounting mistakes, and protocol framing issues.
func runLargePayloadTests() {

    testAsync("stream handles a 1MB single content delta") {
        let oneMB = String(repeating: "a", count: 1_048_576)
        let sse = #"data: {"choices":[{"delta":{"content":"\#(oneMB)"}}]}"# + "\n\ndata: [DONE]\n\n"
        let server = try await PayloadMockServer.start(sse: sse)
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)

        var total = 0
        for try await d in client.stream(prompt: "x") {
            total += d.text?.count ?? 0
        }
        try assertEqual(total, 1_048_576)
    }

    testAsync("stream handles 500 small deltas without reordering") {
        var sse = ""
        for i in 0..<500 {
            sse += #"data: {"choices":[{"delta":{"content":"\#(i),"}}]}"# + "\n\n"
        }
        sse += "data: [DONE]\n\n"
        let server = try await PayloadMockServer.start(sse: sse)
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)

        var collected: [String] = []
        for try await d in client.stream(prompt: "go") {
            if let t = d.text { collected.append(t) }
        }
        let expected = (0..<500).map { "\($0)," }.joined()
        try assertEqual(collected.joined(), expected)
        try assertEqual(collected.count, 500)
    }

    testAsync("parser handles a 2MB content payload in a single line") {
        let twoMB = String(repeating: "x", count: 2_097_152)
        let line = #"data: {"choices":[{"delta":{"content":"\#(twoMB)"}}]}"#
        switch SSEParser.parse(line: line) {
        case .delta(let d):
            try assertEqual(d.text?.count, 2_097_152)
        default:
            throw TestFailure("expected .delta")
        }
    }

    testAsync("ChatRequest encodes 100 messages without breaking") {
        var messages: [ChatMessage] = []
        for i in 0..<100 {
            messages.append(ChatMessage(role: "user", content: "Message \(i)"))
        }
        let req = ChatRequest(messages: messages)
        let data = try JSONEncoder().encode(req)
        let back = try JSONDecoder().decode(ChatRequest.self, from: data)
        try assertEqual(back.messages.count, 100)
        try assertEqual(back.messages[99].content, "Message 99")
    }

    testAsync("ChatMessage with 100KB content round-trips cleanly") {
        let big = String(repeating: "字", count: 33_000) // each '字' is 3 UTF-8 bytes -> ~99KB
        let m = ChatMessage(role: "user", content: big)
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ChatMessage.self, from: data)
        try assertEqual(back.content.count, big.count)
    }

    testAsync("stream copes with rapid small packets followed by large ones") {
        // Simulates a model that streams word-by-word then dumps a paragraph.
        var sse = ""
        for w in ["The", " quick", " brown", " fox"] {
            sse += #"data: {"choices":[{"delta":{"content":"\#(w)"}}]}"# + "\n\n"
        }
        let para = String(repeating: " jumped over the lazy dog.", count: 200)
        sse += #"data: {"choices":[{"delta":{"content":"\#(para)"}}]}"# + "\n\n"
        sse += "data: [DONE]\n\n"
        let server = try await PayloadMockServer.start(sse: sse)
        defer { server.listener.cancel() }
        let client = ApfelClient(port: server.port)

        var out = ""
        for try await d in client.stream(prompt: "x") {
            if let t = d.text { out += t }
        }
        try assertTrue(out.hasPrefix("The quick brown fox"))
        try assertTrue(out.count > 200 * 20)
    }
}

// MARK: - Payload mock server

private struct PayloadMockServer: Sendable {
    let port: Int
    let listener: NWListener

    static func start(sse: String) async throws -> PayloadMockServer {
        let (port, fd) = reservePayloadPort()
        Darwin.close(fd)
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(sse.utf8.count)\r\nConnection: close\r\n\r\n\(sse)"
                connection.send(
                    content: response.data(using: .utf8),
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready where !resumed: resumed = true; cont.resume()
                case .failed(let e) where !resumed: resumed = true; cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        return PayloadMockServer(port: port, listener: listener)
    }
}

private func reservePayloadPort() -> (Int, Int32) {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    precondition(fd >= 0)
    var yes: Int32 = 1
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.getsockname(fd, sa, &len)
        }
    }
    return (Int(UInt16(bigEndian: bound.sin_port)), fd)
}
