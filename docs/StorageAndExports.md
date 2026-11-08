# Storage and Exports

Current implementation uses durable per-destination publication receipts. Earlier Part 9A evidence below is historical; current release-fix verification is recorded in [development guide](Development.md).

## Export recovery

A verified job-local plan is retained before publication. Illucet atomically saves each destination's committing intent, then its result, before starting another destination or removing prepared inputs. Retry resumes export from that plan and skips committed destinations, including an existing Files copy when Photos failed. Input digests and containment are revalidated; no transport URL or account credential enters the plan.

An interrupted committing receipt has an unknown outcome and does not automatically repeat the save. History asks the user to check existing copies. Photos and local snapshots cannot form one atomic transaction. Completed legacy records remain terminal; a deliberate new download is a separate request.

Snapshot envelope 10 retains publication state, monotonic write revisions, batch controls, background-time waits, bounded transfer-recovery counts and native staging receipts, and reads versions 1–9. It adds optional owned-relative and bookmarked external output references to jobs and History. Receipts contain local file identity/task/format/byte-count facts only; they do not authorize source reuse. Older queued snapshots cannot erase newer acknowledged results. Photos receives the sanitized requested basename plus the actual extension through PHAssetResourceCreationOptions.originalFilename. Share dismissal without a UIKit answer is unconfirmed; a definite callback settles the outcome, and staging cleanup waits for the History save acknowledgement.

Offline failure/restart and UI verification is recorded in fix plan 1. Actual Photos metadata, Files share-provider behavior and physical locked-device completion remain separate acceptance gates.

## Saved output access

`SavedOutputResolver` supplies the same contained paths for preview/playback,
sharing and deletion. Current Downloads references store the full relative path.
Legacy physical/simulator sandbox URLs rebase only from recognized
Documents/Downloads roots; no basename search or symlink traversal is permitted.
Original absolute URL fields remain backward-readable. Current transient/share
staging stays available without making arbitrary old paths eligible for migration.

Each external record retains its export plan's folder bookmark and contained
relative paths. A later default-folder change does not replace that authority.
One access session holds the folder grant for its files; coordinated image reads
and deletion use it, and AVPlayer/UIKit consumers retain it for their full lifetime.
Stale/denied access offers **Choose saved folder**. Reauthorization accepts the
original folder, preserves relative identity and leaves the default destination
unchanged. Unknown legacy locations cannot be redirected by matching a basename.
Missing files and lost authorization have distinct messages; failed deletion keeps
the record for recovery. Photos library items are not deleted.

Storage counts logical sizes of owned regular files, including hidden range parts
and package contents, without following links. Active/recoverable/quarantined job
cleanup protection is retained. Publication acknowledgements and History updates
request a refresh; Settings entry also measures usage. Newer scan generations win,
and an unmeasured/updating root summary says Calculating/Updating instead of zero.
The independent OS capacity query still drives preflight.

Storage shows Documents, temporary files and free space without expandable inventories.
**Delete Illucet files** explicitly removes Downloads and other files in the app's
Documents directory, including files without History records; settings and History
in Application Support, Photos and external folders remain. Temporary cleanup
protects active/recoverable job roots and an open diagnostics share and reports
partial failures. Manual cleanup also recognizes CFNetwork download files and
UUID-staged preferences exports older than 24 hours, only with no recoverable jobs.
Unknown temporary content is preserved. Automatic job cleanup stays job-scoped.

A filename/size-only iPhone inventory on 2026-11-05 identified the reported 1 MB as
five old Documents/Audit-Invalid-Preferences test fixtures, including the
1,048,640-byte oversized fixture. The approximately 41 KB temporary remainder
included a 32 KB CFNetwork download file and an 8 KB exported preferences file.
The updated manual actions cover those leftovers. Recently created/in-use temporary
content can remain or be recreated by iOS; cleanup does not reset the app.


Simulator proof covers containment, lifetime, migration and local UI only. Actual
Files-provider authorization, reauthorization and reinstall behavior remain in the
[development guide](Development.md).
Apple's [directory access guidance](https://developer.apple.com/documentation/uikit/providing-access-to-directories)
describes the bookmark, security-scope and file-coordination contract.

## Storage and publication boundary

Illucet stages media under app-controlled temporary storage, verifies the selected output contract, and publishes only finalized output through the appropriate Illucet/Files/Photos/Share owner. Complete media is not intentionally buffered in RAM.

Safe publication remains transactional where required. Partial/native outputs are never deliberately exposed as final merely because processing produced bytes.

Owned job payloads and app-owned export targets use after-first-unlock protection,
reapplied after native moves/atomic replacement. External-provider protection and
unrelated private/account files remain unchanged. Native staging acknowledgement
awaits the durable snapshot writer; write failure retains verified inputs and
prevents publication. A quarantined transfer keeps its files until native cleanup
is acknowledged. Simulator tests cover the protection request and containment;
actual access under device lock remains a separate gate.

Subtitles Only remains an early media-free route that bypasses media resolution/download/FFmpeg, validates exact VTT/SRT output, publishes the complete subtitle set, records the real files as owned output, and cleans prepared temporary inputs.

## Current verification/publication behavior

Reviewed C3A implementation uses:

- `fastStructural` verification for ordinary downloaded sources and no-reencode outputs;
- `boundedStrong` structural/tail plus representative decoded-window verification for material rewrites;
- explicit `strongFullDecode` only for developer/runtime-proof/test/diagnostic use.

Reliable exact transferred-byte mismatches fail before processing where the expectation is trustworthy, and verified processing results are reused instead of redundant equivalent probing.

Atomic publication still requires the verification class/evidence required by the actual operation to pass. The cost policy does not weaken applicable container/extension/stream/codec/duration/requested-property/truncation/metadata truth.

