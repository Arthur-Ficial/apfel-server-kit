# apfel-server-kit

[![CI](https://github.com/Arthur-Ficial/apfel-server-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/Arthur-Ficial/apfel-server-kit/actions/workflows/ci.yml)
[![Swift 6](https://img.shields.io/badge/swift-6.0-orange.svg)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue.svg)](https://www.apple.com/macos/)

Shared Swift package for apfel ecosystem tools: discover the local `apfel` binary, spawn it as `apfel --serve`, poll `/health`, and stream `/v1/chat/completions` over Server-Sent Events - with Swift 6 strict concurrency, TDD, and honest errors.

> This package exists because five ecosystem tools (apfel-quick, apfel-chat, apfel-clip, apfel-gui, apfelpilot) each duplicated ~320 lines of the same subprocess lifecycle, port scanning, SSE parsing, and health polling. One shared library means bug fixes propagate everywhere. See [apfel#106](https://github.com/Arthur-Ficial/apfel/issues/106).

## Install

```swift
// In your Package.swift
dependencies: [
    .package(url: "https://github.com/Arthur-Ficial/apfel-server-kit.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourTool",
        dependencies: [
            .product(name: "ApfelServerKit", package: "apfel-server-kit"),
        ]
    ),
]
```

## Quick start

```swift
import ApfelServerKit

let server = ApfelServer()
let port = try await server.start()
defer { Task { await server.stop() } }

let client = ApfelClient(port: port)
for try await delta in client.stream(prompt: "Say hi in three words.") {
    if let text = delta.text { print(text, terminator: "") }
}
print()
```

Output:

```
Hello, dear reader.
```

## What you get

| Type | Purpose |
|------|---------|
| `ApfelServer` (actor) | Discover `apfel`, find a free port, spawn `apfel --serve`, poll `/health`, terminate on `stop()`. |
| `ApfelClient` | Stream `/v1/chat/completions` as `TextDelta` values; non-streaming health check. |
| `SSEParser` | Parse individual Server-Sent Event lines into typed `SSEEvent` values. |
| `ApfelBinaryFinder` | Locate `apfel` across `PATH`, bundle, Homebrew, `/usr/local/bin`, `~/.local/bin`. |
| `ChatRequest` | Minimal OpenAI-compatible chat request type - bring your own or convert from apfel's full types. |
| `ApfelServerError` | Typed errors: `.binaryNotFound`, `.noPortAvailable`, `.spawnFailed`, `.healthCheckTimeout`. |

## Design principles

- **100% local.** Talks only to `127.0.0.1`. No cloud, no external DNS.
- **Swift 6 strict concurrency.** `ApfelServer` is an `actor`. Everything crossing concurrency domains is `Sendable`.
- **TDD.** Every behavior has a failing test first. `swift run apfel-server-kit-tests` runs the full suite without XCTest.
- **Dependency-free.** No ApfelCore coupling, no Hummingbird coupling. Uses `URLSession`, `Process`, and `Darwin.bind()`.
- **Honest errors.** `ApfelServerError` tells you what failed and why, not "something went wrong".
- **Stable API.** See [STABILITY.md](STABILITY.md). `swift package diagnose-api-breaking-changes` runs in CI.

## Configuration

```swift
let server = ApfelServer(
    portRange: 11450...11459,           // default
    healthTimeout: .seconds(8),         // default
    arguments: ["--cors", "--permissive"] // default
)
```

If an existing apfel server is already listening inside `portRange` and answers `/health`, `start()` connects to it and sets `isManaged = false`. Calling `stop()` in that case is a no-op.

## Swift version

Swift 6.0 or later. Builds with Command Line Tools - no Xcode required.

## Testing

```bash
swift run apfel-server-kit-tests
```

The test runner is pure Swift (no XCTest, no Testing framework) - the same pattern apfel itself uses. It prints each case and exits non-zero on any failure.

## Documentation

```bash
swift package generate-documentation --target ApfelServerKit
```

Published DocC at `Sources/ApfelServerKit/Documentation.docc/`.

## License

MIT. See [LICENSE](LICENSE).
