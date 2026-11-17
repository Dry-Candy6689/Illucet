# Known limitations

- Recognized multi-site links still depend on upstream extractors, service changes,
  geography and legitimate session access. A recognized link is not a guarantee
  that a particular post can be downloaded. New-site profile/board scraping and
  ongoing live recording are excluded. Cookies remain isolated by website.
- Post-image adapters cover Instagram photos/carousels, Reddit images/galleries,
  X attached photos, Bluesky image posts, TikTok slideshows, Pinterest image pins
  and Facebook photo links or numeric post IDs. Facebook pagination is rejected
  when the page supplies an incomplete gallery; individual photo links can be
  imported instead. Facebook photo posts are limited to 50 images. Opaque
  Facebook post IDs still need the page to expose a matching post identity.
  YouTube community posts, profiles, boards and whole-account image archives
  are unsupported. YouTube, Vimeo, Dailymotion and Twitch primarily use the
  video/audio path; SoundCloud uses audio. Video posters are not post images.
- The yt-dlp transfer engine needs in-process execution. Incomplete Python
  transfers restart after suspension; verified sources and normal native transfer
  recovery retain their existing behavior. No external downloader/FFmpeg process
  or remote token service is used.
- WebKit challenge execution uses a separate WebKit process with time/output
  bounds. Local YouTube PO tokens are generated on demand while the app is open.
  Their generator and a token-bearing download passed simulator live checks.
  Background token requests wait for foreground continuation.
- Image identity uses extractor post/asset facts plus a hashed change fence when
  only an ordinal is supplied. TikTok ordinal photos use native content probes
  instead, bounded to 50 slides, 8 MiB per photo and 64 MiB per inventory. These
  probes add network reads during preparation and refresh. Other ordinal image
  sources can require reviewing the post after a signed-URL change. Metadata
  removal may be unavailable for a particular image type.
- Reddit discovery and expired-source refresh require the app in the foreground
  to open the site's post page. Original gallery images must be present in that
  page. Access gates, deleted posts and connection challenges can still prevent
  extraction.

- iOS controls background execution. Native transfers can continue independently; long processing, force quit, notifications and locked-device behavior depend on OS scheduling and signing capabilities. Reopening can continue eligible saved checkpoints.
- On iOS 26, Shortcuts have a short preparation window; if a download cannot start in time, the link is saved for continuation in Illucet. iOS 27 can request a longer intent execution window. Neither version guarantees uninterrupted background completion. See [Shortcut startup](BackgroundBehavior.md#shortcut-startup).
- HLS supports bounded VOD and ordinary manifest-supplied identity AES-128. DRM, SAMPLE-AES, session keys, encrypted byte ranges and ongoing live recording are unsupported. Expiry refresh remains bounded and preserves the exact selected source.
- Extractor Python-package updates activate at the next process launch after compatibility checks. Native runtime updates require a new app build.
- Supported codec/container/Photos combinations are bounded. Arbitrary encoders and HDR-to-SDR transforms are unavailable. Player apps choose whether to display embedded covers; video covers currently require MP4.
- Authenticated public-media extraction is covered separately from account-only media. Account-only access, alternate sideloading signatures and broad device/OS combinations need their own verification.
- Simulator tests do not prove physical-device scheduling, Photos/provider behavior, energy usage or throughput. Background completion is best effort.

See [Development](Development.md) for repeatable verification and [Signing](Signing.md) for installation requirements.
