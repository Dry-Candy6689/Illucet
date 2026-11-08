import SwiftUI

enum SelectionItem: Hashable {
    case history(UUID), job(UUID), batch(UUID), batchItem(UUID, String)
}

struct InlineSelectionState: Equatable {
    var isActive = false
    var selected: Set<SelectionItem> = []
    var eligible: Set<SelectionItem> = []
    var allSelected: Bool { !eligible.isEmpty && selected == eligible }

    mutating func begin(_ item: SelectionItem) {
        guard eligible.contains(item) else { return }
        isActive = true
        selected.insert(item)
    }
    mutating func toggle(_ item: SelectionItem) {
        guard eligible.contains(item) else { return }
        if !selected.insert(item).inserted { selected.remove(item) }
    }
    mutating func update(_ items: Set<SelectionItem>) {
        eligible = items
        selected.formIntersection(items)
        if items.isEmpty { cancel() }
    }
    mutating func cancel() { isActive = false; selected = [] }
    mutating func selectAll() { selected = allSelected ? [] : eligible }
}

struct InlineSelectionBar: View {
    @Environment(\.illucetPalette) private var theme
    @Binding var selection: InlineSelectionState
    var working = false
    let delete: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            Button(selection.allSelected ? "Deselect all" : "Select all") { selection.selectAll() }
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("selection.selectAll")
            Button(selection.allSelected ? "Delete all" : "Delete", role: .destructive, action: delete)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(IllucetTheme.danger)
                .disabled(selection.selected.isEmpty)
                .accessibilityIdentifier("selection.delete")
            Button("Cancel") { selection.cancel() }
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("selection.cancel")
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.plain)
        .foregroundStyle(theme.foregroundAccent)
        .frame(maxWidth: 560, minHeight: 46)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .disabled(working)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selection.bar")
    }
}

private struct SelectableCard: ViewModifier {
    @Environment(\.illucetPalette) private var theme
    @Binding var selection: InlineSelectionState
    let item: SelectionItem
    private var eligible: Bool { selection.eligible.contains(item) }
    func body(content: Content) -> some View {
        content
            .overlay {
                if selection.isActive && eligible {
                    Color.clear.contentShape(RoundedRectangle(cornerRadius: 18))
                        .onTapGesture { selection.toggle(item) }
                }
                if selection.selected.contains(item) {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(theme.foregroundAccent, lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                if eligible { selection.begin(item) }
            })
            .accessibilityAddTraits(selection.selected.contains(item) ? .isSelected : [])
            .accessibilityAction(named: selection.isActive ? "Toggle selection" : "Select") {
                if selection.isActive { selection.toggle(item) } else { selection.begin(item) }
            }
    }
}

extension View {
    func selectableCard(_ item: SelectionItem, selection: Binding<InlineSelectionState>) -> some View {
        modifier(SelectableCard(selection: selection, item: item))
    }
}
