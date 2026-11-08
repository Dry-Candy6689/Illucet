# Decision 006 — Verification Cost Policy

Status: Active policy as of 2026-08-13; executable adoption remains P9A.14.

## Decision

Illucet does not routinely decode an entire media file merely to decide whether a normal production download may be published.

This applies to both ordinary no-reencode paths and material media rewrites.

Production verification uses two practical levels:

### Fast structural verification

Use for direct/simple no-reencode paths such as stream-copy Video + Audio merge, remux, original-audio extraction, video-only copy, metadata/chapter-only rewrite where the media essence is copied, and equivalent paths.

Structural proof must preserve meaningful correctness without decoding every frame/sample. It includes the applicable facts:

- file exists and is non-empty;
- reliable expected transferred byte count matches when known;
- real container opens and matches the intended output;
- extension matches the real container;
- required stream counts/codecs match;
- requested dimensions/frame rate/sample rate/channel count match where applicable;
- duration/timeline is sane and consistent with the requested result;
- requested properties were not silently substituted;
- primary streams contain valid data near their tails and obvious early-ending/truncation conditions are rejected.

### Bounded strong/sample verification

Use for material rewrites such as audio/video transcode, subtitle burn-in, accurate trim, SponsorBlock media edits, and similar operations where Illucet generated new media content.

A bounded strong verifier combines structural truth with a small, explicitly bounded amount of decoding and operation-specific evidence. It does **not** decode every frame/sample by default.

Examples:

- transcode: representative decode windows/samples for each required primary stream, including start, near end, and a middle/operation-relevant position where useful, plus requested codec/property verification;
- subtitle burn-in: bounded real pixel-rendering proof at selected cue time(s), plus normal structural/output truth;
- accurate trim and SponsorBlock edits: exact requested/applied timeline and duration truth plus bounded A/V/sample checks around important edit boundaries;
- Apple-compatible output: the existing small asset/sample/playback compatibility proof may remain when it adds distinct evidence.

Full-media decode remains available as an explicit developer/test/runtime-proof/diagnostic capability and may be invoked for a separately authorized troubleshooting run. It is not the normal production publication verifier.

## Why

Whole-file decoding can be expensive enough to dominate post-transfer time, particularly when the requested operation itself was stream copy or when multiple verification layers repeat similar work.

P9A.14 Phase 2 already established an important foundation: explicit verification classes, fast structural source/output probing, per-primary-stream tail checks, exact-byte rejection where reliable, and removal of duplicate final-output probes.

The user subsequently chose the faster forward tradeoff for complex rewrites too: accept the small residual risk that a structurally valid file contains an isolated defect outside sampled windows rather than paying a complete decode cost for every transcode/burn-in/edit.

Illucet still must fail closed for known structural, requested-property, timeline, tail/truncation, sampled-decode, or operation-specific proof failures.

## Constraints

- Never weaken truthful container/extension/stream/codec/duration/requested-property verification merely to gain speed.
- Never publish a known partial, structurally invalid, prematurely ending, mismatched, or sampled-decode-failing output.
- A function renamed `probe` or `strong` does not satisfy this decision if it still scans/decodes the whole file in the normal production path.
- Production call sites should choose verification class explicitly; an implicit helper default must not silently route ordinary or complex downloads through full decode.
- Bounded sample count/window duration must remain fixed or otherwise provably bounded rather than scaling with media duration.
- Preserve operation-specific proof that establishes facts generic verification cannot, such as real rendered subtitle pixels or edit-boundary timeline/A/V truth.
- Keep complete full-decode tooling/tests available so targeted diagnosis can still prove whole-file decodability when explicitly requested.
- P9A.14 regression coverage must prove representative ordinary and complex production paths do not route through the full-media verifier.

## Relationship to historical evidence

Historical Part 1 and later checkpoint evidence describing full decode remains truthful for those historical implementations. P9A.14 Phase 2 also remains a valid implementation checkpoint for the structural-verification foundation it introduced.

This decision changes the forward production verification policy; it does not rewrite past results.
