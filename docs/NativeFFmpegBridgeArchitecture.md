# Native FFmpeg Bridge Architecture

Status: Part 7A decomposition, Part 8 subtitle/chapter extensions, the Part 9 SponsorBlock media-processing extension, and the P10.3A deterministic fragmented-media fixture/probe evidence are simulator-tested. This document defines the native/media ownership boundary later work must preserve.

## Public C boundary

`Native/FFmpegBridge/IllucetFFmpegBridge.h` remains the sole Swift/C public FFmpeg interface. Part 7A did not rename/remove/change existing public lifecycle/status/ownership behavior. Part 8 added only typed subtitle-embed and chapter-write requests.

**Part 9 adds no new public C/FFmpeg SponsorBlock command or filtergraph surface.** Multi-range SponsorBlock removal is a typed Swift `MediaProcessingOperation.removeRanges` request handled by the existing Swift media processor through the bounded AVFoundation editor path, followed by the existing FFmpeg-backed probe/full-verification/publication contract.

P10.3 checkpoint A adds only `illucet_ffmpeg_generate_dash_fixture`, a bounded
deterministic fragmented-MP4 test-fixture generator in
`IllucetFFmpegFixtures.c`. Production assembly remains Swift bounded streaming
I/O and validation uses the existing typed native probe; no native assembler,
manifest parser, or new production processing operation was added.

There is still no arbitrary command-line surface, raw filtergraph string API, or FFmpeg-object exposure to Swift.

`IllucetFFmpegBridgeInternal.h` remains private to native implementation. New helpers should stay file-local unless at least two bounded native modules intentionally share them.

## Native responsibility ownership

The pre-Part-7A `IllucetFFmpegBridge.c` was a 5,002-line monolith. The completed bounded split remains:

| Implementation | Recorded Part 7A/8 size | Ownership |
| --- | ---: | --- |
| `IllucetFFmpegBridge.c` | 48 | Narrow version/configuration façade and version JSON |
| `IllucetFFmpegSupport.c` | 542 | Job lifecycle, cancellation, progress, errors, partial publication, shared lifetime/helpers |
| `IllucetFFmpegProbe.c` | 512 | Probe JSON, stream/format facts, full packet decode, verification facts |
| `IllucetFFmpegAudio.c` | 1,094 | Audio decode/encode/filter/FIFO/resampling/rate-control/loudness/progress |
| `IllucetFFmpegVideo.c` | 841 | Video decode/encode/filter/VideoToolbox/HDR/reporting/progress |
| `IllucetFFmpegStreamCopy.c` | 480 | Stream copy, remux, merge, original-audio extraction, video-only copy |
| `IllucetFFmpegMetadata.c` | 130 | Metadata mapping, fast-start/muxer options, output-header policy |
| `IllucetFFmpegArtwork.c` | 325 | Artwork input/attachment/disposition/publication |
| `IllucetFFmpegFixtures.c` | 754 | Deterministic native fixtures, including the P10.3A fragmented-MP4 source fixture |
| `IllucetFFmpegProof.c` | 303 | Aggregate native proof orchestration |
| `IllucetFFmpegSubtitles.c` | 800 | Compatible text-subtitle muxing and verification |
| `IllucetFFmpegChapters.c` | 344 | Bounded chapter validation/writing and reopened verification |

No Part 9 implementation regrows the C façade or adds a SponsorBlock C module because the selected supported range-edit path is owned above the C bridge.

## Swift media-processing boundary

`Core/MediaProcessing/MediaProcessor.swift` is the typed Swift boundary around production media processing. Implementations own all native/AVFoundation handles and must honor cooperative `Task` cancellation plus explicit operation cancellation.

Part 9 adds:

- `MediaProcessingOperation.removeRanges(mediaURL:mode:keptRanges:)`;
- optional `MediaProcessingResult.appliedTimeRanges` so a Fast edit can report the real boundaries it used;
- media-probe A/V synchronization verification used by SponsorBlock execution.

`Core/MediaProcessing/NativeFFmpegMediaProcessor.swift` remains the production processor and staged-publication owner. For `removeRanges`, it dispatches to `Core/MediaProcessing/AVFoundationMediaEditor.swift`, then:

1. probes the staged result with the existing native probe;
2. derives verification duration from actual applied kept ranges when present;
3. performs full output verification;
4. atomically moves the verified sibling partial to the requested temporary workflow URL;
5. removes staged output on failure/cancellation.

