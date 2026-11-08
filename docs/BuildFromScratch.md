# Build from source

Requires an Apple Silicon Mac, Xcode 27, XcodeGen, Python 3 and GitHub CLI. For native runtime builds, also install CMake, Ninja, pkgconf, Autoconf, Automake, GNU libtool and GnuPG. Allow at least 20 GiB for a complete native build.

```sh
brew install xcodegen gh cmake ninja pkgconf autoconf automake libtool gnupg
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Restore verified runtimes

```sh
Scripts/restore-runtime-dependencies.sh
xcodegen generate
```

The runtime archive is downloaded from this repository's pinned runtime release. Its SHA-256 and member paths are checked before installation. No private repository or Apple account is needed. `Config/RuntimeRelease.json` pins the archive; `Config/Dependencies.sh` pins its components.

Open `IllucetApp.xcodeproj` and select the Illucet scheme. See [Signing](Signing.md) for a device build.

## Rebuild every native component

Instead of restoring prebuilt runtimes:

```sh
Scripts/fetch-stage0-dependencies.sh
Scripts/build-python-ios.sh
Scripts/build-quickjs-ios.sh
Scripts/build-ffmpeg-ios.sh
xcodegen generate
```

The scripts verify pinned archives and FFmpeg's detached signature. Python uses the upstream Apple build scripts; exact support-package digests are recorded in `Vendor/PythonSourceDeps.sha256`. Native build work defaults to `/private/tmp/IllucetNativeBuild`, keeping personal home paths out of distributed binaries. Set `ILLUCET_NATIVE_WORKSPACE` to another neutral absolute directory if needed. Generated frameworks live in ignored `Vendor/Frameworks`.

The app uses a trimmed Python standard library: CPython's upstream test suites, their sample keys and the unused ensurepip bundle are excluded. Illucet's own tests remain in the source tree. The native packaging patch changes signing/file attributes only; the source patch and dependency pins are tracked.

## Verify and package

```sh
Scripts/verify.sh static
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ILLUCET_SIMULATOR_ID=<uuid> Scripts/verify.sh simulator
Scripts/build-unsigned-handoff.sh /private/tmp/IllucetRelease
```

Discover simulator IDs with `xcrun simctl list devices available`. The handoff contains `Illucet.ipa`, checksums, complete notices, signing help and local build logs. Public release assets include the IPA, notices, source inputs and checksums; build logs stay local.

See [Development](Development.md) for UI, live-download and Release guard invocations, and [Licenses](Licenses.md) for rebuilding linked components. Native media bytes can vary by toolchain; verify actual properties and record new checksums.

## Artwork and Shortcut

Committed app assets are ready to build. `Scripts/generate-app-icon.swift` deterministically exports the masters in `Design/Brand`; `Scripts/validate-app-icon.sh` checks the catalog. [Artwork provenance](IconArtwork.md) describes the variants.

The editable Shortcut is in `Shortcuts`. Convert its plist to a binary plist with the `.shortcut` extension, then use `shortcuts sign --mode anyone`. It targets the app bundle, without a developer-team binding. Verify Add Shortcut and actual intent execution after changing it.
