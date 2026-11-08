# Architecture

SwiftUI features → IllucetAppModel → DownloadCoordinator → DownloadPipelineRunner.
The coordinator owns durable job/task state; the runner sequences extraction,
transport, verification, processing and export through typed protocols.

| Area | Owner and contract |
| --- | --- |
| Extraction | RuntimeEnvironment, PythonEngine, YTDLPExtractorEngine, StreamResolver; embedded CPython/yt-dlp and QuickJS return bounded typed JSON. |
| Transfers | StreamDownloadService owns URLSession and delegates. Direct/Range, DASH and HLS acquisition preserve exact selected identity. |
| HLS | Parser/resolver → sequential staging and optional AES-128-CBC decryption → HLSLocalStreamAssembler → job-local publication. |
| DASH | Ordered fragment staging → DASHLocalStreamAssembler → job-local publication. |
| Recovery | FragmentURLRecovery bounds exact-source expiry refresh; FragmentResumeCheckpoint retains verified files and hashed identity/validator facts. Coordinator liveness recovery waits for native acknowledgement and full attempt teardown. |
| Updates | ExtractorPackageCatalog/Installer/Store stage official Python packages; RuntimeEnvironment validates and activates one immutable generation on process launch. |
| Processing | NativeFFmpegMediaProcessor plus dedicated subtitle, chapter, trim and SponsorBlock workflows. Verify actual streams/container and selected output. |
| Export | DownloadPipelineFinalizer prepares complete output sets; DownloadPublicationWorkflow journals destination receipts around ExportManager publication. |
| Background status | Per-window scene eligibility and ContinuedProcessingController own attempt-bound queued CPU/network leases. NativeTransferAcknowledgements fences local snapshot writes for URLSession delivery. Notifications and LiveActivityController observe bounded state. |
| Saved files | SavedOutputResolver maps owned-relative/bookmarked references, validates containment and holds reader/share scopes; StorageManager counts hidden regular payloads and protects recoverable jobs during cleanup. |
| State | IllucetPersistence owns versioned atomic snapshots and rejects stale save revisions; restoration reconciles safe checkpoints, publication receipts and native background tasks. |
| Presentation | App-model composition owns service wiring and observable state; feature views own presentation. Custom floating tabs support iPhone; iPad keeps native adaptive navigation. |

## Invariants

- Python resolves metadata and ephemeral URLs; native URLSession downloads media.
- Never infer exact media identity from URL, filename, MIME or role alone.
- HLS AES supports ordinary manifest-supplied identity AES-128, rotation, explicit
  IVs and media-sequence IVs. Keys remain operation-local. Assembly sees plaintext.
- DRM, SAMPLE-AES, session keys, nonidentity key formats and encrypted byte ranges
  remain unsupported. Keys and signed transport secrets never enter durable state.
- Validate containment, regular-file identity, byte coverage and actual output media
  before publication. Keep cancellation/cleanup and accepted-byte progress truthful.
- State read failures must not silently overwrite saved data with an empty snapshot.
- Transfer and processing work stays bounded and cancellable; iOS background execution
  is best effort and does not imply processing through force quit.

Detailed contracts: [background behavior](BackgroundBehavior.md),
[extraction](YTDLPIntegration.md), [storage/export](StorageAndExports.md),
[batch queues](PlaylistBatchArchitecture.md), [subtitles](SubtitleSidecarArchitecture.md),
[native processing](NativeFFmpegBridgeArchitecture.md), [Python](EmbeddedPython.md)
and [JavaScript](JavaScriptRuntime.md).

Part 13 keeps link intake separate from extraction: `SharedLinkInbox` accepts only
canonical public YouTube webpage URLs in an App Group, and app-model routing
preserves existing drafts and required decisions.
Inbox records retain a presentation date so foreground refresh offers each saved
link once without deleting recovery copies. The action picker can remember a
sharing preference; manual reopening remains available in Saved shared links.
The native Download with Illucet intent and SwiftUI share
`IllucetApplicationServices.model`, including one runtime, coordinator and
persistence writer. Shortcut requests have durable IDs; queue admission is held
until its snapshot is saved, and options preserve that identity. Native requests
are excluded from legacy automatic inbox presentation. A background invocation
returns Started only after native transport owns the job, or a truthful queued
reason. Immediate mode saves required decisions for the next foreground visit;
review modes may open UI without replacing an existing draft.
The Share extension is removed; the older Open shared link intent is retained.
Automatic clipboard reads are opt-in on initial launch and foreground return,
first detect URL patterns without reading content, require an idle draft and respect
Replace existing URL for different supported links,
recheck activation/draft state after detection, and deduplicate unchanged clipboard contents within
the running session. Settings separates these checks from Home preset actions and
shared-link routing. Manual Paste retains its user-initiated behavior. The first-paste
permission tip is local FirstRunState, separate from clipboard consent and portable
preferences; it waits for the Download workspace to be available. Notification
events default off for fresh preferences. A successful explicit authorization request
selects recommended events only if none were chosen; saved event choices survive.
Preference-export timestamps are local snapshot metadata, updated only after a
successful file export and excluded from portable backups.
`LabeledMenuPicker` keeps each control's purpose visible; download source IDs and
encoding controls remain available under Advanced. Keyboard dismissal observes
taps without cancelling control touches, including Settings and preset editors.
`TransferBandwidthLimiter`
paces native range/resource admission and preserves job pause between requests.
The coordinator claims pause before awaiting native controls; its cancellation-aware
pause gate holds subsequent stages. Queued permit requests use job priority with
FIFO ties, and Prioritize changes only future admission. A native Resume waits for
a slot before resuming the task; another Pause or Cancel owns and cancels that wait.
Bulk pause includes queued/environmental waiters, while active processing/export
continues to report its actual state. Download review submission is claimed on the
main actor before async work and consumed after successful enqueue; opening a new
review permits another intentional download of the same source.
Known-size direct sources use bounded ranges when a target rate is requested;
individual responses, ignored ranges and OS-owned background execution can exceed
the target. Charging is a best-effort queue-start condition, never a promise that
iOS will wake the app. `MetadataSidecarWriter` and `HistoryFileRemoval` extend the
existing export/owned-file contracts; local reprocessing uses the native verifier.

