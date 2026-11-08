# Toolchain Troubleshooting

Illucet deliberately does not change the Mac-wide active developer directory.
On this Mac, `xcode-select -p` currently resolves to Command Line Tools, which
cannot build iOS projects. Always choose Xcode explicitly for a Illucet command.

## Known-working toolchain

At the time of this document, the installed toolchain is Xcode 27 beta 3:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -list -project IllucetApp.xcodeproj
```

Current targets are `Illucet`, `LiveActivityExtension`, `IllucetTests`, and
`IllucetUITests`. The former Share extension is replaced by a native App Intent.

## Testing a second Xcode safely

When Xcode 27 beta 4 (or a later supported Xcode) is installed, retain the
known-working app and give the new bundle a distinct path, for example:

`/Applications/Xcode-27-beta4.app`.

Use it for one command at a time:

```sh
DEVELOPER_DIR=/Applications/Xcode-27-beta4.app/Contents/Developer \
  xcodebuild -list -project IllucetApp.xcodeproj
```

Then run the same targeted build or test that failed under the default
toolchain. Do not use `sudo xcode-select --switch`, and do not rename or delete
the known-working Xcode installation while investigating a build failure.

## Before rebuilding native dependencies

CPython, QuickJS-ng, and FFmpeg XCFrameworks are large generated artifacts.
Do not rebuild them because an Xcode command is slow or produces an unrelated
Swift error. Rebuild only when a framework is missing, fails validation, has an
architecture/link error, or the intended source/configuration changed. The
reproducible commands and pinned versions are in `Scripts/` and
`Config/Dependencies.sh`.

## Disk-space guard

Installing a parallel Xcode requires enough room for both the downloaded XIP
and the expanded application bundle, plus build products. Check before
downloading:

```sh
df -h /Applications $PWD
```

On 2026-07-28 this Mac had only 14 GiB free, so a parallel Xcode 27 beta 4
installation was intentionally not attempted. Free sufficient space first;
never overwrite the existing Xcode merely to make room.
