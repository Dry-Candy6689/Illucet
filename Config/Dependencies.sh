#!/bin/sh
#
# Source-of-truth pins for native and Python Stage 0 dependencies.
# Keep this file data-only so Bash 3.2 and later can source it.

CPYTHON_VERSION="3.15.2"
CPYTHON_ARCHIVE="Python-3.15.2.tar.xz"
CPYTHON_URL="https://www.python.org/ftp/python/3.15.2/Python-3.15.2.tar.xz"
CPYTHON_SHA256="8b5536d280142ecf6cdfe15d12a21ba1c65e300bbf7b28a8d0cdb849575797de"

YTDLP_PROFILE="nightly"
YTDLP_VERSION="2026.11.04.232659"
YTDLP_PACKAGE_VERSION="2026.11.4.232659.dev0"
YTDLP_WHEEL="yt_dlp-2026.11.4.232659.dev0-py3-none-any.whl"
YTDLP_SHA256="8623aa358f20d513dc5ae4bcf2cbeea229a7b84b59c9f4e0d10f8fb1a6feba61"

YTDLP_EJS_VERSION="0.8.0"
YTDLP_EJS_WHEEL="yt_dlp_ejs-0.8.0-py3-none-any.whl"
YTDLP_EJS_SHA256="79300e5fca7f937a1eeede11f0456862c1b41107ce1d726871e0207424f4bdb4"

CERTIFI_VERSION="2026.10.23"
CERTIFI_WHEEL="certifi-2026.10.23-py3-none-any.whl"
CERTIFI_SHA256="e9b54de76e530bb6cf0ccd036787103acb58fd42ba930ea8bf948ddbaa2f61d1"

QUICKJS_VERSION="0.18.0"
QUICKJS_ARCHIVE="quickjs-amalgam-0.18.0.zip"
QUICKJS_URL="https://github.com/quickjs-ng/quickjs/releases/download/v0.18.0/quickjs-amalgam.zip"
QUICKJS_SHA256="6c05066a6b62b483e2ba0f83d7a16688c6958182b214bfd693529434cef84a9e"

FFMPEG_VERSION="9.0.2"
FFMPEG_ARCHIVE="ffmpeg-9.0.2.tar.xz"
FFMPEG_URL="https://www.ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz"
FFMPEG_SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
FFMPEG_SIGNATURE_URL="https://www.ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz.asc"
FFMPEG_KEY_URL="https://ffmpeg.org/ffmpeg-devel.asc"
FFMPEG_SIGNING_FINGERPRINT="FCF986EA15E6E293A5644F10B4322F04D67658D8"

LAME_VERSION="4.0"
LAME_ARCHIVE="lame-4.0.tar.gz"
LAME_URL="https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz"
LAME_SHA256="3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb"
