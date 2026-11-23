<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Design/Brand/Illucet-Dark.png">
  <img src="Design/Brand/Illucet-Light.png" alt="Illucet app icon" width="96" height="96">
</picture>

# Illucet

An on-device media downloader for iPhone and iPad.

Paste a media link or import a list of links, choose download options, and save to Illucet, Files or Photos.

- Video, audio, playlists, subtitles and thumbnails
- Trimming, chapters, conversion and SponsorBlock
- Download queues, history and background transfers
- Share Sheet Shortcuts, custom presets, themes and app icons
- Text/rich-text bulk imports, mixed-site batches and original post images
- Site-scoped accounts, per-site defaults and selectable download engines
- Optional onboarding and hints from PiP, the chinchilla guide

Downloads and processing run on your device using native transfers, optional aria2, yt-dlp, QuickJS and FFmpeg.
No Illucet account or server is required. Background completion depends on iOS execution limits.
On iOS 26, Shortcut preparation has a shorter time limit and may require reopening Illucet
to continue a saved link; iOS 27 can request more execution time.
See [background behavior](docs/BackgroundBehavior.md#shortcut-startup).

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

In **SideStore** or **AltStore Classic**, open **Sources → +** and paste the URL below.

```text
https://github.com/Dry-Candy6689/Illucet/releases/latest/download/illucet-source.json
```

Find Illucet in the source and tap **Free** to install it. The source follows the latest Illucet release. Your sideloading app signs the IPA with your own Apple account.

**[Download the unsigned IPA manually](https://github.com/Dry-Candy6689/Illucet/releases/latest/download/Illucet.ipa)** · [Release notes and checksums](https://github.com/Dry-Candy6689/Illucet/releases/latest) · [Signing help](docs/Signing.md)
