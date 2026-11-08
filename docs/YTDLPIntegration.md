# yt-dlp integration

`Config/Dependencies.sh` pins the runtime versions, exact Python wheel names and
SHA-256 hashes. `Scripts/sync-dependency-versions.py` generates Swift and Python
runtime expectations; `--check` detects stale generated files. Package and runtime
versions differ for nightlies, so both are pinned independently. Current runtime:
yt-dlp 2026.11.04.232659, EJS 0.8.0, QuickJS-ng 0.18.0.

## Ownership

Embedded Python runs yt-dlp with `download=False` and returns bounded typed JSON
through PythonEngine. Swift requests exact selected format IDs. The native EJS
provider calls in-process QuickJS; import-contract tests guard its private yt-dlp
API integration. Runtime proof checks provider use and expected EJS hashes rather
than accepting a fallback that merely returns metadata.

Ordinary anonymous direct downloads reuse a recent in-memory extraction through a
one-use handoff instead of extracting separately for the picker, preparation and
stream resolution. Runtime proof always requests fresh evidence. The bounded lifetime,
invalidation and fallback rules are in [BackgroundBehavior](BackgroundBehavior.md).

Swift URLSession owns media transfer. Signed transport URLs, playlists, headers
and decryption material are ephemeral. Durable queue/checkpoint/history records
keep stable source identity and accepted local files, never raw key bytes or tokens.

## Exact transport

Automatic selection can recompute supported formats after fresh analysis; manually
selected IDs remain exact and fail when unavailable. Direct HTTP is preferred on
otherwise equivalent ties. DASH/HLS carry separate typed plans, validated again in
Swift; they are not treated as direct media URLs.

DASH stages bounded ordered fragments, retries eligible transient same-fragment
failures, validates trustworthy sizes, assembles locally and verifies output.
HLS resolves bounded VOD playlists and validates exact selected video/format,
protocol, extension and media role before fetching initialization/media resources.
The resolver fetches yt-dlp's exact selected media leaf directly; refetching a
parent master can regenerate signed URLs and cannot strengthen the selected
identity. A master returned at that leaf is rejected, with no variant fallback.
The trusted extension comes from yt-dlp metadata, not URL, MIME or filename guesses.
For HLS MP4/M4A sources, native probing also accepts the MPEG-TS intermediate
transport container while preserving codec/role checks. Native remux and final
container verification still run before export.

The HLS playlist is the encryption authority. Ordinary identity AES-128 key rotation,
explicit IV and sequence-derived IV semantics are supported. Keys are bounded exact
16-byte responses and cached only within the operation. Only verified plaintext
enters assembly. SAMPLE-AES, DRM, session keys, nonidentity formats and encrypted
byte ranges remain rejected. Reconstructed incomplete HLS operations are cancelled
and cleaned rather than resumed with lost ephemeral state. A fresh unencrypted plan
can reuse completed resources only with unchanged plan/URL identity, a fresh strong
ETag from that exact resource, and matching local hashes. Typed 403/410 refreshes
retain the originally selected format facts and stop after two attempts per source.

## Updating

Use official release metadata and verified wheels, then run Python contract tests,
the deterministic simulator suite and a separately authorized real download through
the app pipeline. Upstream recommends the nightly channel for site-breakage fixes;
the bundle retains a pinned fallback. Settings can explicitly stage a compatible
official release for activation on the next process launch, with local provider
validation and previous/bundled fallback. Native components still require rebuilding.

[Development](Development.md) contains commands. [development guide](Development.md) distinguishes
current test evidence from historical claims. [UpdaterSecurity](UpdaterSecurity.md)
describes the separate on-device installation boundary.

## Manual cookie import security

Accounts accepts an explicitly selected Netscape cookies text file (at most 256 KiB).
Parsing is local and rejects malformed/expired sessions; unrelated domains are
ignored. Only the existing YouTube/Google domain allowlist and bounded cookie fields
can enter an account. The preview displays a count, never cookie values. Save is an
explicit action and uses the same device-only Keychain store as in-app sign-in;
cookies are supplied to extraction in memory and never copied into descriptors,
history, diagnostics or a temporary cookie file. Cancelling clears the pending
import. The original document remains wherever the user selected it; the UI tells
the user to delete it when no longer needed. Import does not bypass authentication,
DRM or service access controls. Physical account-only testing remains separate.

Creator tabs use bounded inventories (uploads, Shorts, completed streams). Ongoing
and upcoming streams are excluded from completed-replay eligibility. Detailed
metadata is an explicit additional request; date/resolution/size filters exclude
unknown values instead of guessing. Filtering affects loaded inventory only and
selection changes only on the explicit Select matching action.
