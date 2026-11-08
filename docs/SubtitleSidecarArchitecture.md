# Subtitle Sidecar Architecture

Status: **Part 8 subtitle sidecars, embedding, burn-in, and Subtitles Only remain implemented; R5-R7 are accepted; current exact production Mac/phone burn parity passes with unchanged duration policy; final hands-on physical output evidence remains.**

## Ownership

| Owner | Responsibility |
| --- | --- |
| `SubtitleSelectionPlanner` | Exact language/manual-or-automatic/track/format matching and delivery planning |
| `SecureSubtitleTransport` | HTTPS URL validation, public DNS policy, redirect handling, answer stability, bounded response and expired/unusable-response classification |
| `IllucetHostResolver` | Bounded `getaddrinfo` conversion to numeric IPv4/IPv6 answers; no request or URL ownership |
| `WebVTTProcessor` | Bounded UTF-8 WebVTT classification, validation, normalization, cue parsing, and SRT rendering |
| `SubtitleFilenamePlanner` | Media-sidecar basename alignment plus standalone Subtitles Only title/language/origin/exact-track naming, normalization collision handling, and length bounds |
| `SubtitleSidecarWorkflow` | Exact bounded refresh, preparation partials, validation/hand-off, and cleanup |
| `SubtitleEmbeddingWorkflow` | Container-compatible text-codec requests, exact selected-track identity, and reopened stream verification |
| `SubtitleBurnInWorkflow` | Bounded cue preparation, full-conversion routing, output verification, and cancellation |
| `SubtitleBurnInRenderer` | In-process WebVTT cue compositing into SDR H.264/HEVC MP4/MOV frames with audio and required metadata preservation |
| `ExportManager` | Atomic file-set publication, sidecar publication, and truthful Share staging |
| `DownloadExportFlow` | Serialized duplicate decisions and Subtitles Only complete-set export orchestration |
| `DownloadPipelineRunner` | Narrow planner/workflow invocation inside one durable pipeline, including the early Subtitles Only branch |

`IllucetAppModel` and `DownloadCoordinator` do not own subtitle parsing, naming, muxing, rendering, or file-set publication algorithms. The coordinator may own durable pipeline/retry orchestration where the exact subtitle refresh path must integrate with job lifecycle. The native FFmpeg façade remains bounded; Subtitles Only never invokes it.

## Data and secret boundary

`MediaSubtitleFormat.url` is ephemeral in-memory transport data. `SubtitleTrackSelection` carries non-secret exact track/format identity, language, and manual/automatic identity. Jobs, history, presets, diagnostics, errors, UI, and filenames never store or render the remote subtitle URL.

A refreshed URL follows the same rule.

C3B preserves exact identity across refresh:

- expected video ID;
- language;
- manual/automatic origin;
- exact track identity;
- subtitle format identity.

There is no silent substitution to another language, track, origin, or format.

## Transport policy

Before each request and after its response, the transport resolves the host through an injectable resolver. Empty, mixed public/prohibited, private, loopback, link-local, reserved, multicast, unspecified, documentation, and IPv4-mapped IPv6 answers fail closed. The answer must continue to intersect the host's initial public answer set during the attempt. Every redirect repeats URL and DNS validation; downgrade, credentialed URLs, redirect loops, and more than four redirects fail.

The native resolver traverses the complete `addrinfo` answer chain and fails closed when its bounded answer/output capacity cannot represent the complete safe result.

The live client uses an ephemeral URLSession with cookies, credential storage, and URL cache disabled; request/resource timeouts are bounded. Normal system TLS verification remains enabled. Responses are streamed only up to the configured **2 MiB** subtitle bound and cancel promptly.

Foundation does not expose the actual connected peer address to this layer. The implementation therefore does not claim cryptographic peer-IP pinning. Resolver checks before/after each request, redirect revalidation, initial-answer stability, and system TLS remain the documented platform boundary.

## Bounded live-response classification — C3B implemented

Fresh pre-C3B physical testing on the user's iPhone and a separate iPad without MDM produced:

`The subtitle response was not valid bounded WebVTT.`

C3B Checkpoint C `128c52664e822f2d3422884e7b99433c5679d06e` adds secret-free classification sufficient to distinguish:

- empty body;
- HTML/error-page body;
- JSON-like body;
- XML/markup/non-VTT body;
- other non-WebVTT body;
- a body that presents as WebVTT but is rejected by the bounded parser;
- expired exact subtitle transport.

Classification records only bounded non-secret reason/status facts. It never logs subtitle text, signed URLs/query strings, tokens, cookies, credentials, Authorization, or secret headers.

Nominal HTTP 2xx no longer automatically means a usable subtitle body.

## One bounded exact refresh — C3B implemented

The transport and parsing preparation path share one structurally clamped refresh budget. At most one reanalysis/re-resolution refresh can occur for a preparation attempt.

Refresh requires the same original source/video identity and exact selected subtitle identity. A second unusable response fails; there is no loop.

Existing explicit-expiry HTTP outcomes and newly classified nominally-successful unusable responses enter the same bounded owner rather than creating independent retry loops.

No evidence from C3B required broadening the WebVTT grammar permissively. The established current YouTube WebVTT shape is covered deterministically; malformed HTML/JSON/XML/other non-VTT remains fail-closed.

## Validation and media-sidecar publication

Downloaded bytes must be non-empty bounded UTF-8 WebVTT, independent of file extension or Content-Type. HTML/JSON/error bodies, binary/control data, malformed blocks or timestamps, excessive lines/cues/payload/output, and metadata-only files fail.

