import SwiftUI
import UIKit

struct AppearanceSettingsView: View {
    @Environment(\.illucetPalette) private var theme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var accentBinding: Binding<Color> {
        Binding(get: { theme.accent }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            model.settings.accentColor = AppAccentColor(red: Double(r), green: Double(g), blue: Double(b))
        })
    }

    @EnvironmentObject private var model: IllucetAppModel

    var body: some View {
        ScrollViewReader { pipScroll in
        Form {
            Section("Preview") {
                VStack(spacing: model.settings.cardDensity == .compact ? 8 : 12) {
                    HStack {
                        RoundedRectangle(cornerRadius: 8).fill(theme.accent)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.outline))
                            .frame(width: 36, height: 36)
                            .accessibilityLabel("Selected accent color")
                        Text("Your accent").font(.caption)
                        Spacer()
                        Text("Download").font(.subheadline.bold()).foregroundStyle(theme.actionText)
                            .padding(10).background(theme.actionFill, in: Capsule())
                            .overlay(Capsule().stroke(theme.outline))
                    }

                    DownloadCardDensityPreview(
                        title: "City Walk — 1080p",
                        stage: "Downloading video",
                        detail: "42% • 8.4 MB/s • ≈ 2 min left",
                        progress: 0.42,
                        systemImage: "video.fill",
                        density: model.settings.cardDensity
                    )
                    .accessibilityIdentifier("appearance.cardPreview")
                    .accessibilityValue(model.settings.cardDensity.rawValue)
                    DownloadCardDensityPreview(
                        title: "Studio Session",
                        stage: "Waiting for processing",
                        detail: "MP3 Audio • Illucet",
                        progress: nil,
                        systemImage: "waveform",
                        density: model.settings.cardDensity
                    )
                }
                .padding(.vertical, 5)
                .animation(
                    systemReduceMotion ? nil : .snappy,
                    value: model.settings.cardDensity
                )
            }
            Section("Theme") {
                Picker("Theme", selection: $model.settings.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        brandedText(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Picker(
                    "Download cards",
                    selection: $model.settings.cardDensity
                ) {
                    ForEach(CardDensity.allCases) { density in
                        brandedText(density.rawValue).tag(density)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearance.cardDensity")
            }
            Section("Color") {
                VStack(alignment: .leading, spacing: 16) {
                ColorPicker("Accent color", selection: accentBinding, supportsOpacity: false)
                    .accessibilityIdentifier("appearance.accent")
                Button("Reset color to default") { model.settings.accentColor = nil }
                    .disabled(model.settings.accentColor == nil)
                Toggle("Black / OLED background", isOn: Binding(
                    get: { model.settings.oledDarkBackground ?? false },
                    set: { model.settings.oledDarkBackground = $0 }))
                    .accessibilityIdentifier("appearance.oled")
                }
                .pipAnchor(.colors)
                .id(PipAnchor.colors)
            }
            Section("App icon") { AppIconPicker() }
            Section("Navigation") {
                Toggle("Tap tab to scroll to top", isOn: Binding(
                    get: { model.settings.tapTabToScrollToTop ?? true },
                    set: { model.settings.tapTabToScrollToTop = $0 }))
                    .accessibilityIdentifier("interface.tapTabToTop")
            }
        }
        .settingsFormBackground()
        .navigationTitle("Interface")
        .navigationBarBackButtonHidden(model.pipGuideStep != nil)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.pipGuideStep, initial: true) { _, step in
            guard step == .colors else { return }
            Task { @MainActor in
                await Task.yield()
                withAnimation(systemReduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    pipScroll.scrollTo(PipAnchor.colors, anchor: .bottom)
                }
            }
        }
        }
    }
}

private struct DownloadCardDensityPreview: View {
    @Environment(\.illucetPalette) private var theme
    let title: String
    let stage: String
    let detail: String
    let progress: Double?
    let systemImage: String
    let density: CardDensity

    var body: some View {
        HStack(spacing: density == .compact ? 9 : 12) {
            RoundedRectangle(cornerRadius: density == .compact ? 8 : 11)
                .fill(theme.accent.opacity(0.14))
                .frame(
                    width: density == .compact ? 42 : 56,
                    height: density == .compact ? 42 : 50
                )
                .overlay {
                    Image(systemName: systemImage)
                        .foregroundStyle(theme.foregroundAccent)
                }
            VStack(alignment: .leading, spacing: density == .compact ? 2 : 5) {
                HStack {
                    Text(title)
                        .font(
                            density == .compact
                                ? .caption.weight(.semibold)
                                : .subheadline.weight(.semibold)
                        )
                        .lineLimit(1)
                    Spacer()
                    Text(stage)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.foregroundAccent)
                        .lineLimit(1)
                }
                if let progress {
                    ProgressView(value: progress)
                        .tint(theme.foregroundAccent)
                }
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(density == .compact ? 9 : 13)
        .background(
            theme.raisedCard,
            in: RoundedRectangle(cornerRadius: 14)
        )
        .accessibilityElement(children: .combine)
    }
}

struct NotificationSettingsView: View {
    @EnvironmentObject private var model: IllucetAppModel

    var body: some View {
        Form {
            Section {
                Button {
                    model.requestNotifications()
                } label: {
                    Label(
                        "Request notification access",
                        systemImage: "bell.badge"
                    )
                }
                .accessibilityIdentifier("notifications.request")
                .pipAnchor(.notifications)
                Button {
                    if let URL = URL(
                        string: UIApplication.openSettingsURLString
                    ) {
                        UIApplication.shared.open(URL)
                    }
                } label: {
                    Label("Open iOS Settings", systemImage: "gear")
                }
            }
            Section("Events") {
                Toggle("Playlist complete", isOn: Binding(get: { model.settings.notifyPlaylistComplete ?? true },
                    set: { model.settings.notifyPlaylistComplete = $0 }))
                Toggle("Retries exhausted", isOn: Binding(get: { model.settings.notifyRetryExhausted ?? true },
                    set: { model.settings.notifyRetryExhausted = $0 }))
                Toggle(
                    "Download complete",
                    isOn: $model.settings.notifyDownloadComplete
                )
                Toggle(
                    "Processing complete",
                    isOn: $model.settings.notifyProcessingComplete
                )
                Toggle("Failure", isOn: $model.settings.notifyFailure)
                Toggle(
                    "Needs attention",
                    isOn: $model.settings.notifyNeedsAttention
                )
                Toggle(
                    "Low storage",
                    isOn: $model.settings.notifyLowStorage
                )
                Toggle(
                    "Updates available",
                    isOn: $model.settings.notifyUpdates
                )
            }
            Section("Live progress") {
                Toggle(
                    "Live Activities",
                    isOn: $model.settings.liveActivities
                )
                Text(
                    "Shows one active job on the Lock Screen and Dynamic Island when iOS allows it. Open its controls to pause eligible transfers or cancel in Illucet. Background processing is best effort and may need you to reopen the app."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .settingsFormBackground()
        .navigationTitle("Notifications")
        .navigationBarBackButtonHidden(model.pipGuideStep != nil)
        .navigationBarTitleDisplayMode(.inline)
    }
}
