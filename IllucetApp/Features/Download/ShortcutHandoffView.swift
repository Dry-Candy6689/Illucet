import SwiftUI

struct ShortcutHandoffView: View {
    @EnvironmentObject private var model: IllucetAppModel
    @Environment(\.dismiss) private var dismiss
    let handoff: ShortcutHandoff
    @State private var starting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(handoff.reason)
                    Text(handoff.request.url.absoluteString).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if model.settings.shortcutPreferences.behavior == .ask {
                        Button(starting ? "Preparing…" : "Download now") {
                            starting = true
                            Task {
                                // This choice applies only to this invocation.
                                do {
                                    let result = try await model.submitShortcut(handoff.request, behaviorOverride: .download)
                                    starting = false
                                    switch result {
                                    case .admitted:
                                        dismiss()
                                        model.selectedTab = .queue
                                    case let .foreground(next): model.shortcutHandoff = next
                                    }
                                } catch {
                                    starting = false
                                    errorMessage = error.localizedDescription
                                }
                            }
                        }.disabled(starting)
                    }
                    Button("Open download options") { model.requestShortcutOptions(handoff) }
                        .disabled(!model.canPresentShortcutOptions || starting)
                    if !model.canPresentShortcutOptions {
                        Text("Finish the current setup or download choice first. This link stays in Saved shared links.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Download with Illucet")
            .alert("Couldn’t start download", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
            .toolbar {
                ToolbarItem(placement: .principal) { brandedText("Download with Illucet").font(.headline) }
                ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
            }
        }
    }
}
