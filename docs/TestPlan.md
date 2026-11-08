# Test coverage

Use [Development](Development.md) for executable commands. Tests preserve observable
behavior across extraction, exact format selection, direct/Range/DASH/HLS acquisition,
AES key/decryption/staging, assembly/publication, processing, output validation,
subtitles, SponsorBlock, chapters, persistence, queue/batches and export lifecycle.

Behavioral changes require regression cases that reproduce the defect. Offline
fixtures do not establish live-service or physical-device correctness. Keep live
opt-in separate from the full unit suite; zero tests is NOT RUN.

UI validation covers iPhone/iPad, light/dark, Dynamic Type, empty/populated state,
queue/history/settings, rotation and adaptive navigation. Physical background,
Photos, notifications and interruption behavior needs device evidence when available.
