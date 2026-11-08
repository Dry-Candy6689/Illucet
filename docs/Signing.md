# Signing and installation

The release IPA is unsigned. Use a sideloading tool with your own Apple account, or build and run from Xcode.

For Xcode builds, select your team for Illucet and its Live Activity extension. Both targets must use compatible provisioning and the shared App Group. The defaults are `com.local.illucet`, `com.local.illucet.activity` and `group.com.local.illucet`.

Store local overrides in ignored `Config/DeveloperSigning.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODE_SIGN_STYLE = Automatic
```

`Base.xcconfig` includes this file optionally. Never commit signing identities, profiles or account credentials. If changing bundle identifiers, update the app, extension, App Group and Shortcut together.

A sideloading tool must sign the app, extension and nested Python frameworks in the appropriate order. Free-account entitlements, signing validity and background capabilities depend on the signing method. Trust, Developer Mode and permission prompts require action on the device.

The downloadable IPA contains no personal provisioning profile. Builds made with your own credentials naturally contain your signing metadata.
