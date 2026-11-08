# Known limitations

- iOS controls background execution. Native transfers can continue independently; long processing, force quit, notifications and locked-device behavior depend on OS scheduling and signing capabilities. Reopening can continue eligible saved checkpoints.
- On iOS 26, Shortcuts have a short preparation window; if a download cannot start in time, the link is saved for continuation in Illucet. iOS 27 can request a longer intent execution window. Neither version guarantees uninterrupted background completion. See [Shortcut startup](BackgroundBehavior.md#shortcut-startup).
- HLS supports bounded VOD and ordinary manifest-supplied identity AES-128. DRM, SAMPLE-AES, session keys, encrypted byte ranges and ongoing live recording are unsupported. Expiry refresh remains bounded and preserves the exact selected source.
- Extractor Python-package updates activate at the next process launch after compatibility checks. Native runtime updates require a new app build.
- Supported codec/container/Photos combinations are bounded. Arbitrary encoders and HDR-to-SDR transforms are unavailable. Player apps choose whether to display embedded covers; video covers currently require MP4.
- Authenticated public-media extraction is covered separately from account-only media. Account-only access, alternate sideloading signatures and broad device/OS combinations need their own verification.
- Simulator tests do not prove physical-device scheduling, Photos/provider behavior, energy usage or throughput. Background completion is best effort.

See [Development](Development.md) for repeatable verification and [Signing](Signing.md) for installation requirements.
