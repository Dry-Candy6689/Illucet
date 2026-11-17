import SwiftUI

struct SharedLinkChoiceView: View {
    @EnvironmentObject private var model: IllucetAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rememberChoice = true

    var body: some View {
        NavigationStack {
            List {
                Section("Shared link") {
                    Text(model.pendingSharedLink?.absoluteString ?? "").textSelection(.enabled)
                    if !model.URLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Choosing an action replaces the current URL draft. Your queued downloads are kept.").font(.caption)
                    }
                }
                Section {
                    Toggle("Remember my choice", isOn: $rememberChoice)
                        .accessibilityIdentifier("sharing.rememberChoice")
                    ForEach(SharedLinkBehavior.allCases.filter { $0 != .ask }) { behavior in
                        Button(behavior.rawValue) {
                            model.applySharedLinkBehavior(behavior, rememberChoice: rememberChoice)
                        }
                            .disabled(model.isAnalyzing)
                    }
                } footer: {
                    brandedText("Set the Download with Illucet shortcut’s action in Settings → Sharing & Shortcuts. A missing or incompatible preset opens download options. Collections open their selection screen.")
                }
            }
            .navigationTitle("Open shared link")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Keep current draft") { dismiss() }
            } }
        }
    }
}
