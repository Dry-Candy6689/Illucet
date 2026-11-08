# Decision 004 — Truthful Output and Atomic Publication

Status: Active

## Decision

Illucet must never silently substitute a different codec, container, media mode, effective output request, destination, export outcome, or processing path from the one the user selected.

A requested output is accepted as complete only after its required properties are verified. Publication happens only after verification; failure or cancellation must not leave a false-success final output.

Multi-file outputs that are defined as one destination result — including primary media plus required chapter files and P8.15 standalone Subtitles Only file sets — use transactional publication semantics: resolve collisions first, stage/verify the full set, commit only when the set is ready, and restore replaced pre-existing bytes if a later commit step fails.

## Why

The project prioritizes trustworthy files over optimistic UI success. Earlier work added container/codec probing, full decode checks, partial-file publication, ZIP readback, and rollback-safe export specifically to prevent mislabeled, corrupt, incomplete, or partially published results.

P8.15 extends the same truth rule to non-media output: a Subtitles Only request owns only its verified selected VTT/SRT files. It must not fabricate a media URL/probe merely to reuse a media-oriented export path.

## Required invariants

- unsupported selections fail closed rather than being replaced by a convenient alternative;
- processing/preparation writes to unique temporary/partial paths before final publication;
- required output properties are verified before success using the appropriate verifier for that output type;
- cancellation/failure removes this attempt's incomplete output;
- history reflects the actual effective output request, files, export result, and destination;
- one logical multi-file result is collision-preflighted and committed as a set;
- package/ZIP outputs verify their finalized contents before publication;
- standalone subtitle sets verify VTT/SRT outputs and complete-set publication without requiring a media probe;
- current UI identity describes the effective output truthfully.

## Related contracts

- `docs/KnownLimitations.md`
- `docs/StorageAndExports.md`
- `docs/SubtitleSidecarArchitecture.md`
- `docs/NativeFFmpegBridgeArchitecture.md`
- `docs/Architecture.md`
