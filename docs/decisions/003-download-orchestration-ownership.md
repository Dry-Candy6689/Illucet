# Decision 003 — Download Orchestration Ownership

Status: Active

## Decision

`DownloadCoordinator` remains the job-identity actor and public queue facade. It must not regrow into the owner of every download algorithm.

Bounded owners remain responsible for their domains, including scheduling/permits, pipeline sequencing, retries, restoration, network continuations, export completion, conversion planning/execution, playlists/batches, subtitles, chapters, trimming, packages, and ZIP writing.

Future work extends the relevant seam instead of adding unrelated branches to `DownloadCoordinator`, `DownloadPipelineRunner`, or `IllucetAppModel`.

## Why

Part 5A and later checkpoints decomposed a large coordinator so future playlist, fragmented-transfer, conversion, subtitle, and export features could evolve without recreating a monolith. Keeping identity/state ownership separate from algorithms improves testability and limits regression scope.

## Key invariants

- Only `DownloadCoordinator` owns the in-memory `DownloadJob` dictionary and per-job pipeline task creation/cancellation.
- Bounded components communicate UI-visible job changes through typed callback/context seams.
- Playlist parents/children remain outside the single-item pipeline algorithm.
- Retry/re-resolution does not reuse expired signed URLs.
- Future HLS/DASH transfer work belongs behind `StreamDownloading` and existing retry/restoration seams rather than coordinator-specific networking.

## Related contracts

- `docs/Architecture.md`
- `docs/Architecture.md`
