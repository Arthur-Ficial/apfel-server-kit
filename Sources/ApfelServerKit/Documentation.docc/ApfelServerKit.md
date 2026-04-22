# ``ApfelServerKit``

Shared Swift building blocks for apfel ecosystem tools that talk to a local `apfel --serve` process.

`ApfelServerKit` contains the reusable parts that apfel-quick, apfel-chat, apfel-clip, apfel-gui, and apfelpilot each used to reimplement: binary discovery, port allocation, subprocess spawn and health polling, and Server-Sent Event parsing.

## Overview

Use `ApfelServerKit` when you want to:

- spawn a managed `apfel --serve` subprocess from a Swift app with one line
- stream `/v1/chat/completions` responses without hand-rolling SSE parsing
- reuse the same binary-discovery logic that apfel-quick and apfel-chat ship
- write your own apfel ecosystem tool without copying ServerManager.swift from a sibling repo

## Topics

### Essentials

- ``ApfelServer``
- ``ApfelClient``

### Discovery and transport

- ``ApfelBinaryFinder``
- ``SSEParser``
- ``SSEEvent``
- ``TextDelta``

### Requests and errors

- ``ChatRequest``
- ``ChatMessage``
- ``ApfelServerError``
