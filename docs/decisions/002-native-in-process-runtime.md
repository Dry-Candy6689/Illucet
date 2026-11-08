# Decision 002 — Native In-Process Runtime

Status: Active

## Decision

Illucet's runtime architecture remains native and in-process:

- embedded CPython drives the typed yt-dlp integration;
- QuickJS-ng executes the pinned EJS challenge path through native APIs;
- FFmpeg functionality is exposed through typed native C APIs;
- iOS runtime code does not launch shell commands, `Process`, bundled executables, or child-process JavaScript/media tools.

Unsafe/native details stay behind bounded bridges. SwiftUI and ordinary app state do not receive raw Python objects, FFmpeg structures, unsafe pointers, signed media URLs, cookies, tokens, or unbounded raw extractor dictionaries.

## Why

The architecture must work inside the iOS application sandbox without relying on executable subprocesses. Typed in-process boundaries also keep cancellation, validation, secret handling, and output verification under application control.

## Rejected alternatives

- spawning Deno, Node, Bun, `qjs`, ffmpeg, or other bundled executables;
- command-line FFmpeg argument surfaces inside the app;
- passing raw Python/native objects into UI state;
- external conversion/extraction servers as a substitute for the on-device architecture.

## Change rule

A future task may extend a bounded native/Swift boundary, but must not silently replace this architecture. Any deliberate architecture migration requires an explicit user decision and corresponding current-contract updates.

## Related contracts

- `docs/Architecture.md`
- `docs/YTDLPIntegration.md`
- `docs/NativeFFmpegBridgeArchitecture.md`
