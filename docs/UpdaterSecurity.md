# Extractor updates

Settings → yt-dlp & EJS checks official Nightly, Stable and Master releases. Nightly
is the recommended default and the bundled profile. Automatic checks are optional
and run at most once per 24 hours for the current channel. Install and restore are
explicit. A switch to an older release requires confirmation, and the exact offer
must still match the selected channel’s latest release when installation begins.
The active version changes on the next process launch.

## Package and activation boundary

- Stable and Nightly use the official universal yt-dlp wheel from PyPI. EJS and
  certifi use their exact upstream-pinned universal wheels. PyPI requests use
  canonical HTTPS URLs with redirects disabled.
- Master uses the single official `yt-dlp.tar.gz` asset from the checked GitHub
  release. It must match the release API’s size and SHA-256, and can redirect once
  to GitHub’s release asset host. The app reads the version, channel, origin and
  pinned dependencies as data, then stages only the `yt_dlp` Python package.
- Metadata, compressed downloads, expanded files and entry counts are bounded.
  Downloads must match the official size and SHA-256. The bundled staging helper
  rejects traversal, links, special files, duplicate case-folded paths, native
  libraries and import hooks. It reads literal version assignments without
  importing downloaded code during installation.
- Installation creates an immutable generation with hashes for every installed
  file and a native-runtime compatibility contract. Atomic metadata publication
  only marks it pending; the running interpreter keeps its existing imports.
- Next launch rechecks the complete generation, then starts the real interpreter
  and exercises the local EJS/QuickJS provider contract. Successful startup commits
  the selection. Corrupt packages, import/contract failures or an interrupted
  activation fall back to the previous valid generation or bundled packages.
- Published generations are read-only. Private metadata and package storage use
  protection until first device unlock, permitting imports during later background
  transfers. Old unreferenced generations are removed only during startup, before
  an interpreter can be using them. Malformed selection metadata fails explicitly.
- Restore Previous Version validates the retained generation and queues it for the
  same next-launch activation and recovery checks. The store keeps active, previous
  and pending selections, not an archive of every version ever installed.
- Restore Bundled Version queues a next-launch reset. The app bundle stays
  immutable. No in-process hot reload, plugin installation or native updates occur.

Official HTTPS release metadata and checksums are the trust root. Downloaded
Python code runs in the embedded interpreter only after verified activation.
The provider depends on a private yt-dlp interface, so an incompatible release can
be rejected even when its download/hash is valid. CPython, QuickJS, FFmpeg, LAME,
Swift and signed frameworks always require an app rebuild.

## Evidence

Offline tests cover archive rejection, metadata/hashes, generation publication,
corruption, crash recovery, real writable imports, concurrent runtime startup,
contract fallback and bundled restoration. `Scripts/verify.sh updater-live` is a
separate explicit opt-in. It stages official packages, activates them in a fresh
runtime, performs one public video-plus-audio production download, verifies the
output and restores bundled packages in an isolated test store. Default simulator
regression excludes this network test. See [development guide](Development.md) for executed results.
