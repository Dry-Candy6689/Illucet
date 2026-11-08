# Illucet development

Verify branch, HEAD, origin and worktree changes before editing. Do not pull into active work automatically.
Read [README](README.md), [Development](docs/Development.md) and the relevant source.
[Architecture](docs/Architecture.md) maps ownership.

- Preserve features and saved data unless the requested change requires otherwise.
- SwiftUI owns presentation; native Swift owns transfers; Python owns extraction; FFmpeg owns processing. Keep C and unsafe pointers inside native bridges and wrappers.
- Never persist signed transport URLs, keys, cookies or authorization headers in descriptors, history or diagnostics.
- Preserve exact media identity, job-local containment, truthful progress, cancellation and transactional publication. Do not bypass access controls.
- Use command-local DEVELOPER_DIR. Do not change machine-wide signing, Xcode, power, networking or remote access to make a test pass.
- Run Scripts/verify.sh static and relevant tests. Live tests require explicit opt-in and separate execution. Distinguish offline, live, simulator and physical-device evidence.
- Add regression cases for behavioral fixes. Keep responsibilities coherent; avoid arbitrary file splits and wrapper layers.
- Keep docs current and concise. Do not commit local reports, personal configuration or task roadmaps.
- Public artifacts must pass Scripts/verify-public-package.py, including their nested runtimes. Keep signing profiles, developer identities and personal paths out of distributed packages.
