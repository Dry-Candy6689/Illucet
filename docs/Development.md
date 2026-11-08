# Development

Use Xcode 27 through a command-local `DEVELOPER_DIR`, and generate project changes
from `project.yml` with `xcodegen generate`. Preserve the iOS 26 deployment floor.

## Fast checks

```sh
Scripts/verify.sh static
```

This checks documentation links, generated dependency expectations, Python-package
integrity and Python unit tests. Native frameworks are restored separately as
explained in [BuildFromScratch](BuildFromScratch.md).

## Simulator regression

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ILLUCET_SIMULATOR_ID=<simulator-uuid> Scripts/verify.sh simulator
```

Only the unit target runs. Authorized live-download and live-updater methods are
explicitly excluded. Results are stored outside source files; a run with zero executed tests
is not evidence of success. Use iPhone/iPad on installed iOS 26 and 27 runtimes.
UI tests run separately with the IllucetUITests target and deterministic fixtures.
`PipUITests` covers the guide, repeat-until-confirmed disable appeal and PiP's
first-download shortcut hint, redundant-hint suppression, visible highlight fade,
activity-choice migration, target-relative gaze and one-tap final-message exit. `RefinementUITests` covers independent inline
Queue/History selection, mixed video/audio transfer admission, one-line SponsorBlock
labels/popovers, direct Shortcut import and Storage separator feedback. These tests
use isolated Debug fixtures; `PhysicalRefinementUITests` instead requires explicit
`ILLUCET_PHYSICAL_SMOKE=1` and uses the existing installation without resetting it.
`-only-testing:IllucetUITests/UsabilityCleanupUITests` covers the four download-flow
combinations, immediate clipboard Quick Start, a 5,000-entry subtitle picker and
version-copy feedback, Settings tab reselection at multiple navigation depths, and
preference backup controls in light/dark appearance. The download-cleanup tests also
cover below-bar tab holds, Storage pull-to-refresh and cleanup feedback after idle, non-media
SponsorBlock bypass, History/Queue actions and retained-URL configuration. `PreferencesBackupTests` covers
portable backup validation and import without replacing media/history/account state.
`--ui-polish-reset` resets only the Debug fixture settings;
its optional `--ui-skip-details`, `--ui-skip-review`, `--ui-instant-quick-start` and
`--ui-screen=configuration-large-subtitles` arguments are for isolated UI tests.
Use the same project, scheme, destination and signing arguments as the simulator
command above, with a separate result bundle. Inspect screenshots as well as assertions.

Launch fixtures (`--ui-testing`, its unit-test override, and `--stage0-autorun`)
are Debug-only. When changing launch routing, also run `LaunchConfigurationTests`
with `xcodebuild test -configuration Release
-only-testing:IllucetTests/LaunchConfigurationTests ENABLE_TESTABILITY=YES
ONLY_ACTIVE_ARCH=YES ARCHS=arm64` on Apple Silicon, using the same project, scheme,
simulator destination and ad-hoc signing as above. The embedded Python packaging
script requires a single simulator architecture.
The focused Release suite verifies that fixture arguments and overrides are ignored;
the normal fixture-based UI suite still requires Debug. Runtime Proof is kept out of user Settings; its inspection screen is available
only through `--ui-testing --ui-screen=runtime-proof-inspection` in Debug.

For iPhone tab scrubbing, run the `UsabilityCleanupUITests/testTabBar…`
methods plus `testHighlightTraversesAndReversesAcrossAllTabs`. These verify release
selection, short holds with immediate movement, drag-away cancellation, normal taps,
Settings depth preservation and Reduce Motion/large-text presentation. Inspect a simulator recording for continuous
finger-following highlight movement; iPad uses the native adaptive tab interface.

## System presentation

Run `-only-testing:IllucetUITests/LiveActivityUITests` separately with `xcodebuild
test` on the selected simulator. The Debug-only `--live-activity-proof` screen
(`ILLUCET_LIVE_ACTIVITY_PROOF=1` for the UI runner) uses synthetic progress and no
media download. It requests a real ActivityKit activity and captures Home and
Notification Center; inspect its Home/Lock Screen
presentation separately. The unit suite injects processing expiration to prove safe
checkpoint retention, not real OS continuation admission. Neither is device proof.

## Real download

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ILLUCET_SIMULATOR_ID=<simulator-uuid> ILLUCET_AUTHORIZED_LIVE_TEST_CONFIG_PATH=<absolute-plist-path> Scripts/verify.sh live
```

