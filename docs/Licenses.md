# Licenses and notices

Illucet's original code is licensed under [GPL-3.0](../LICENSE), copyright 2026 Illucet contributors. Third-party components retain their own notices and licenses. The release includes complete notices and exact native-source inputs for rebuilding the linked libraries.

| Component | Pinned version | License in pinned artifact | Notes |
| --- | --- | --- | --- |
| CPython | 3.15.2 | Python Software Foundation License and historical notices | Full text is bundled at `python/lib/python3.15/LICENSE.txt`. |
| yt-dlp | 2026.11.04.232659 | Unlicense | Pure Python; pinned wheel license is under its `.dist-info/licenses` directory. |
| yt-dlp EJS | 0.8.0 | Unlicense AND MIT AND ISC | Metadata covers EJS plus its bundled JavaScript dependencies. |
| QuickJS-ng | 0.18.0 | MIT | Copyright/permission notice is present in the pinned amalgamation header. |
| FFmpeg | 9.0.2 | LGPL 2.1-or-later for this configuration | `--enable-gpl`, `--enable-nonfree`, and GPL external codecs are not enabled. |
| LAME | 4.0 | LGPL 2.0 | Linked statically for MP3 encoding; acknowledgment and LGPL obligations apply. |
| certifi CA bundle | 2026.10.23 | Mozilla Public License 2.0 | The bundled certificate data carries the pinned wheel notice. |

CPython's iOS support build also contains OpenSSL 3.5.9, bzip2 1.0.8,
libffi 3.4.7, mpdecimal 4.0.0, XZ 5.6.4, and zstd 1.5.7. Their exact upstream
archives and hashes are recorded in `Vendor/PythonSourceDeps.sha256`.
The release notices include the complete texts from those verified build inputs.

## FFmpeg/LAME configuration boundary

The tracked FFmpeg build must remain LGPL:

- no `--enable-gpl`;
- no `--enable-nonfree`;
- no libx264, libx265, or other GPL/nonfree codec dependency;
- libmp3lame is the only enabled external codec library;
- FFmpeg and LAME source versions, build flags, modifications, and relink
  materials must remain available as required by their licenses.

Illucet currently uses unmodified upstream FFmpeg and LAME sources. The narrow
Illucet C bridge is application code and is built separately from the upstream
source tree.

## SponsorBlock icon

The Settings row uses the unmodified plain shield/play icon by munadikieh from
[SponsorBlock's upstream assets](https://github.com/ajayyy/SponsorBlock/blob/master/public/icons/IconSponsorBlocker256px.png),
without the dollar badge. Its SHA-256 is
`a3cf4236f66f33b7135fc33d6028072c0d2d26d231e1780152168bc97f4effc3`.
The [Commons logo record](https://commons.wikimedia.org/wiki/File:SponsorBlockLogo.png)
classifies the geometric logo as public domain and also carries an LGPL-3.0-or-later
notice. This is an attribution/provenance record, not a grant of trademark rights.
The app identifies the SponsorBlock integration and credits its logo author in
About & licenses.

## Source locations

SponsorBlock category descriptions are copied from the official English
[ExtensionTranslations revision 166548e9](https://github.com/ajayyy/ExtensionTranslations/blob/166548e90223a11c57713439080c1903b8853bd6/en/messages.json),
used by [SponsorBlock](https://github.com/ajayyy/SponsorBlock). Copyright the
SponsorBlock contributors; upstream SponsorBlock is GPL-3.0. Full
category names and descriptions are available in the app's category popovers.

Pinned source/download hashes and URLs live in `Config/Dependencies.sh`.
`Scripts/fetch-stage0-dependencies.sh` verifies them. Generated frameworks are
intentionally ignored; a clean build must recreate them from those sources and
the tracked scripts.

Complete distribution notices are in [ThirdPartyNotices.txt](ThirdPartyNotices.txt), also included in the app and release. Native source archives and the source tag accompany each public app release.

`Scripts/package-native-sources.py` packages the exact upstream archives, support-library recipes, patches and build scripts with neutral archive metadata. Additional source digests are pinned in `Config/NativeSupportSources.json`.
