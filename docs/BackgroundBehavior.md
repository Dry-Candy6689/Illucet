# Background behavior

Native background URLSession owns actual media downloads. Python resolves metadata
and exact ephemeral transport identity; it never owns durable network-transfer tasks.
DownloadCoordinator owns user-visible jobs, permits, retries and restoration.

Immediate anonymous direct downloads can reuse the picker extraction for up to
60 seconds. Python keeps at most four results / 16 MiB of serialized data in
memory. An opaque, one-use token ties the selected direct streams to that analysis;
it is omitted from encoded evidence and never enters a persisted job. Missing,
expired, consumed or mismatched tokens fall back to fresh extraction. Explicit
analysis and retry resolution invalidate older results. Runtime shutdown clears
the handoff, and account requests bypass and clear it. Signed URLs stay in memory.
Fresh preparation also hands its extraction to the direct resolver, eliminating
the second fetch when the picker result is unavailable. Manifest resolution keeps
its existing path, and exact identity/output checks still run.

HTTPS requests to the Google video CDN carry an HTTP/3 capability hint, including
redirects. URLSession retains TCP fallback and background-session ownership. This
hint changes connection discovery only; it does not select or validate media.
Other hosts keep normal protocol negotiation. See
[Apple's HTTP/3 guidance](https://developer.apple.com/documentation/technotes/tn3102-http3-in-your-app).

Transfer speed uses cumulative accepted byte deltas sampled over at least one
second, with time-based smoothing and three samples before estimating remaining
time. Resume resets the estimator. Unknown totals keep ETA unknown. Queue metrics
use separate, stable rows and rounded estimates to avoid layout shifts as values
change. Queue cards, job details, playlist child rows and Live Activities use the
same current-stage fraction: all selected media bytes run from 0 to 100%, then each
measured processing operation uses its own range. A stage with no trustworthy
measurement remains indeterminate. The weighted whole-job estimate is retained only
for aggregate/system continuation bookkeeping. Foreground entry reads authoritative
coordinator snapshots; delayed UI events cannot roll back a newer snapshot.

## Direct HTTP and Range

Direct failure classification preserves HTTP truth: 401 is permanent, 403/410 use
bounded exact re-resolution where supported, 429/5xx are transient. Range is not a
workaround for rejected requests. Range plans require trustworthy exact lengths and
validated chunk guidance, use at most 128 tasks per source, and verify response
coverage/length before accepting bytes. One request first confirms Range support;
remaining requests are handed to the existing background session as a batch.
Foreground speed limits retain paced single requests, with batch admission after
background handoff. Per-range cumulative observations support out-of-order completion,
and restoration counts each source's verified baseline and total once. Completed verified ranges can be reused;
unfinished bytes are discarded. Existing one-GET task descriptors remain attachable.

Descriptors contain stable identity and safe destination facts. They exclude signed
URLs and secrets. Reconstructed tasks are reconciled before work resumes. Pause,
resume and cancel await terminal acknowledgement where required; a cancelled caller
must not incorrectly complete another caller's waiter. The existing descriptor
array is durably written before a batch starts; no snapshot-schema change is needed.
A bounded native request submission does not require a CPU-processing grant.
Range assembly, extraction and fragmented-media work keep their execution gates.
Restoration preserves eligible native transfers; user-paused, unrecognized and
policy-gated jobs remain suspended.

Native receipts arriving before startup are held until the saved jobs and durable
writer are ready, or fail explicitly if startup is blocked. Optional account/folder
and updater work follows transfer restoration. Unconsumed acknowledgement failures
cannot be evicted by the completion-cache limit.

A public Video + Audio download to Illucet completed while backgrounded through
Home in iPhone Mirroring on iPhone 16 Pro / iOS 27.2 on 2026-11-05. Saved output,
pre-reopen completion diagnostics and subsequent player advancement were verified.
This is direct-transfer/app-switch evidence; independent physical lock, force quit,
fragmented media and provider variants remain separate checks. See the
[development guide](Development.md).

## Fragmented media

DASH acquisition stages ordered exact fragments with bounded eligible retries and
verified local assembly. HLS acquisition preserves resource ordering, initialization,
discontinuities and accepted ranges. The HLS lifecycle registry is separate from
the direct/Range registry but shares the service's URLSession delegate owner.

Ordinary HLS AES-128 decryption happens during acquisition. Keys/IVs remain in
operation memory, ciphertext is never published as accepted media, and assembly
receives verified plaintext. Restored HLS operations lacking their ephemeral plan
are cancelled and cleaned. A fresh unencrypted plan may reuse completed fragments
whose exact URL/plan, fresh strong ETag and local digest all match. Incomplete bytes
are discarded. Changed URLs, missing validators or encrypted HLS restart safely.
Raw URLs, ETags and encryption keys are not stored in the fragment checkpoint.

Typed 403/410 failures re-resolve the original exact selected source, at most twice
per source across automatic retries/relaunch. Explicit Retry starts a new budget.
Paused jobs remain paused after restoration; Resume obtains a fresh plan. Success,
cancellation and terminal-job removal clean fragment caches; recoverable network
interruptions retain verified fragments. Completed replays use bounded plans; ongoing
live recording is deferred. Broader key-continuity resume remains future work.
Device background behavior still needs separate physical evidence.

## Continued processing on iOS 26+

Each window reports foreground-scene identity. Active and temporarily inactive
scenes (including Control Center) permit execution; only background/disconnection
revokes it. Revision checks reject reordered scene callbacks. A deferred job retries
at most once per activation, after the old attempt and its lease finish teardown.

Foreground-started jobs register and submit the same concrete
BGContinuedProcessingTask identifier, covered by the plist's permitted wildcard,
with `.queue`. Submission runs off the main actor; iOS 27 uses the asynchronous
API to capture scheduler failures. Only bounded system error kind/code are logged.
The attempt-local lease records requesting, queued, granted, denied, expired and
finished states with safe reasons and timestamps. A delayed grant wakes the same
runner; waiting releases its processing permit and remains cancellable. Denial
does not resubmit in a loop. Pause/cancel closes the lease; stale grants/expiration
callbacks cannot affect its replacement. Leases are never restored from disk.

Checkpoints retain the verified base assembly separately from later edits.
Recovery checks exact selected sources, job-local containment and media identity
before reuse; it restarts timeline edits from the base rather than editing an
already edited output. Cancellation during a source probe does not invalidate or
delete that source. Fresh assembly/edit paths avoid colliding with an interrupted
uncheckpointed output. Older checkpoints remain readable and can rebuild safely.

Extraction, fragment acquisition/decryption/assembly, probing, processing and export
require foreground execution, the matching live grant or the admitted Intent window.
A daemon-owned public task continues independently. Expiry stops only matching
in-process work and retains verified checkpoints. The lease remains open through
publication acknowledgement and authoritative terminal-state commit. CPU/network
admission does not establish background GPU/VideoToolbox support; no GPU entitlement
was added, and hardware-only policy remains explicit.

Normal downloads validate file/stream identity and decoded audio/video samples;
they do not try to play video in an invisible AVPlayer. Actual player advancement
remains part of developer Runtime Proof. Legacy playback-wait checkpoints can reuse
the retained output after the same containment, identity and decode checks.

A typed foreground-resume reason distinguishes a system-time wait from manual
Pause, Cancel and real failures. Opening the app or tapping the notification resumes
eligible work once through the existing queue. Cancel publishes its state before
awaiting native cleanup. Late progress carries an attempt identity and cannot revive
cancelled or superseded work. Progress emissions are capped at five per second,
while stage boundaries and final stage percentages remain immediate.

Leaving the foreground disables app-timer pacing and releases only limiter-owned
task suspension. User pause stays in effect. Foreground return resets pacing debt
and byte baselines, so background bytes do not become a new artificial delay.

An independent foreground monitor reconciles native task counters. After 90 eligible
seconds without activity it cancels the stalled attempt and waits for both native
acknowledgement and pipeline teardown before replacing it. Pause, offline,
background and deliberate pacing time do not count. Two automatic recoveries are
allowed; explicit Retry resets the budget. Unacknowledged cancellation keeps the
attempt, its transfer slot and files quarantined, with Retry unavailable. A late
acknowledgement after the 15-second cleanup deadline permits manual recovery only.
Completed exact sources and verified ranges remain subject to existing validation.

Owned media/staging/output files explicitly use after-first-unlock protection,
including after moves and atomic replacement. External providers and unrelated
account files keep their policy. Native delegate completions journal bounded local
staging receipts and await the snapshot write before returning the file. Receipts
contain no transport secrets and never authorize media reuse. Background URLSession
event completion waits for writes already enqueued for that delivery cycle, once;
it does not wait for a CPU grant or future network requests.

## Notifications and Live Activities

Preferences cover completed downloads, verified processing completion before export,
failures, attention/cellular approval, low storage, exhausted transient retries,
playlist/package completion and available extractor updates. Restored history is not
replayed as new transition notifications. Messages omit raw errors and transport
secrets. ZIP playlist completion waits for the package result. OS notification
permission is still required.

The embedded WidgetKit extension prioritizes running jobs over older paused/waiting jobs. ActivityKit
updates show stage-specific progress, transfer speed and transfer or processing ETA;
missing measurements stay unknown. Progress updates are limited to once per second,
with stage changes immediate. Running content requests a 30-second stale date; stopped jobs have static status;
when iOS marks it stale, the extension hides measurements and asks the user to reopen
Illucet. Since iOS can delay that visual refresh, the stale expanded/Lock Screen display also
shows a fixed last-update time. Fresh activities omit the resetting measurement-age
ticker; it was not elapsed download time. Compact content shows Open, Paused, Wait
or Failed with distinct symbols; an unmeasured transfer shows an ellipsis. Failure
stays in the Island for up to a minute while execution remains available, then its
final state stays briefly on the Lock Screen. Disabling activities or removing the
job ends its activity. Notification delivery runs independently of status updates.
Creation requires foreground execution or a LiveActivityIntent and permission from
iOS. Background Shortcut admission attempts an activity and falls back to a local
notification when allowed. Denial never prevents a download.

“Open controls” and Dynamic Island taps open the job in Illucet. Pause is available
only for supported transfer stages; cancel uses the existing confirmation. There are
no direct background widget pause/cancel actions. Activity attributes contain only a
bounded title, job UUID and display measurements, not transport/account credentials.

## Limits and evidence

Background network transfer is distinct from CPU/media processing. iOS may suspend
or expire work; there is no guarantee of processing through lock, suspension or
force quit. Preserve safe checkpoints and truthful state transitions. Device tests
must cover lock/background, interruption, relaunch and storage pressure separately
from simulator and offline fixtures. See [Development](Development.md) and
[development guide](Development.md) for current commands and evidence.
The D4 implementation and offline evidence are recorded in
[development guide](Development.md).
Simulator checks verify protection requests and owned-path containment; its
filesystem does not expose protection metadata or prove encrypted access under lock.
Actual locked-device media completion remains **NOT RUN** until separately tested.

## Shortcut startup

Download with Illucet uses the shared native runtime and queue. Immediate-download
mode never requests foreground continuation. On iOS 26 an 18-second preparation
budget leaves the public link durably saved if native transfer ownership is not yet
established. On iOS 27 LongRunningIntent is requested before cold startup and covers
preparation and the actual job until completion or a genuine waiting state.
System progress uses a labeled percent for a measured stage and indeterminate
preparation, rather than 1,000 synthetic units. Intent transitions also synchronize
ActivityKit directly, including after its execution grant is released. Failure is
reported as failure, not successful queue admission.
Required choices are saved and notified; explicit review behaviors may open UI.

An interrupted preparation can continue once on the next foreground activation.
After admission, queue controls own the job independently of the Shortcuts overlay.
Losing the intent window releases its execution grant and safely defers CPU work
if no other grant exists. Transfer work already handed to URLSession remains native.
No path promises uninterrupted work after force quit or bypasses iOS scheduling.

Apple references: [background downloads](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background),
[continued processing](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados),
[LongRunningIntent](https://developer.apple.com/documentation/appintents/longrunningintent),
and [Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).
Physical lock-screen and scheduling evidence remains separate from Simulator tests.