Use an ignored local plist with `LiveTestsEnabled = true` and `StandardVideoURL` set to an explicitly authorized public video. The live command
explicitly enables one video-plus-audio production-pipeline test and verifies a
nonempty regular output with audio and video streams. Network errors are failures,
not permission to substitute fixture results. Do not report simulator output as
physical-device evidence.

Optionally set `ILLUCET_LIVE_CHAPTERS=1` on the authorized `live` invocation to
include creator chapters and mark discovered SponsorBlock segments as chapters.
This requires actual segments and verifies chapter-bearing video/audio output.

`ILLUCET_LIVE_INCLUDE_THUMBNAIL=1` uses a normalized H.264/AAC MP4 request with
Include Thumbnail and additionally requires an attached cover stream in the
completed output. Run this separately from recovery/chapter variants.

For interrupted-processing recovery, separately opt in to the same `live` command
with `ILLUCET_LIVE_BACKGROUND_RECOVERY=1`. It transfers one authorized public video,
uses H.264/AAC MP4, the native media processor and a synthetic 1–2 second SponsorBlock removal,
injects a delayed execution grant during the edit, then verifies completed media
and reuse of the verified base assembly before terminal cleanup. The production scheduler
is exercised and its admission status recorded. Grant timing is injected; this does not
prove OS background admission, physical lock-screen completion or live segment lookup.

`IllucetUITests/BackgroundDownloadUITests/testAuthorizedVideoCompletesWithoutReopening`
is a separate, explicit simulator-only live proof. In the UI runner's `.xctestrun`
EnvironmentVariables set `ILLUCET_BACKGROUND_LIVE=1`, the enabled
`ILLUCET_AUTHORIZED_LIVE_TEST_CONFIG_PATH`, `ILLUCET_BACKGROUND_APP_STATE_PATH` to the
installed app's `Library/Application Support/Illucet/IllucetState.json`, and
`ILLUCET_BACKGROUND_RECEIPT_PATH` to a temporary JSON output. Resolve the simulator
container after installation; Xcode can relocate it when replacing the test host.
Use normal app state with no unfinished jobs, retries off and download/review pages
enabled. The test launches without fixture mode, selects exact source 18 for video
and audio, presses Home while the job is running, and reads persisted completion
without reactivation. It records state/byte observations and requires a nonempty
regular output. Probe that file for audio/video separately. No execution grant is
injected; report its OS/runtime separately from the recovery test above.
The companion `testAuthorizedVideoCompletesWhenBackgroundedDuringPreparation`
presses Home earlier, while the job is still preparing. Both use the same live
opt-in variables and emit the actual stage/retry count. Production reserves UIKit's
short finishing allowance while foregrounded; it ends synchronously on expiration,
on job teardown or when a real continued-processing grant takes over. This is
separate from OS-controlled native transfers and from an extended processing grant.

## Download timing

`Scripts/benchmark-ytdlp.py` compares an authorized native-download log with upstream yt-dlp. Keep logs and measurements outside the repository. Network comparisons require explicit opt-in; simulator timing does not establish device performance.

## Dependency update

