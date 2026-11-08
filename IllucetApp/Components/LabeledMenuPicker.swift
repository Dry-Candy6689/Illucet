import SwiftUI

/// Keep the control's purpose visible outside its selected menu value.
struct LabeledMenuPicker<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    @ViewBuilder let content: () -> Content
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ title: String, selection: Binding<Selection>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._selection = selection
        self.content = content
    }

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                picker
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                picker
            }
        }
    }

    private var picker: some View {
        Picker(title, selection: $selection, content: content)
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize(horizontal: false, vertical: true)
    }
}
