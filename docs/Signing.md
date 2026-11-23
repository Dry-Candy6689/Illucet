# Signing and installation

The release IPA is unsigned. Use a sideloading tool with your own Apple account, or build and run from Xcode.

## SideStore and AltStore Classic

1. Set up [SideStore](https://docs.sidestore.io/) or [AltStore Classic](https://faq.altstore.io/altstore-classic) on an iPhone or iPad running iOS or iPadOS 26 or later.
2. In **Sources → +**, paste `https://github.com/Dry-Candy6689/Illucet/releases/latest/download/illucet-source.json` and add the source.
3. Open the Illucet listing and tap **Free**. The store downloads the unsigned IPA and uses your Apple account to sign it. Use the store to install updates as new releases become available and refresh signing when required.

The feed and IPA are public GitHub downloads. This source uses Classic sideloading. AltStore PAL uses a separate distribution format for notarized apps.

## Xcode and manual signing

For Xcode builds, select your team for Illucet and its Live Activity extension. Both targets must use compatible provisioning and the shared App Group. The defaults are `com.local.illucet`, `com.local.illucet.activity` and `group.com.local.illucet`.

Store local overrides in ignored `Config/DeveloperSigning.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODE_SIGN_STYLE = Automatic
```

`Base.xcconfig` includes this file optionally. Never commit signing identities, profiles or account credentials. If changing bundle identifiers, update the app, extension, App Group and Shortcut together.

A sideloading tool must sign the app, extension and nested Python frameworks in the appropriate order. Free-account entitlements, signing validity and background capabilities depend on the signing method. Trust, Developer Mode and permission prompts require action on the device.

The downloadable IPA contains no personal provisioning profile. Builds made with your own credentials naturally contain your signing metadata.