`Config/Dependencies.sh` pins wheel filenames and SHA-256 digests. Runtime and
package version strings can differ for yt-dlp nightlies; retain both exact pins.
Verify release metadata at official upstream/PyPI sources, refresh the three
pure-Python packages with `Scripts/fetch-stage0-dependencies.sh --python-packages-only`,
then run `python3 Scripts/sync-dependency-versions.py`. Run static checks, simulator
regressions and the real-download gate. The private EJS provider seam must pass
its contract tests; never loosen the version/proof checks to make an update pass.

## In-app updater verification

### Reproducible build profiles

`Config/Dependencies.sh` records a `stable`, `nightly`, or `pinned` extractor build
profile. Every profile selects an exact release, never a moving `latest` alias.
Stable requires `YYYY.MM.DD`; Nightly requires `YYYY.MM.DD.BUILD`; Pinned accepts
either. The current bundled Nightly is pinned to `2026.11.04.232659`.

Preview a complete config without changing files:

```sh
python3 Scripts/select-extractor-profile.py --profile nightly --version 2026.11.04.232659
```

Use `--profile stable` or `--profile nightly` with an explicit matching release to
prepare another build. The selector checks version-specific official [PyPI metadata](https://docs.pypi.org/api/json/),
universal-wheel identity, SHA-256, Python compatibility and yt-dlp's exact EJS/certifi
requirements. Unsupported metadata fails before any config write. It does not
download or execute package code, and it preserves native-runtime pins.

To apply a reviewed selection, add `--apply`, then run:

```sh
Scripts/fetch-stage0-dependencies.sh --python-packages-only
python3 Scripts/sync-dependency-versions.py
Scripts/verify.sh static
```

The config, package bundle and generated expectations must agree before building.
An alternate profile still needs simulator/provider and authorized live-download
verification before release; metadata acceptance alone is not runtime proof.
Commit the config and generated expectations together. Native upgrades require a
separate rebuild. Settings shows the running profile independently of the selected
update channel; a staged install or reset changes that label only after activation.

### Live updater check

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ILLUCET_SIMULATOR_ID=<simulator-uuid> ILLUCET_UPDATER_CHANNEL=Master Scripts/verify.sh updater-live
```

This explicit network test stages the selected official release in an isolated
store, activates it in a new runtime, downloads a public video with audio and
restores the bundle. It uses the public Blender Big Buck Bunny sample by default
or the standard video from an explicitly enabled `ILLUCET_AUTHORIZED_LIVE_TEST_CONFIG_PATH`.
The default test channel is Nightly, which needs a newer official release than
the bundled build to exercise installation. Set `ILLUCET_UPDATER_CHANNEL` to
`Master` or `Stable` to test a channel switch. The script requires one executed,
passing test.

For a controlled channel comparison, also set `ILLUCET_UPDATER_COMPARE_BUNDLED=1`.
It first downloads with the bundle, then repeats with the installed release using
the same configuration and locked format IDs. Both downloads must pass; the
installed runtime is restored even after a media failure. Receipts include only
format IDs, transport names and typed errors, never signed media descriptors.
Optionally set `ILLUCET_UPDATER_TEST_FORMATS` to one video format ID or a
comma-separated video-only,audio-only pair from that same authorized video's
inventory. Both runtimes must offer those exact identities; unavailable formats
fail the test instead of silently choosing another source. Provider receipts
record only challenge counts and typed failure counts. A single video-only ID
deliberately tests video-only output and requires zero audio streams in the result.

The native transport honors yt-dlp's optional `available_at` timestamp. It is an
absolute per-format not-before deadline, independent of URL expiry. Preserve it
through the single-use extraction cache; do not replace it with a fixed sleep or
wait inside Python. Background URLSession tasks use `earliestBeginDate`; foreground,
DASH preparation and HLS manifest requests use cancellable Swift waits. Invalid
timestamps or deferrals over ten minutes fail before a media request. Native
snapshots expose the scheduling time to liveness, which excludes deliberate waits.
Diagnostics report bounded relative wait seconds without storing the signed URL.

## Local signing

See [Signing](Signing.md). Keep credentials and profiles in ignored local configuration.

## Evidence

Keep build logs, screenshots, xcresult bundles and device receipts outside the repository. Report the source revision, executed test counts, runtime and outcome. Zero tests is not a pass; label unrun physical and live checks explicitly.

Before publishing, run `Scripts/verify-public-package.py --source` and scan every distributed payload. A private `--forbid-file` can add owner-specific identifiers without committing those identifiers. Inspect retained imagery separately. Upstream attribution is public provenance, not personal application data.

## Sharing and creator verification

Run `IllucetUITests/SharingAndCreatorUITests` for clipboard consent, collection search, bulk
History controls and Shortcuts settings. `ShortcutDownloadTests` covers durable
admission, cancellation, preference migration, draft preservation and request identity.
The Debug-only `--shared-link-proof` screen remains a synthetic system share-sheet
source for manual Shortcut checks; it does not request remote media. `BandwidthTransportTests` uses an in-process local HTTP fixture to
measure actual URLSession throttling; charging admission uses injected power state.

With explicit authorization, `Scripts/verify.sh part13-live` fetches at most three
public entries per NASA uploads/Shorts and SpaceX completed-streams tab, then
downloads one available public NASA Short with all five metadata sidecars. It is
separate from offline regression and requires exactly one executed passing live test.

Shortcut requests and legacy saved links retain the App Group
`group.$(ILLUCET_BUNDLE_ID)`; device profiles must still authorize it.
Settings → Shortcuts opens the signed bundled file directly in Add Shortcut. The two-action
wrapper in `Shortcuts/` extracts URLs and invokes `DownloadSharedLinkIntent`, with
Open When Run disabled. All behavior and download choices live in Illucet.
The legacy Open shared link intent remains compatible. The old Share extension
is no longer built or embedded.

To regenerate the distributable from the readable prototype:

```sh
python3 - <<'PY'
import pathlib, plistlib
source = pathlib.Path('Shortcuts/Download with Illucet.plist')
pathlib.Path('/tmp/Illucet-unsigned.shortcut').write_bytes(plistlib.dumps(plistlib.loads(source.read_bytes()), fmt=plistlib.FMT_BINARY))
PY
shortcuts sign --mode anyone --input /tmp/Illucet-unsigned.shortcut \
  --output '/tmp/Download with Illucet.shortcut'
```

Verify Add Shortcut on iOS with Illucet installed after replacing the bundled file.
The wrapper uses download-arrow glyph 61956 (`arrow.down`), verified against the
system's workflow icon mapping. Existing imported shortcuts require re-importing
to receive the new icon. The Mac can sign the iOS action even though it displays Unknown Action there.
The wrapper targets `com.local.illucet`; builds with a different bundle identifier
need a matching wrapper. Do not change signing just to satisfy this test.
Live execution needs separate opt-in; offline admission fixtures prove queue
ownership, not actual OS background scheduling.

## PiP and identity checks

Run `Scripts/verify.sh static` for identity, source-structure and Python checks.
`python3 Scripts/verify-branding.py --forbid <retired-name>` also scans current
tracked/untracked files and filenames case-insensitively; `--bundle <app-path>`
extends the scan to a packaged app. Git history and ignored build products are
outside the current-source scan.

Run `-only-testing:IllucetTests/PipTests` and
`-only-testing:IllucetUITests/PipUITests` for guide routing, typing, skip/replay,
mascot taps, preference persistence, cadence and large-text coverage.
`--pip-fast-text` accelerates dialogue only in Debug.

`Scripts/package-runtime-dependencies.sh <absolute-output-directory>` packages the
currently verified runtimes with the names expected by CI and emits a SHA-256 file.
The signed, team-independent Shortcut is bundled as an app resource; no external installation link
is needed. Sign its editable plist with `shortcuts sign` after converting to a
binary `.shortcut` file; signing requires the normal Shortcuts system service.
