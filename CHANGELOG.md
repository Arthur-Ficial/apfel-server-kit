# Changelog

All notable changes to apfel-server-kit are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
