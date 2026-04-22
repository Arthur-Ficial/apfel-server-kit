# Audit: existing patterns in apfel ecosystem tools

Snapshot of what ServerManager / SSEParser / service code looked like across apfel-quick, apfel-chat, apfel-clip on 2026-04-22, before extraction into apfel-server-kit. This is the behavioral contract the shared package must preserve.

## Binary discovery (union)

All three tools use the same search helper `findBinary(named:)`. Order:

1. `ProcessInfo.processInfo.environment["PATH"]` - colon-split, first match
2. bundle executable's parent directory (`MacOS/`)
3. bundle `Helpers/` subdirectory
4. `/opt/homebrew/bin/<name>`
5. `/usr/local/bin/<name>`
6. `~/.local/bin/<name>`

apfel-chat additionally searches for `ohr`. apfel-server-kit accepts a `name:` parameter so any ecosystem tool (including hybrid Apfel+Ohr apps) can use it.

## Port scanning

| Tool | Default range | Source |
|------|---------------|--------|
| apfel-quick | 11450...11459 | hardcoded `serverPortStart/End` |
| apfel-chat | 11434, 11435, 11440...11449 | inline in `tryExistingServer()` |
| apfel-clip | 11435, 11440...11449 | `candidatePorts(startingAt:)` |

All three use identical socket-based availability test: `Darwin.socket` + `SO_REUSEADDR` + `bind()` on `127.0.0.1`. No `lsof`, no TCP connect probe.

apfel-server-kit default is `11450...11459` (matches apfel-quick, the reference). Consumers can override.

## Subprocess spawn

Command: `apfel --serve --port <N> [flags]`

| Tool | Flags |
|------|-------|
| apfel-quick | `--cors --permissive` (always) |
| apfel-chat | `--cors` + conditional `--permissive` from `AppUserDefaults["ac_permissive"]` |
| apfel-clip | `--cors --permissive` (always) |

stdout/stderr: all three redirect to `FileHandle.nullDevice`.

apfel-server-kit: `arguments` parameter, default `["--cors", "--permissive"]`.

## Health polling

- Endpoint: `GET /health`
- Timeout defaults: request 0.25s, resource 0.5s, total wait 8.0s
- Interval: 200ms
- Success: HTTP 200 exactly
- apfel-quick + apfel-chat use a per-call ephemeral `URLSession`; apfel-clip uses `URLSession.shared` (we prefer the ephemeral pattern - no shared cookie jar).

## SSE parser test cases (contract)

From apfel-quick `SSEParserTests` (17 cases) plus apfel-chat `parseUsage` (1 case):

1. `testParseDataLineWithText` - `data: {"choices":[{"delta":{"content":"hi"}}]}` -> delta(text: "hi")
2. `testParseDataDone` - `data: [DONE]` -> `.done`
3. `testParseEmptyLine` -> `nil`
4. `testParseCommentLine` - `:` prefix -> `nil`
5. `testParseFinishReason` - `"finish_reason":"stop"` -> delta(text: nil, finishReason: "stop")
6. `testParseTextAndFinishReason` - both set -> delta(text, finishReason)
7. `testParseInvalidJSON` -> `.error(...)`
8. `testParseNonDataLine` -> `nil`
9. `testParseErrorLine` - `event: error\ndata: <payload>` -> `.error(payload)`
10. `testParseNullContent` - `"content": null` with no finish_reason -> `nil`
11. `testParseWhitespaceOnlyLine` -> `nil`
12. `testParseDataLineWithLeadingSpaceAfterColon` - `data:{...}` variant
13. `testParseFirstChoiceDeltaUsed` - multiple choices -> only index 0
14. `testParseEmptyChoicesArray` - `"choices":[]` -> `nil`
15. `testParseErrorOnNonErrorLineReturnsNil` - `event: other` -> `nil`
16. `testParseErrorOnEmptyLineReturnsNil` -> `nil`
17. `testParseFinishReasonLength` - `"finish_reason":"length"` variant
18. `testParseUsageOnlyPayload` (from apfel-chat) - `{"usage":{...}}` no choices -> `nil`

## Error types (union)

apfel-quick `QuickServiceError`, apfel-chat `ChatServiceError`, apfel-clip `ClipServiceError`:

- `.serverError(String)`
- `.streamError(String)`
- `.connectionFailed(String)`
- `.serverUnavailable`
- `.emptyResponse`
- `.invalidResponse`

apfel-server-kit consolidates these into `ApfelServerError` with stable names. Client-side stream errors surface as `Error` thrown into `AsyncThrowingStream`.

## Concurrency model

All three siblings: `@MainActor final class ServerManager`. apfel-server-kit moves to `actor ApfelServer` - intentional tightening. `@MainActor` is strictly stricter than a custom actor for call-site behavior, so any downstream SwiftUI view that `await`s `ApfelServer` just hops actors naturally.
