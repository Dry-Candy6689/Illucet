import SwiftUI

struct DownloadScreenSettingsSection: View {
    @EnvironmentObject private var model: IllucetAppModel
    @Environment(\.illucetPalette) private var theme

    var body: some View {
        Section("Download screens") {
            Toggle("Skip video details", isOn: $model.settings.experience.skipVideoDetails)
                .listRowBackground(highlightBackground)
                .accessibilityIdentifier("flow.skipDetails")
            Toggle("Skip download review", isOn: $model.settings.experience.skipDownloadReview)
                .listRowBackground(highlightBackground)
                .accessibilityIdentifier("flow.skipReview")
            Button("Use recommended defaults") { model.applyRecommendedDownloadScreens() }
                .accessibilityIdentifier("flow.defaults")
        }
    }

    private var highlightBackground: some View {
        // Keep the same background view after fading. Switching to nil leaves
        // cached Form cells displaying their previous highlighted background.
        Color(uiColor: .secondarySystemGroupedBackground)
            .overlay {
                theme.foregroundAccent.opacity(model.highlightsDownloadScreens ? 0.18 : 0)
                    .animation(.easeOut(duration: 0.9), value: model.highlightsDownloadScreens)
            }
    }
}

extension IllucetAppModel {
    func applyRecommendedDownloadScreens() {
        settings.experience.skipVideoDetails = false
        settings.experience.skipDownloadReview = false
        settingsChanged()
    }
}
