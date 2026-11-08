import SwiftUI
import UIKit

struct SponsorBlockDefaultsView: View {
    @EnvironmentObject private var model: IllucetAppModel
    @State private var showsHelp = false

    var body: some View {
        Form {
            Section {
                SponsorBlockPolicyControls(policy: policy, showsExplanations: false)
            } header: {
                Text("New downloads")
            }
        }
        .settingsFormBackground()
        .navigationTitle("SponsorBlock")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsHelp = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("About SponsorBlock")
                    .accessibilityIdentifier("settings.sponsorblock.info")
            }
        }
        .sheet(isPresented: $showsHelp) {
            NavigationStack {
                List {
                    Text("These defaults apply to new downloads. Presets and existing downloads keep their own choices.")
                    Text("Remove cuts a segment; Mark as Chapter adds a marker; Off leaves it untouched. Filler defaults to Off.")
                    brandedText("Lookup sends a four-character video-ID hash prefix to SponsorBlock. Illucet checks the exact match locally.")
                }
                .navigationTitle("About SponsorBlock")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsHelp = false } } }
            }
        }
    }

    private var policy: Binding<SponsorBlockPolicy> {
        Binding(
            get: { model.settings.sponsorBlock },
            set: { value in
                var settings = model.settings
                settings.sponsorBlock = value
                model.settings = settings
            }
        )
    }
}

private struct SettingsFormBackground: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            IllucetBackground()
            content
                .scrollContentBackground(.hidden)
                .illucetContentWidth()
        }
    }
}

extension View {
    func settingsFormBackground() -> some View {
        modifier(SettingsFormBackground())
    }
}