Structural media verification seeks to non-keyframe packets near the tail, so
long GOPs cannot consume its inspection budget before reaching the sampled region.
The 320-packet/64 MiB limits and per-stream tail checks remain; representative
decode windows still seek to keyframes and verify decoded frames at their targets.

`SubtitlePickerCatalog` builds a URL-free search index off the main actor; the sheet
renders choices lazily while binding exact track/format selections to configuration.
`DownloadExperiencePreferences` changes presentation routing only. Required validation
and enqueue remain in the app model/coordinator. `AutomaticExtractorUpdatePolicy`
controls foreground check cadence; installation and retained-version restoration
still pass through the package store's next-launch validation boundary.

Analysis exports only selectable WebVTT subtitle sources, retaining their existing
track/format identities and all usable language choices. SRT, embedded and burned-in
outputs still derive from those sources. Python and Swift enforce UTF-8 field bounds
and the complete metadata response remains capped at 8 MiB. A combined audio/video
source is a valid analysis inventory; separate streams are not mandatory.

New download setups use full length and automatic thumbnail selection. Removed trim
and source-image controls retain their stored keys for existing job retry/resume.
Include Thumbnail embeds a JPEG cover in MP4 video after subtitle/chapter/timeline
processing, with the same step for exported chapter splits. Other video containers
reject this choice; legacy separate-image preferences and audio artwork remain distinct.
Native stream copy preserves media, subtitles and chapter markers; output verification
checks artwork, stream identity properties, timing, metadata and chapter equivalence.
Extra files defaults collapsed; chapter help and SponsorBlock Settings help are on demand.
iPhone tab selection uses one custom moving highlight with a fixed 150 ms cubic timing
curve (0.1, 1.35, 0.2, 1), including overshoot and rebound. Horizontal drags move the
highlight directly with the finger and enlarge the previewed icon; release selects
the tab. Releasing outside the bar's tolerance cancels. A scrub ending on the current
tab preserves navigation depth, while a normal Settings reselect tap returns to root.
Page selection does not inherit the animation. Reduce Motion disables animated
movement and extra drag enlargement. iPad retains native adaptive navigation.


SponsorBlock editing groups returned segments by category. Settings/presets define
Off, Remove or Mark as Chapter defaults; a download may override a category, and
individual segments may override that effective category action. Menus pin the
inherited action and omit its duplicate. Existing Keep/Ask encodings remain readable;
Ask migrates to Off, and legacy explicit inclusions/exclusions retain their meaning.
The category/segment changes reuse the existing lookup snapshot, without new API calls.

Storage usage scans run on StorageManager and only the newest requested scan may
publish. Storage uses native pull-to-refresh and automatically scans on entry,
foreground return and cleanup. History file deletion runs off the main actor, uses the selected folder
bookmark when available, and rebases recognized app-sandbox Downloads paths after
container relocation. Failed file deletions retain their History record. Successful
file deletion cleans only that record's inactive temporary job folder and refreshes
usage. Settings can delete all app Downloads (including orphaned files), serialized
with export transactions, plus inactive temporary job folders; active/recoverable
jobs block that bulk operation. Settings, History, Photos and external folders stay.

## PiP

`PipCoordinator` owns the foreground tour, dialogue and companion timing. SwiftUI
anchors measure real controls; the overlay routes through existing Settings pages
and returns to Download on completion or skip. It does not create jobs or alter
download settings. First-run setup alone gates Shortcut admission; replay is
presentation only.

PiP preferences travel in preference backups. The confirmed disable appeal, session
counts, first-download hint and thirty-day hint memory stay in `FirstRunState` in
the local snapshot. Keep/Cancel/dismiss does not consume the appeal; Turn Off does.
Sprites are bundled; animation pauses outside the active scene and respects Reduce
Motion. Companion events observe durable job-state transitions, never byte updates.

PiP's first-download suggestion uses the current screen-skipping settings and is
consumed silently when both are already on. Activity has two choices with stable
backup values; legacy Never decodes as disabled. The page owns its cancellable
highlight timer and fades into a stable row background. Guide exit has a separate
task and a stable root cover; it routes/scrolls while covered and then reveals
Download without further input. Attention derives from target geometry, using
up/down gaze sprites or side-pointing poses.

## Manual transfer admission and selection

`TransferAdmissionPolicy` counts jobs across extraction/preparation and all transfer
stages. Foreground manual starts/resumes/retries consult the coordinator and offer
Queue, Start anyway or Cancel when the normal limit is reached. An approved exception
belongs to that job and the transfer permit pool; processing permits and the saved
limit stay independent. Background intents retain normal queue admission.

Queue and History own independent in-memory inline selection state on the app model.
Only eligible terminal rows can enter selection; filtering or job changes prune
stale IDs. Queue deletion dismisses terminal work without removing media/History;
History reuses the existing contained file-deletion flow with records-only or
files-and-records choices. Each page supplies its own action bar above the tab bar.
