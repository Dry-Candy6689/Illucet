# Illucet icon artwork

The 1.0.1 icons were recreated with the built-in `image_gen` tool from the user's
blue/orange/purple reference sheet and pink ribbon monogram. The default is blue.
The finished 1024-pixel assets live in `IllucetApp/Assets.xcassets/AppIcon*.appiconset`;
the eight explicit light/dark picker previews are `IconPreview*.imageset`.
Full-size masters are committed under `Design/Brand`; `Scripts/generate-app-icon.swift`
re-exports them without an image-generation request.
Square backgrounds are opaque; iOS applies the outer mask. Light/dark appearance
and system tinting follow iOS rather than the app's Interface theme.

## Prompt set

Base: Create one production square iOS app icon for Illucet, referencing the
Aurora light-mode icon. Preserve the sculpted luminous ribbon capital I: straight
center stem, two folded curved bars, cyan/periwinkle/violet highlights, premium
glass/satin shading, pale icy-blue background, balanced padding. Full-bleed square;
no rounded outer corners, captions, text, border, mockup or grid.

Each variant edits that master while preserving geometry, silhouette, position,
folds, camera and padding; change only palette, lighting and background:

- Blue dark: cyan/electric blue with violet highlights; midnight navy background.
- Orange light: orange/amber, cream highlights; pale warm ivory background.
- Orange dark: orange/amber, golden highlights; near-black burnt umber background.
- Purple light: violet/lavender, icy lilac highlights; pale lavender background.
- Purple dark: electric violet, lavender highlights; near-black aubergine background.
- Pink light: rose/magenta, peach-cream highlights; pale blush background.
- Pink dark: rose/magenta, warm cream highlights; near-black burgundy background.
- Tinted base: silver/white ribbon on black; neutral grayscale, no colored pixels.

Dark color variants use the corresponding light variant as their edit reference.
The neutral tinted master is shared across palettes. Output resizing and preview
generation are deterministic packaging steps using `sips`.
