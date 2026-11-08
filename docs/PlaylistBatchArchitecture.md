# Playlist and Batch Architecture

Part 6 adds playlist discovery and durable parent/child batches without moving
batch policy into the single-item download pipeline.

## Part 5A baseline

At the start of Part 6:

| File | Lines | Existing responsibility |
| --- | ---: | --- |
| `Core/Downloads/DownloadCoordinator.swift` | 1,131 | Job identity, persisted/UI-visible job state, task ownership, coordinator events, and high-level orchestration |
| `Core/Downloads/DownloadPipelineRunner.swift` | 1,074 | One media item's analyze, resolve, transfer, process, verify, and export sequence |

Neither file owns playlist discovery, parent/child expansion, batch-wide
progress, download-archive policy, or batch recovery.

## Bounded Part 6 components

The intended dependency direction is:

```text
IllucetAppModel
   |
   +--> PlaylistAnalyzer ---------> embedded yt-dlp playlist API
   |
   +--> PlaylistChildJobFactory --> ExtractorEngine
   |                                |
   |                                v
   |                         DownloadCoordinator facade
   |
   +--> DownloadBatchController --> child-job commands
   |          |
   |          +--> BatchProgressAggregator
   |          +--> DownloadArchive
   |          +--> BatchRestoration
   |
   +--> BatchPackageService ------> ExportManager / bounded ZIP writer
```

### PlaylistAnalyzer

Classifies supported YouTube collection URLs and returns a bounded, sanitized
playlist inventory. It distinguishes a video referenced inside a collection,
a normal playlist, mix/radio, Shorts collection, and a private collection. It
never starts child extraction or downloading.

### PlaylistChildJobFactory

Turns an explicit item selection into independent media analyses and exact
child-job enqueue requests. It applies one configuration or a persisted
per-item override, numbering context, destination structure, the item limit,
and download-archive decisions. It calls only the public coordinator facade.

### DownloadBatchController

Owns durable batch identity, selected-entry state, parent lifecycle, and the
mapping to child job identities. It reduces immutable child-job updates into
batch progress and returns typed pause/resume/cancel/retry/remove commands. It
does not own `DownloadJob`, URLSession tasks, FFmpeg permits, or pipeline
tasks.

Batch admission pause is durable independently of child processing. Pause all stops
batch expansion before awaiting native child controls; Resume all admits each
paused child independently so a slot waiter cannot block other resume commands.
An explicit child retry carries a new request UUID. A stopped parent records the
previous UUIDs, ignores old queued updates, and reactivates only for a new retry.
Restoration uses the same rule, preserves skipped/archive items, and removal rejects
any parent with an active child. Snapshot version 8 adds optional admission-pause
and stopped-retry fields; versions 1–7 decode without them.

### BatchProgressAggregator

Computes counts, byte totals, and progress from persisted child jobs. Unknown
totals remain unknown. Terminal states are derived without treating a
duplicate/archive skip as failure.

### DownloadArchive

Stores the extractor site plus media ID only after a child reaches verified
completion. Archive membership is independent from history and the exported
file. Re-expansion can skip an archived ID without deleting any record or
file.

### BatchRestoration

Reconciles persisted batches with restored child jobs. Missing unfinished
children become attention items; completed children remain complete and are
never enqueued a second time. Individual transfer restoration continues to be
owned by `DownloadRestorationController`.

### BatchPackageService

Creates playlist folders and, when explicitly selected, a final verified ZIP
from completed child outputs. The ZIP writer streams stored entries in bounded
chunks, validates CRC/central-directory data, handles UTF-8 and ZIP64, and
publishes only through the existing atomic export flow. It does not add
subtitle, chapter, metadata sidecar, trimming, or SponsorBlock behavior from
later roadmap parts.

## Durable model

A persisted batch contains:

- stable batch and playlist identities;
- sanitized collection title, creator, thumbnail, and source URL;
- explicit selection mode and selected entry identities;
- one base `DownloadConfiguration` plus optional per-item overrides;
- destination structure, numbering width, item limit, archive policy, and
  continue-on-error policy;
- ordered item records with optional child job IDs and explicit skip/failure
  reasons;
- aggregated progress, lifecycle state, final package URL when applicable,
  and timestamps.

Each child `DownloadJob` carries only immutable membership and output context:
batch ID, playlist ID/index/title, filename-template values, and an optional
sanitized relative output directory. The existing scheduler continues to
schedule ordinary jobs, and the existing pipeline continues to execute one
ordinary media item.

## Concurrency and cancellation rules

- Playlist analysis and child creation are cancellable structured tasks.
- CPython extraction remains serialized by the existing Python engine.
- The factory does not hold a transfer or processing permit.
- Every child uses the existing scheduler and independent transfer/processing
  budgets.
- Batch Pause calls only valid child pause operations; processing is not
  mislabeled as paused.
- Batch Cancel cancels pending expansion and every non-terminal child.
- Stop-on-error prevents new child creation and cancels remaining non-terminal
  children at a safe coordinator boundary.
- Retry Failed restarts both the failed item and children halted by
  stop-on-error without duplicating a completed or archived item.
- Completed child rows can be dismissed only after any selected final ZIP has
  been published; their parent summary and download-archive identity remain.
- Removing a terminal parent cancels an in-flight child race before its
  terminal child records are removed from the coordinator.
- Restoration never persists signed URLs, headers, cookies, or Python objects.

## Line-count audit

| Checkpoint | Coordinator | Pipeline runner | Result |
| --- | ---: | ---: | --- |
| Part 6 baseline (`75055d6`) | 1,131 | 1,074 | No playlist/batch responsibility present |
| Schema 4 identity/persistence | 1,131 | 1,074 | Durable models added with no guarded-file growth |
| Playlist analysis and child factory | 1,133 | 1,074 | Coordinator gained only two lines of child membership wiring; analysis, expansion inputs, filename specialization, and identity verification live in bounded components |
| Batch lifecycle, restoration, and progress | 1,158 | 1,074 | Coordinator growth is generic queued-job pause/resume and snapshot access; parent lifecycle, aggregation, archive, stop-on-error, and recovery remain in separate Part 6 components |
| Selection UI, grouped queue, archive, and package output | 1,175 | 1,074 | Coordinator gained only generic validated active-job reordering; UI, package creation, and archive management are bounded elsewhere |
| Final cleanup/retry audit (`cb4272e`) | 1,185 | 1,074 | Ten generic lines remove a supplied set of terminal job identities; stop-on-error retry and completed-item dismissal stay in `DownloadBatchController` |

Part 6 is complete with a net coordinator increase of 54 lines and no pipeline
runner growth. Neither guarded file absorbed playlist discovery, parent/child
expansion, batch-wide progress, archive policy, packaging, or batch
restoration.
