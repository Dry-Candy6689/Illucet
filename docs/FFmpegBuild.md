# FFmpeg iOS Build

## Current boundary

The in-process bridge supports the explicitly advertised codec/container matrix, bounded verification and cancellable processing. The native fixture suite covers media properties and failure boundaries; physical playback, Photos and OS background scheduling require their own device checks.

## Rebuild

First fetch and verify the pinned archives and FFmpeg release signature:

```sh
./Scripts/fetch-stage0-dependencies.sh
```

Then build:

```sh
./Scripts/build-ffmpeg-ios.sh
```

The script discovers Xcode through `Scripts/resolve-developer-dir.sh`, so it
does not change the machine-wide `xcode-select` value. It refuses unpinned
archive hashes, an unexpected FFmpeg signing fingerprint, unsafe archive paths,
links/special archive members, missing source structure, unexpected target
architectures, or incorrect XCFramework platform metadata. A failed final
replacement restores the previous working XCFramework.

Generated configure logs, command lines, installed-header manifests, exported
symbols, and a hash report are retained under:

```text
Vendor/Build/FFmpeg-9.0.2/
```

Those generated files are intentionally not normal source-control inputs.

## Configure policy

All slices are static, position-independent native libraries. There are no
FFmpeg command-line programs in the package and the iOS app must never launch
an executable or child process.

The shared FFmpeg configure policy is:

```text
--enable-cross-compile
--target-os=darwin
--enable-static
--disable-shared
--enable-pic
--disable-programs
--disable-doc
--disable-debug
--disable-avdevice
--disable-network
--disable-autodetect
--enable-avcodec
--enable-avformat
--enable-avfilter
--enable-swscale
--enable-swresample
--enable-videotoolbox
--enable-audiotoolbox
--enable-libmp3lame
```

The x86_64 simulator additionally uses `--disable-x86asm`, avoiding a NASM
build dependency. LAME uses:

```text
--disable-shared
--enable-static
--disable-frontend
--disable-decoder
--disable-nasm
--disable-dependency-tracking
--with-pic
```

LAME's correct switch is `--disable-nasm`; it does not support
`--disable-asm`. `lt_cv_sys_max_cmd_len=65536` avoids a cross-build libtool
probe that cannot execute target programs.

`ZERO_AR_DATE=1` is exported for all static archive creation. FFmpeg embeds
configure arguments and `__FILE__` values in its libraries, so the script also
uses a locked, stable `Vendor/Build/FFmpeg-9.0.2/Work` path instead of a random
temporary name. An interrupted prior work tree is moved aside rather than
silently overwritten, and the last accepted XCFramework remains installed
until the new one passes every check. Xcode 27 may emit its two
`AvailableLibraries` entries in either order, so the already-validated plist is
normalized to device-then-simulator order before hashing. Exact archive hashes
can still change when the repository path, Xcode/Clang, upstream build tooling,
source pins, script revision, SDK, architecture set, or deployment target
changes.

## Included capabilities and exclusions

The build keeps FFmpeg's native codec, demuxer, muxer, parser, bitstream-filter,
and media-filter registrations except where the options above or unavailable
external libraries exclude them. It includes:

- `libavcodec`;
- `libavformat`;
- `libavfilter`;
- `libavutil`;
- `libswscale`;
- `libswresample`;
- `libmp3lame`;
- AudioToolbox and VideoToolbox integration.

`--disable-autodetect` intentionally prevents host libraries from leaking into
the build. Consequently, this checkpoint does not include zlib-backed FFmpeg
PNG support or arbitrary optional codec libraries. JPEG artwork is available;
the app may use ImageIO for PNG thumbnail conversion. No x264, x265, libvpx,
libaom, fdk-aac, or other optional external codec library is enabled. Native
FFmpeg codecs and VideoToolbox cover the initial proof surface. The controlled
simulator runtime opened the H.264 VideoToolbox encoder, but that is not proof
of the physical hardware path or of arbitrary source compatibility.

`--disable-network` is deliberate. Swift performs direct transfers, and the
media processor consumes local files. Manifest/network support
must be implemented and tested separately; this library build does not prove
it.

The generated component configuration confirms H.264, HEVC, and ProRes
VideoToolbox encoders; AAC AudioToolbox encode/decode; libmp3lame encoding;
native H.264, HEVC, AAC, MP3, Opus, Vorbis, FLAC, and MJPEG decoding; MOV,
Matroska/WebM, MP3, FLAC, Ogg, and WAV muxing; and scale, frame-rate, loudness,
trim, and resample filters. PNG encode/decode and libass subtitle burn-in are
not enabled in this minimal build. P8.2 VTT/SRT sidecar parsing and conversion
is a bounded Swift path and requires no FFmpeg dependency rebuild. Part 8 uses
the existing MOV/Matroska/WebM muxers and `mov_text`/SubRip/WebVTT codecs for
typed subtitle embedding, while rendered burn-in uses the in-process Swift
renderer and VideoToolbox rather than libass. Chapter writing uses the existing
muxers. No generated framework was rebuilt for Part 8.

## Linking

The static archive requires:

```text
AudioToolbox.framework
VideoToolbox.framework
CoreFoundation.framework
CoreMedia.framework
CoreVideo.framework
libm
libpthread
```

The build script compiles and links an arm64 iOS Simulator smoke program using
the packaged module and these dependencies. It does not execute that program.

## License

The selected FFmpeg configuration does not enable `--enable-gpl`,
`--enable-nonfree`, or any nonfree library. FFmpeg reports the LGPL license for
this configuration. LAME 4.0 is LGPL 2.0.

The XCFramework header payload carries FFmpeg's LGPL 2.1/3 texts and LAME's
license text. Static distribution has additional LGPL obligations, including
notices, corresponding source availability, and a relinking mechanism or
another compliant method. Before distributing even a personal build to
another person, review the exact generated configure report and obtain legal
advice appropriate to that distribution. This document is engineering
documentation, not legal advice.
