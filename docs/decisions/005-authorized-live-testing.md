# Decision 005 — Authorized Live Testing

Status: Active

## Decision

Illucet keeps deterministic tests and live-service downloader validation separate.

Live downloader validation uses only media the user owns or is otherwise authorized to save. The tracked public standard fixture is Blender Foundation's Creative Commons Attribution Big Buck Bunny video:

`https://www.youtube.com/watch?v=YE7VzlLtp-4`

The tracked `AuthorizedLiveTestURLs.example.plist` records this public standard URL but keeps `LiveTestsEnabled` false. A local ignored `AuthorizedLiveTestURLs.plist` may be created from that template only when live testing is intentionally enabled.

## Frequency

Live downloading is not an automatic per-task cost.

Run the basic authorized live matrix when:

- a broad/full-app end-to-end validation is already being performed and the simulator/network prerequisites are usable; or
- a task materially changes downloading, extraction/resolution, output routing, thumbnails, or another path where a live result provides relevant proof; or
- the user explicitly asks for a manual live downloader check.

Unrelated UI/settings/documentation tasks do not need live downloading.

## Basic live matrix

When the basic live downloader matrix is required, exercise the production path for:

- Video + Audio;
- Audio Only;
- Video Only;
- Thumbnail Only.

A test is not a PASS merely because metadata analysis or queue creation succeeded. The requested output must complete and be validated through the production path appropriate to that mode.

## Cleanup and evidence

- Save live outputs only in the designated temporary test location.
- Delete the live outputs after validation.
- Never use arbitrary YouTube/media URLs chosen by the agent.
- Never commit private URLs, cookies, tokens, credentials, or signed transport URLs.
- Report live evidence separately from deterministic fixture evidence.
- If a requested live gate cannot run, report `BLOCKED` or `NOT RUN` rather than substituting deterministic evidence.

## Related contracts

- `docs/TestPlan.md`
- `docs/YTDLPIntegration.md`
- `AuthorizedLiveTestURLs.example.plist`