Valid VTT is line-ending normalized; SRT conversion handles BOM, headers, cue identifiers/settings, short and long timestamps, multiline cues, and NOTE/STYLE/REGION blocks without executing content.

Prepared output is written to a unique partial and renamed only after validation. Media-sidecar names use the actual exported media basename plus sanitized language and `manual`/`auto`; a non-secret identity suffix separates canonical Unicode or otherwise equivalent collisions. Existing sidecars are never silently overwritten.

Once preparation returns files, the pipeline owns unconditional cleanup for prepared temporary inputs after success, failure, cancellation, duplicate skip/cancel, and export failure without deleting published outputs or unrelated work.

Illucet Documents and Files keep media sidecars beside media. Files + Photos retains them with the Files copy. Share stages media plus sidecars as truthful items. Photos-only is rejected before queueing.

## Subtitles Only — implemented P8.15 boundary

Subtitles Only reuses the exact selection/transport/validation architecture instead of creating a second downloader/parser.

The path branches before media stream resolution, media download, media probing/playback verification, or FFmpeg. It reanalyzes the same video identity, matches the exact selected subtitle tracks, securely prepares VTT/SRT files, transactionally publishes the complete set to eligible destinations, records the real subtitle outputs, and performs normal cleanup/history lifecycle.

Eligible destinations are Illucet Documents, selected Files folder, and Share. Photos and Files + Photos remain intentionally unavailable for subtitle-file-only output.

Duplicate Ask/Skip/Overwrite/Add Number/Add Video ID behavior remains complete-set transactional for Illucet/Files. Share stages the complete selected VTT/SRT set into one pending share request.

## Embedding and burn-in

Embedding consumes the same exact securely prepared selections. Container-specific subtitle codecs and reopened output verification remain required.

Burn In parses normalized WebVTT cues, removes markup, decodes bounded entities, and composites actual text pixels in process. It accepts at most four selected tracks and supports the verified SDR H.264/HEVC MP4/MOV path. It is a full video re-encode with explicit UI warning and preserves audio.

R5 `a02c0e6ac924d54d096610042b19ddcb1980e028` reproduced the failure on iOS 26.5 and assigned it to `AVAssetExportSession`: date survived while title, artist, comment, and description were dropped despite the renderer receiving all five exact values. Burn-in now renders pixels to a private intermediate without claiming final metadata, then the existing typed native metadata-only remux republishes the canonical `ConversionMetadataPolicy` values into the staged output before strict verification. The intermediate remains under cancellation/failure cleanup.

The deterministic burn-in gate still decodes completed frames before/during/after a controlled cue and requires a localized subtitle-region pixel change. Successful encoding or stream metadata alone cannot satisfy this proof.

The general production publication gate remains `boundedStrong`; the specialized real pixel proof is distinct additional evidence.

## R6 live `en-orig` duration-boundary repair

R6 `841accd4990f9043174922d37722607a48cb8dac` reproduced the exact authorized live path and proved transport, WebVTT normalization, and all 541 rendered cues were valid. The only rejection was the burn duration guard: terminal cue `561.040-564.720s` versus verified exact-media end `563.362540s`.

The workflow now receives the already-verified probe for the exact burn input. Verified duration is used only when it identifies the same unedited extraction timeline within 0.5s. A cue beginning within media may be clipped only when its terminal overrun is <=1.5s; wholly post-media or larger overruns remain fail-closed. Materially edited timelines keep the prior extracted-timeline behavior.

Exact identity, one-refresh budget, SSRF/DNS/HTTPS/redirect/credential/cache/timeout/size bounds, R5 metadata publication, and real pixel proof remain unchanged.

## R7 production/device parity result

R7 `bb6e3ee49f43cd6ec6dea87e79fa06164521f1ac` exercised the freshly produced full production merged `MediaProbeResult` on Mac and a fresh iPhone. Both independently reported container `563.29288s`, video `563.233333s`, audio `563.29288s`, extracted `563.0s`, 541 cues and terminal `561.04-564.72s`; the decision was `verified_duration / clipped_to_verified_end`, and the phone job completed.

R7 added secret-free structural duration route/outcome diagnostics but did not widen parser grammar, transport security, the 0.5s timeline identity bound or the 1.5s terminal overlap bound. The historical R6 device failure is currently nonreproducible and is not assigned retroactively.

Hands-on visible-pixel/playback/audio/metadata evidence remains for the final physical packet.

## Current evidence boundary

Historical P8.15 simulator evidence remains correct and unchanged.

C3B Checkpoint C Codex-reported focused evidence:

- subtitle-sidecar suite: **70 executions PASS**;
- related media suite including the real burn chain: **57 executions PASS**;
- Subtitles Only suite: **8 PASS**;
- coordinator: **20 PASS / 1 authorized-live SKIP**;
- settled C3B-C total: **155 PASS / 0 FAIL / 1 SKIP**;
- verifier tests: **16/16 PASS**;
- real repository verifier: **PASS**;
- unsigned arm64 Debug build: **PASS**.

Required deterministic chain passed:

`selected VTT -> secure transport -> bounded classification/parse -> at most one exact refresh -> rendered cues -> burn-in -> real pixel proof -> boundedStrong output verification`.

The previous review independently reviewed the implementation diff and approved C3B with no R1. It did not independently rerun the Mac/Xcode commands.

Current exact production burn completion is now physically demonstrated by R7. Separate hands-on visible subtitle, playback/audio and metadata observation remains required in R8; deterministic R5 metadata and rendered-pixel gates remain green.
