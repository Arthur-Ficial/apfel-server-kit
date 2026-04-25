# Changelog

All notable changes to apfel-server-kit are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-04-25

### Added

- `ChatRequest.maxTokens: Int?` — optional cap on output tokens, encoded as `max_tokens` to match OpenAI shape. Without this, apfel streams until the 4096-token context overflows; setting it lets short-bounded callers (one-line decisions, batch scripts) drop per-call latency from ~50 s to ~1.3 s.
- `ApfelClient.completeOnce(_:) async throws -> String` — non-streaming chat completion. Forces `stream = false`, decodes the OpenAI response inline, returns the assistant content as one string.

### Changed

- `ApfelServer.start()` is now idempotent. A second `start()` without an intervening `stop()` returns the cached port immediately — no re-probe of the range, no risk of accidentally double-spawning.
- `ApfelServer.pollHealth()` fast-fails when the spawned subprocess dies during bring-up. Previously a binary that exited immediately (mis-config, crash) made `start()` wait the full `healthTimeout` (default 8 s) for a corpse; now it throws `healthCheckTimeout` in the next ~250 ms poll iteration.
- `ApfelServer.stop()` escalates SIGTERM → SIGKILL after a 500 ms grace period and reaps the process synchronously. Previously a wedged apfel that ignored SIGTERM kept holding its port forever; now the port is freed within ~500 ms even against an uncooperative server. The same escalation path runs from `start()`'s catch handler.

### Fixed

- `ChatRequest.init(model:messages:stream:temperature:)` — the v1.0.0 4-arg initializer is now preserved as an explicit overload, so `swift package diagnose-api-breaking-changes` reports zero diff against the previous tag. Adding the new 5th `maxTokens:` parameter would otherwise have changed the symbol.

### CI

- `api-breakage` job no longer uses `continue-on-error: true`. Real API breakage now actually fails the PR. macos-14 runner's spurious "every public type removed" messages are filtered through `.api-breakage-allowlist.txt`; any genuine new removal shows up as an additional message and fails the job.

## [1.0.0] - 2026-04-22

### Added

- Initial public release.
- `ApfelBinaryFinder` - discovers the `apfel` binary across PATH, bundle, Homebrew, `/usr/local/bin`, `~/.local/bin`.
- `ApfelServer` actor - spawns and manages an `apfel --serve` subprocess with configurable port range, health timeout, and arguments.
- `ApfelClient` - streams `/v1/chat/completions` responses over Server-Sent Events; exposes `isHealthy()`, `stream(prompt:)`, and `chatCompletions(_:)`.
- `SSEParser` - parses individual SSE lines into `SSEEvent` values (delta, done, error) with `TextDelta` payloads.
- `ApfelServerError` - typed errors covering binary discovery, port allocation, spawn failure, and health-check timeout.
- Swift 6 strict concurrency throughout.
- DocC catalog at `Sources/ApfelServerKit/Documentation.docc/`.
- Extracted from duplicated ServerManager/SSEParser code across apfel-quick, apfel-chat, and apfel-clip (see [apfel#106](https://github.com/Arthur-Ficial/apfel/issues/106)).
