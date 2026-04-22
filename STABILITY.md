# Stability and Compatibility

## What "1.0" means for apfel-server-kit

apfel-server-kit 1.0 is a stable release of the public Swift API for discovering, spawning, and streaming from a local `apfel --serve` process. The types, methods, and behaviors documented here are semver-protected.

## What is stable (semver-protected)

- Public types: `ApfelServer`, `ApfelClient`, `ApfelBinaryFinder`, `SSEParser`, `SSEEvent`, `TextDelta`, `ChatRequest`, `ApfelServerError`
- Default port range (`11450...11459`), health endpoint (`/health`), health timeout default (`8` seconds)
- Subprocess arguments defaults (`--cors --permissive`)
- Binary discovery search order: `PATH`, bundle executable directory, `Helpers/` subdirectory, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`
- SSE parsing behavior for OpenAI-compatible `/v1/chat/completions` responses

## What is NOT stable

- **apfel's own model output.** apfel-server-kit is transport; text content comes from Apple's on-device FoundationModels. See [apfel/STABILITY.md](https://github.com/Arthur-Ficial/apfel/blob/main/STABILITY.md).
- **Error message strings.** `ApfelServerError` case names are stable; the associated `String` values may improve.
- **Performance.** Health poll cadence and startup latency depend on apfel, the OS, and hardware state.

## Versioning

Semantic versioning:

- **PATCH** (1.0.x): bug fixes, documentation, CI changes
- **MINOR** (1.x.0): new public API (backward-compatible)
- **MAJOR** (x.0.0): removed or renamed public API, changed default behaviors

apfel-server-kit versions independently of apfel. It targets apfel's published HTTP surface, which is itself semver-protected.

## Deprecation Policy

- Public APIs deprecate before removal.
- A deprecation lands in one released version with `@available(*, deprecated, ...)`.
- The deprecated API remains available through the next compatible release line.
- Removal happens only in a major release.
- Public-surface changes are called out in [CHANGELOG.md](CHANGELOG.md).

## CI enforcement

Every PR runs `swift package diagnose-api-breaking-changes` against the most recent tag. A breaking public-API change fails CI unless the PR is tagged as a major bump.

## Our commitment

- Clean Swift 6 strict-concurrency code. No `@unchecked Sendable` without explicit thread-safety notes.
- TDD for every public behavior.
- No network dependencies beyond talking to a local `apfel --serve` process.
- Honest errors with actionable messages.
