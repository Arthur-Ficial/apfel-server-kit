# apfel-server-kit Implementation Plan

> Extracted from duplicated ServerManager/SSEParser code across apfel-quick, apfel-chat, apfel-clip. See [apfel#106](https://github.com/Arthur-Ficial/apfel/issues/106) and [../docs/audit.md](./audit.md) for the behavioral contract.

**Goal:** Ship a Swift 6 package `ApfelServerKit` that replaces five hand-rolled ServerManagers with one shared, tested, stable API.

**Architecture:** Actor-isolated `ApfelServer` for lifecycle, `Sendable` value types for data, `URLSession`-based SSE client, pure static helpers for discovery/parsing. No dependencies beyond swift-docc-plugin.

**Tech Stack:** Swift 6.0, Foundation, URLSession, Darwin sockets. macOS 14+.

---

## Task order

Each task is TDD: red test first, green minimal implementation, commit.

### Task 1: `TextDelta` + `SSEEvent` value types

**Files:** `Sources/ApfelServerKit/SSEEvent.swift`, `Tests/ApfelServerKitTests/SSEEventTests.swift`

- Types: `TextDelta { text: String?, finishReason: String? }`, `SSEEvent { delta(TextDelta) | done | error(String) }`, both `Sendable, Equatable`.
- Test: round-trip equality, finish-reason variants (`stop`, `length`, `null`).

### Task 2: `SSEParser` (17 apfel-quick cases + 1 parseUsage from apfel-chat)

**Files:** `Sources/ApfelServerKit/SSEParser.swift`, `Tests/ApfelServerKitTests/SSEParserTests.swift`

- `public enum SSEParser { public static func parse(line: String) -> SSEEvent? }`
- Contract (ported from audit):
  - `data: {"choices":[{"delta":{"content":"hi"}}]}` -> `.delta(text: "hi", finishReason: nil)`
  - `data: [DONE]` -> `.done`
  - Empty line / comment `:` / whitespace-only -> `nil`
  - `data: {"choices":[{"delta":{"content":null}}]}` -> `nil`
  - `data: {"choices":[{"finish_reason":"stop"}]}` -> `.delta(text: nil, finishReason: "stop")`
  - `data: {"choices":[{"finish_reason":"length"}]}` -> `.delta(text: nil, finishReason: "length")`
  - `data: not-json` -> `.error("...")` (invalid JSON)
  - `data: {}` (no choices) -> `nil`
  - Leading space after colon handled (`data:{...}` and `data: {...}` both valid)
  - Only first choice used when multiple present
  - Explicit `event: error\ndata: ...` -> `.error(payload)`
  - `data: {"usage":{...}}` (no choices) -> `nil` (from apfel-chat)
- 18 tests total.

### Task 3: `ApfelBinaryFinder`

**Files:** `Sources/ApfelServerKit/ApfelBinaryFinder.swift`, `Tests/ApfelServerKitTests/ApfelBinaryFinderTests.swift`

- `public enum ApfelBinaryFinder { public static func find(name: String = "apfel", fileManager: FileManager = .default, environment: [String: String] = ProcessInfo.processInfo.environment, bundleExecutableURL: URL? = Bundle.main.executableURL) -> String? }`
- Search order (union of all three ecosystem tools):
  1. `environment["PATH"]` components
  2. bundle executable's parent directory (`MacOS/`)
  3. bundle's `Helpers/` subdirectory
  4. `/opt/homebrew/bin`
  5. `/usr/local/bin`
  6. `~/.local/bin` (expanded from `environment["HOME"]`)
- Inject dependencies for testability. Tests use a stub `FileManager` subclass + curated env.

### Task 4: `ApfelServerError`

**Files:** `Sources/ApfelServerKit/ApfelServerError.swift` (no dedicated tests file - exercised via ApfelServer tests)

- `public enum ApfelServerError: Error, Equatable, Sendable { case binaryNotFound, noPortAvailable(ClosedRange<Int>), spawnFailed(String), healthCheckTimeout(port: Int, elapsed: Duration) }`
- `LocalizedError` conformance for friendly messages.

### Task 5: Port scanner helper

**Files:** `Sources/ApfelServerKit/PortScanner.swift`, `Tests/ApfelServerKitTests/PortScannerTests.swift`

- `enum PortScanner { static func isAvailable(_ port: Int) -> Bool; static func firstAvailable(in range: ClosedRange<Int>) -> Int? }`
- Uses `Darwin.socket/bind/close` with `SO_REUSEADDR` on `127.0.0.1` (matches all three sibling tools exactly).
- Test: pick a port that the OS randomly assigns, bind it, verify `isAvailable` returns `false`; close, verify `true`.

### Task 6: `ChatRequest` + `ChatMessage`

**Files:** `Sources/ApfelServerKit/ChatRequest.swift`, `Tests/ApfelServerKitTests/ChatRequestTests.swift`

- Minimal OpenAI-compatible types - deliberately thin so consumers who want full types import ApfelCore separately.
- `ChatMessage { role: String, content: String }`, `ChatRequest { model: String, messages: [ChatMessage], stream: Bool, temperature: Double? }`, both `Codable, Sendable, Equatable`.
- Tests: JSON encode/decode round-trip matches OpenAI shape.

### Task 7: `ApfelServer` actor

**Files:** `Sources/ApfelServerKit/ApfelServer.swift`, `Tests/ApfelServerKitTests/ApfelServerTests.swift`

- `public actor ApfelServer`
- `init(portRange: ClosedRange<Int> = 11450...11459, healthTimeout: Duration = .seconds(8), arguments: [String] = ["--cors", "--permissive"], binaryFinder: () -> String? = ApfelBinaryFinder.find)`
- `func start() async throws -> Int`
- `func stop() async`
- `var port: Int? { get }`, `var isManaged: Bool { get }`
- Behavior:
  1. Probe each port in range via `/health` - if one answers, connect and set `isManaged = false`.
  2. Else, find first available port, spawn `apfel --serve --port <N> <arguments...>`, suppress stdio to `FileHandle.nullDevice`, poll `/health` every 200ms for up to `healthTimeout`.
  3. `stop()` calls `process.terminate()` if managed.
- Tests:
  - `startFailsWithBinaryNotFound` - binaryFinder returns nil -> `ApfelServerError.binaryNotFound`.
  - `startFailsWithNoPortAvailable` - all ports bound -> `.noPortAvailable`.
  - `stopIsNoOpWhenNotStarted` - no crash.
  - `startConnectsToExistingHealthyServer` - spin a tiny HTTP 200 `/health` mock on a port in range, verify `isManaged == false`.
  - `healthCheckTimeoutIfBinaryNeverAnswers` - binaryFinder returns `/bin/sleep` (spawns, never answers `/health`) -> `.healthCheckTimeout` within bounded time.

### Task 8: `ApfelClient`

**Files:** `Sources/ApfelServerKit/ApfelClient.swift`, `Tests/ApfelServerKitTests/ApfelClientTests.swift`

- `public struct ApfelClient: Sendable { init(port: Int, host: String = "127.0.0.1"); isHealthy() async -> Bool; stream(prompt: String, model: String = "apfel") -> AsyncThrowingStream<TextDelta, Error>; chatCompletions(_: ChatRequest) -> AsyncThrowingStream<TextDelta, Error> }`
- Uses `URLSession.shared.bytes(for:)` to read SSE lines, feeds each line into `SSEParser.parse(line:)`.
- Tests: spin a local `Foundation` HTTP server that returns canned SSE bytes, verify deltas stream in order and terminator `[DONE]` closes the stream.

### Task 9: CI + API-breakage guard

**Files:** `.github/workflows/ci.yml`

- Jobs: `build-and-test` (macos-14 runner, `swift build` + `swift run apfel-server-kit-tests`), `strict-concurrency` (`swift build -Xswiftc -strict-concurrency=complete`), `docc` (`swift package generate-documentation --warnings-as-errors`), `api-breakage` (`swift package diagnose-api-breaking-changes <latest-tag>`).
- Skipped on the first commit / before the first tag exists.

### Task 10: Tag 1.0.0 + comment back on apfel#106

- `git tag 1.0.0 && git push origin 1.0.0`
- `gh release create 1.0.0 --generate-notes`
- Post comment on Arthur-Ficial/apfel#106 linking the repo + tag + migration order.

---

## Self-review checklist

- [ ] Every task produces working, testable code.
- [ ] No task references a type or method not defined in a prior task (or injected for test).
- [ ] Binary discovery paths match the audit order exactly.
- [ ] Default port range matches the issue proposal (11450...11459).
- [ ] SSE parser covers all 17 apfel-quick cases + parseUsage from apfel-chat.
- [ ] `ApfelServer` is `actor` (not class, not `@MainActor`) - the audit noted all three siblings are `@MainActor final class`; moving to `actor` is intentional (stricter, safer).
- [ ] No backwards-compat shim for the ecosystem tools - their migration PRs land separately.