C3B/C3B-R1 did not weaken this policy while repairing AVFoundation metadata, subtitle burn-in, SponsorBlock planning, or direct-transfer behavior.

## Files destination — alias/access physically confirmed

The system folder picker plus security-scoped bookmark/access design remains the Files contract.

Implemented access behavior includes:

- presentation-owned folder picking;
- real writable/security-scope bookmark validation;
- stale/unavailable access invalidation/reselection;
- `Test Folder Access` success only after a real write/remove probe;
- Files + Photos preservation rather than silent downgrade.

User-installed smoke confirms normal V+A Files output works. Earlier smoke also confirms Files + Photos can publish to both destinations.

Physical testing clarified that a provider location can legitimately resolve to `Documents`. C3B Checkpoint A `d7a948b24a46dc3919792ef3271d9feeb9404170` separates actual selected-folder identity from presentation alias:

- the real resolved name is retained initially;
- when the resolved name is `Documents`, the UI may offer a custom user-visible alias such as `VLC`;
- declining keeps `Documents`;
- later edit/rename is presentation-only;
- the alias persists across relaunch, `Test Folder Access`, startup validation, bookmark refresh and ordinary access checks;
- a genuinely different folder selection resets the old alias;
- alias changes never alter bookmark identity, security scope, writable-access truth, actual path, destination or export behavior.

Fresh user-installed C3B smoke confirmed the key real-provider path: selection initially displayed `Documents`, Illucet offered the alias, choosing `VLC` changed presentation to `VLC`, and `Test Folder Access` correctly reported the VLC folder writable. The full alias lifecycle remains covered deterministically and remains accepted after Part 9A closure.

## Metadata through accurate AVFoundation publication — implementation reviewed

C3B Checkpoint B `80de1371412b3f5693e5a691713e64b43f18a1da` repairs the accurate AVFoundation range-edit metadata publication seam. When the selected preservation policy requires title, artist/channel, comment/source, date, description, or other applicable metadata, the edited output must actually carry those values and strict verification remains enabled.

MOV-family description compatibility is narrowly canonicalized at the format-global MOV-family probe boundary rather than accepted from unrelated stream/arbitrary-demuxer metadata.

C3B Checkpoint C reuses the same typed metadata publisher for subtitle burn-in.

Later R8/R9 physical evidence closes the live subtitle/burn-in and Accurate SponsorBlock publication/metadata paths at their documented boundaries.

## Photos destination

Normal Photos-including media output must pass the executable compatibility contract. Valid incompatible media is not silently converted or relabeled corrupt.

User-installed C3A smoke confirms normal V+A Photos export and Thumbnail→Photos publication. Earlier smoke also confirms explicit incompatible-output warning, warning removal after changing to Files, and Files + Photos publication. Final Part 9A user observation additionally confirms the compatible retained R9 output saved to Photos and played normally there. Illucet gave no immediate success feedback after that successful save; this USER-OBSERVED FAIL is explicitly deferred. A deliberate transition/reopen retention check remains NOT RUN/deferred.

Formal Photos permission/import/provider validation remains Part 14. Subtitles Only rejects Photos/Files + Photos.

## Final-review destination selection

P9A.5 makes `Change` directly present destination selection and required Files picking. User-installed smoke confirms the flow works and the selected destination propagates back.

## Share and History lifecycle

Main-app share output remains staged until the system share sheet completes/cancels/fails, with truthful History lifecycle and cleanup.

History's built-in media preview has C3B playback-audio-session ownership. Fresh physical smoke confirms completed V+A remains audible with Ring/Silent enabled. That playback policy does not change stored output, export ownership, or verification result.

History mature Open/Reveal/Photos/share/copy/delete behavior remains P13.13. P13.14 remains History bulk management. P13.15/P13.16 later own Queue bulk management and Queue retained-output Open/Reveal/destination actions.

## Complete-set transactions and collisions

Existing chapter-split/Subtitles Only complete-set transactions keep all-or-nothing staging/verification/commit/rollback semantics.

Duplicate policies remain Ask/Skip/Overwrite/Add Number/Add Video ID with serialized user decisions. Verification-cost changes do not change publication/collision ownership.

## Thumbnail Only

Thumbnail Only remains independent of media format resolution/download/FFmpeg. User-installed C3A smoke confirms Thumbnail→Photos works without recurrence of the earlier thumbnail decode failure.

## Evidence boundary

Part 9A is closed. P9A.16 transport, P9A.17 decomposition, subtitle/burn-in, SponsorBlock metadata/efficiency, Files, and compatible Photos save/playback have reached their documented final dispositions. The only retained P9A export/UI boundaries are the user-deferred silent Photos-success feedback FAIL and deliberate retention/reopen NOT RUN.

## Part 13 retained outputs

Optional metadata JSON, description, source URL, NFO and SHA-256 sidecars accompany
media exports to Illucet or a Files folder. They share the existing file transaction
with the primary output and chapter splits. JSON uses an explicit metadata allowlist;
the URL is the canonical public webpage, and the checksum hashes actual finalized
media bytes. Signed media URLs, cookies and headers are excluded. Packages, Photos,
Share-only and media-free output combinations reject these extras explicitly.
Separate thumbnails and sidecars are recorded as owned files for later sharing and
deletion. Record-only History removal keeps files; explicit file removal attempts all
selected owned outputs and retains records with partial failures. It never deletes
Photos assets. Queue removal affects terminal entries and keeps their output files.

Output details can preview retained files, make a compatible Photos copy, redownload,
or convert a retained audio track locally to MP3, AAC/M4A or FLAC. Conversion runs in
the foreground through the native processor/verifier and transactional exporter,
creates a new History record and keeps the original unchanged.
