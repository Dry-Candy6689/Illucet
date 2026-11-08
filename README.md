# Illucet

An on-device media downloader for iPhone and iPad, with an optional chinchilla guide named PiP.

Paste a YouTube link, choose a preset, and save to Illucet, Files or Photos.

- Video, audio, playlists, subtitles and thumbnails
- Trimming, chapters, conversion and SponsorBlock
- Download queues, history and background transfers
- Share Sheet Shortcuts, custom presets, themes and app icons

Downloads and processing run on your device using yt-dlp, QuickJS and FFmpeg.
No Illucet account or server is required. Background completion depends on iOS execution limits.

## Build

Requires Xcode 27, XcodeGen and iOS/iPadOS 26 or later.

```sh
git clone https://github.com/Dry-Candy6689/Illucet.git
cd Illucet
Scripts/restore-runtime-dependencies.sh
xcodegen generate
```

Open `IllucetApp.xcodeproj`. Select your own signing team for device builds.
See [build instructions](docs/BuildFromScratch.md) for prerequisites and building runtimes from source.

[Development & tests](docs/Development.md) · [Architecture](docs/Architecture.md) · [Known limitations](docs/KnownLimitations.md) · [Contributing](CONTRIBUTING.md)

## License

Illucet's original code is [GPL-3.0](LICENSE). [Third-party notices](docs/Licenses.md) cover bundled components and artwork.

## Download

**[Download Illucet.ipa](https://github.com/Dry-Candy6689/Illucet/releases/latest/download/Illucet.ipa)**

The IPA is unsigned. Install it using a sideloading tool and your own signing account.
[Release notes and checksums](https://github.com/Dry-Candy6689/Illucet/releases/latest) · [Signing help](docs/Signing.md)
