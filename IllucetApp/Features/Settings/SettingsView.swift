import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel

    var body: some View {
        NavigationStack(path: $model.settingsNavigationPath) {
            ZStack {
                IllucetBackground()
                ScrollViewReader { pipScroll in
                List {
                    Section("Accounts") {
                        NavigationLink(value: SettingsDestination.accounts) { settingsRow("YouTube accounts", "", "person.crop.circle.fill", .blue) }
                    }
                    .id("settings.root.top")

                    Section("Downloads") {
                        NavigationLink(value: SettingsDestination.downloads) {
                            settingsRow(
                                "Download defaults",
                                "Quality, destination, retries, and filenames",
                                "arrow.down.circle.fill",
                                theme.foregroundAccent
                            )
                        }
                        NavigationLink(value: SettingsDestination.conversion) {
                            settingsRow(
                                "Conversion",
                                "Stream copy, codecs, acceleration, and audio",
                                "gearshape.2.fill",
                                IllucetTheme.violet
                            )
                        }
                        NavigationLink(value: SettingsDestination.sponsorBlock) {
                            settingsRow(
                                "SponsorBlock",
                                "",
                                "SponsorBlockLogo",
                                IllucetTheme.warning
                            )
                        }
                    }

                    Section("Starting a download") {
                        NavigationLink(value: SettingsDestination.clipboard) { settingsRow("App opening & clipboard", "", "doc.on.clipboard.fill", .blue) }
                        NavigationLink(value: SettingsDestination.homeQuickStart) { settingsRow("Home Quick Start", "", "bolt.fill", IllucetTheme.warning) }
                            .id(PipAnchor.homeQuickStartRow)
                            .pipAnchor(.homeQuickStartRow)
                        NavigationLink(value: SettingsDestination.links) { settingsRow("Shortcuts", "", "square.and.arrow.up.fill", .blue) }
                    }

                    Section("Experience") {
                        NavigationLink(value: SettingsDestination.appearance) {
                            settingsRow(
                                "Interface",
                                "Theme, layout & navigation",
                                "circle.lefthalf.filled",
                                .purple
                            )
                        }
                        .id(PipAnchor.appearanceRow)
                        .pipAnchor(.appearanceRow)
                        NavigationLink(value: SettingsDestination.pip) {
                            settingsRow("PiP", "", "pawprint.fill", .purple)
                        }
                        .accessibilityIdentifier("settings.pip")
                        .id(PipAnchor.pipRow)
                        .pipAnchor(.pipRow)
                        NavigationLink(value: SettingsDestination.notifications) {
                            settingsRow(
                                "Notifications & Live Activities",
                                "Completion, failure, and progress",
                                "bell.badge.fill",
                                .orange
                            )
                        }
                        .id(PipAnchor.notificationsRow)
                        .pipAnchor(.notificationsRow)
                    }

                    Section("Files & components") {
                        NavigationLink(value: SettingsDestination.storage) {
                            settingsRow(
                                "Storage",
                                model.storageSummary,
                                "internaldrive.fill",
                                IllucetTheme.success
                            )
                        }
                        .accessibilityIdentifier("settings.storage")
                        NavigationLink(value: SettingsDestination.updates) {
                            settingsRow("yt-dlp & EJS", "", "shippingbox.fill", .cyan)
                        }
                        .accessibilityIdentifier("settings.updates")
                    }

                    Section("Preferences") {
                        NavigationLink(value: SettingsDestination.preferences) {
                            settingsRow("Save & restore preferences", "", "externaldrive.fill", theme.foregroundAccent)
                        }
                        .accessibilityIdentifier("settings.preferences")
                    }

                    Section("Support") {
                        NavigationLink(value: SettingsDestination.licenses) {
                            settingsRow(
                                "About & licenses",
                                "Runtime versions and acknowledgements",
                                "info.circle.fill",
                                .secondary
                            )
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .illucetContentWidth()
                .tabRootScroll(.settings, model: model) { pipScroll.scrollTo("settings.root.top", anchor: .top) }
                .task(id: model.pipNavigationAnchor) {
                    guard let anchor = model.pipNavigationAnchor, anchor.isSettingsRow else { return }
                    await Task.yield()
                    guard !Task.isCancelled, model.selectedTab == .settings,
                          model.settingsNavigationPath.isEmpty else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                        pipScroll.scrollTo(anchor, anchor: .center)
                    }
                }
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .accounts: AccountSettingsView()
                case .downloads: DownloadDefaultsView()
                case .conversion: ConversionDefaultsView()
                case .sponsorBlock: SponsorBlockDefaultsView()
                case .links: LinkSettingsView()
                case .clipboard: ClipboardSettingsView()
                case .homeQuickStart: HomeQuickStartSettingsView()
                case .appearance: AppearanceSettingsView()
                case .pip: PipSettingsView()
                case .notifications: NotificationSettingsView()
                case .storage: StorageSettingsView()
                case .updates: ExtractorUpdateView()
                case .licenses: LicensesView()
                case .preferences: PreferencesBackupView()
                }
            }
            .onChange(of: model.settings) { _, _ in
                model.settingsChanged()
            }
            .task { await model.refreshStorage() }
            .onChange(of: model.selectedTab) { _, tab in
                if tab == .settings { model.requestStorageRefresh() }
            }
        }
    }

    private func settingsRow(
        _ title: String,
        _ subtitle: String,
        _ image: String,
        _ color: Color
    ) -> some View {
        HStack(spacing: 12) {
            settingsIcon(image, color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func settingsIcon(_ image: String, _ color: Color) -> some View {
        Group {
            if image == "SponsorBlockLogo" {
                Image(image).resizable().scaledToFit().padding(4)
            } else {
                Image(systemName: image)
                .font(.body.weight(.medium))
                .foregroundStyle(color)
            }
        }
        .frame(width: 36, height: 36)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityHidden(true)
    }
}

// A selected Settings tab returns to its root without reconstructing the app model.
enum SettingsDestination: Hashable {
    case accounts, downloads, conversion, sponsorBlock, links, clipboard, homeQuickStart
    case appearance, pip, notifications, storage, updates, licenses, preferences
}

extension IllucetAppModel {
    func selectTab(_ tab: AppTab) {
        if selectedTab == tab {
            if tab == .settings, !settingsNavigationPath.isEmpty {
                settingsNavigationPath.removeAll()
                return
            }
            if settings.tapTabToScrollToTop ?? true {
                tabScrollStates[tab]?.scrollToTop(animated: true)
            }
            return
        }
        tabScrollStates[selectedTab]?.request = nil
        selectedTab = tab
    }
}
