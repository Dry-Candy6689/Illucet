import SwiftUI

/// Keep the name readable within ordinary English text: the serif capital I
/// has crossbars, while the two lowercase l characters remain distinct.
func brandedText(_ value: String) -> some View {
    BrandedText(value: value)
}

func brandedText(_ value: String, font: Font) -> Text {
    let parts = value.components(separatedBy: "Illucet")
    var result = Text(verbatim: parts[0])
    for part in parts.dropFirst() {
        result = result + Text("Illucet").font(font).fontDesign(.serif) + Text(verbatim: part)
    }
    return result
}

private struct BrandedText: View {
    let value: String
    @Environment(\.font) private var font

    var body: Text {
        // Form rows can supply their font after concatenation. Resolve it here
        // so their inherited font cannot erase the name's serif face.
        brandedText(value, font: font ?? .body)
    }
}
