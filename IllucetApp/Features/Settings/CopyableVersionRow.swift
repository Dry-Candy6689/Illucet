import SwiftUI
import UIKit

struct CopyableVersionRow: View {
    let title: String
    let version: String
    var footnote: String? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if typeSize.isAccessibilitySize {
                Text(title)
                versionValue
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                    Spacer(minLength: 12)
                    versionValue.multilineTextAlignment(.trailing)
                }
            }
            if let footnote { Text(footnote).font(.caption).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in copy() })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(copied ? "Copied" : version)
        .accessibilityHint("Long press to copy version")
        .accessibilityAction(named: "Copy version", copy)
        .animation(systemReduceMotion ? nil : .easeInOut(duration: 0.18), value: copied)
        .onDisappear { resetTask?.cancel(); copied = false }
        .onChange(of: version) { _, _ in resetTask?.cancel(); copied = false }
    }

    private var versionValue: some View {
        Group {
            if copied {
                Label("Copied", systemImage: "checkmark.circle.fill").foregroundStyle(IllucetTheme.success)
            } else {
                Text(version).monospaced().foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .transition(.opacity)
    }

    private func copy() {
        UIPasteboard.general.string = version
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        copied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