The name `NativeFFmpegMediaProcessor` therefore still represents the production media-processing/verification boundary; not every specialized edit algorithm must itself be implemented in C/FFmpeg.

## SponsorBlock range-edit owner

`AVFoundationMediaEditor.removeRanges` owns the bounded one-pass composition/edit mechanics used by P9.6/P9.7:

- validates ordered finite kept source ranges;
- composes one video and/or one audio stream over the kept intervals;
- Accurate video uses the supported H.264/HEVC encode path;
- Accurate Audio Only uses the supported AAC/M4A writer path;
- Fast requires a video stream, inspects actual sync samples/keyframes, aligns requested kept boundaries to proven keyframes, and uses passthrough export;
- returns actual applied kept ranges to the typed processor;
- cooperatively cancels and never promotes an unverified partial.

Source-to-final timeline policy, eligibility, chapter transformation, requested-versus-actual SponsorBlock facts, and checkpoint decisions do **not** live in the editor. They belong to `Core/SponsorBlock/SponsorBlockExecutionWorkflow.swift`.

## Invariants

Every production media operation, whether the inner edit is FFmpeg or AVFoundation, preserves these rules:

1. Validate typed arguments and fail closed on unsupported combinations.
2. Keep native objects/handles inside their bounded implementation owner.
3. Check cooperative cancellation and propagate a typed cancelled outcome.
4. Report bounded stage progress.
5. Write to a unique sibling partial/staging output.
6. Close native/AVFoundation resources on every exit path.
7. Do not publish a false success after failure/cancellation.
8. Never silently substitute requested codec/container/removal mode/destination behavior.
9. Probe and fully verify production media before publication.
10. For SponsorBlock A/V edits, additionally verify the applied timeline duration and explicit audio/video synchronization.
11. For Fast SponsorBlock edits, report actual applied keyframe-aligned ranges rather than pretending the requested boundaries were exact.

## Chapter boundary

`Core/Chapters/ChapterWorkflow.swift` remains the chapter write/verification owner. Part 9 may supply an already transformed collision-resolved `[MediaChapter]` plus expected final duration. It does not create a second native chapter writer.

SponsorBlock/creator chapter transformation occurs in `SponsorBlockExecutionWorkflow`; the resolved list then enters the existing chapter write/split/package paths. This prevents downstream reuse of stale source-timeline chapters after trim/removal.

## Change rules

- Do not regrow `IllucetFFmpegBridge.c` or add an arbitrary command/filtergraph API.
- Extend `IllucetFFmpegBridge.h` only for a genuinely required bounded C operation; do not add C surface merely because a feature edits media.
- Keep probe/verification separate from muxing/encoding/edit algorithms.
- Keep source-timeline/SponsorBlock policy out of generic media processors/editors.
- Maintain staged/reopened verification and no-publication-on-cancel/failure for every new operation.
- Record guarded line counts when a future task meaningfully changes the native C architecture, not for unrelated Swift-only edits.
- Run the smallest relevant native/media production-output suite after a shared processor/edit change; do not claim physical-device behavior from simulator evidence.

## R2 selected-stream packet identity

Checkpoint `6671c709b46dfa52f45f96549b9bbc95db2cb756` preserves every packet belonging to a selected stream during native stream-copy/remux, including AAC priming/discard-timed packets. Demuxer discard timing metadata is left for the muxer to represent; selected payload is not silently dropped. This keeps strict source/output packet-digest identity meaningful without weakening Runtime Proof.


## R4 Fast metadata-republication DTS repair

R4 `3f7ed109b880aada435076ad2fb3070225cc1780` proved the failure was caused by an AAC `KEY | DISCARD` packet with DTS/PTS `-3856` entering metadata-only REMUX after previously written DTS `20480`. A temporary global discard rollback made Fast pass but broke the strict R2 merge proof, confirming the required mode split.

`VDLRemuxSource` now drops discard-timed selected packets before timestamp selection only when the typed request mode is `ILLUCET_STREAM_COPY_REMUX`. `ILLUCET_STREAM_COPY_MERGE` leaves the filter disabled and preserves every selected packet. Complete Part 9 SponsorBlock is 16/16; strict merge remains 155 total / 95 AAC packets with exact AAC packet SHA-256.
