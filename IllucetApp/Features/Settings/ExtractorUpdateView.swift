import SwiftUI

struct ExtractorUpdateView: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    @State private var pendingDowngrade: ExtractorRelease?

    private var status: UpdateStatus { model.updateStatus }
    private var controlsLocked: Bool { model.extractorUpdateBusy || status.state == .staged }
    private var release: ExtractorRelease? {
        guard status.state == .updateAvailable,
              status.availableRelease?.channel == model.settings.updateChannel else { return nil }
        return status.availableRelease
    }

    var body: some View {
        Form {
            Section("Running versions") {
                HStack(spacing: 11) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.foregroundAccent)
                        .frame(width: 32, height: 32)
                        .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityHidden(true)
                    Text(status.activeChannel == nil ? "Bundled" : "Installed")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    if let channel = status.runningChannel {
                        Text(channel.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.foregroundAccent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(theme.accent.opacity(0.12), in: Capsule())
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Running profile")
                .accessibilityValue(status.activeProfileLabel)
                .accessibilityIdentifier("updates.activeProfile")

                CopyableVersionRow(title: "yt-dlp", version: status.activeYTDLPVersion)
                    .accessibilityIdentifier("updates.runningYTDLP")
                CopyableVersionRow(title: "EJS", version: status.activeEJSVersion)
                    .accessibilityIdentifier("updates.runningEJS")
            }

            Section {
                Picker("Channel", selection: Binding(
                    get: { model.settings.updateChannel },
                    set: { model.selectExtractorUpdateChannel($0) }
                )) {
                    ForEach(UpdateChannel.allCases) { Text($0.title).tag($0) }
                }
                .disabled(controlsLocked)
                .accessibilityIdentifier("updates.channel")
                Toggle("Automatic checks", isOn: $model.settings.automaticUpdateChecks)
                Button {
                    model.checkForUpdates()
                } label: {
                    Label("Check for updates", systemImage: "arrow.clockwise")
                }
                .disabled(controlsLocked)
                .accessibilityIdentifier("updates.check")
                if let release { releaseRow(release) }
                if let message = statusMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if model.extractorUpdateBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: statusIcon)
                                .foregroundStyle(statusColor)
                                .accessibilityHidden(true)
                        }
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("updates.status")
                }
            } header: {
                Text("Updates")
            } footer: {
                if let lastChecked = status.lastCheckedAt {
                    Text("Last checked \(lastChecked.formatted(date: .abbreviated, time: .shortened))")
                }
            }

            if status.previousYTDLPVersion != nil || status.activeChannel != nil || status.state == .staged {
                Section("Restore") {
                    if let previous = status.previousYTDLPVersion {
                        Button { model.restorePreviousExtractor() } label: {
                            restoreLabel("Restore previous version", version: previous, icon: "clock.arrow.circlepath")
                        }
                        .disabled(controlsLocked)
                        .accessibilityIdentifier("updates.restorePrevious")
                    }
                    if status.activeChannel != nil || status.state == .staged {
                        Button { model.resetExtractor() } label: {
                            restoreLabel("Restore bundled version", version: status.bundledYTDLPVersion,
                                         icon: "shippingbox")
                        }
                        .disabled(model.extractorUpdateBusy)
                        .accessibilityIdentifier("updates.rollback")
                    }
                }
            }
        }
        .settingsFormBackground()
        .navigationTitle("yt-dlp & EJS")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Switch to an older version?", isPresented: Binding(
            get: { pendingDowngrade != nil },
            set: { if !$0 { pendingDowngrade = nil } }
        ), presenting: pendingDowngrade) { offer in
            Button(actionTitle(offer)) { model.installUpdate(offer, confirmedOlderVersion: true) }
            Button("Cancel", role: .cancel) {}
        } message: { offer in
            Text("\(offer.channel.rawValue) \(offer.version) is older than your running version \(status.activeYTDLPVersion). It will take effect when you close and reopen Illucet.")
        }
    }

    private func releaseRow(_ offer: ExtractorRelease) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(offer.channel == status.runningChannel ? "Update available" : "Latest \(offer.channel.rawValue) release",
                  systemImage: "arrow.down.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.foregroundAccent)
            Text(offer.version)
                .font(.body.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("updates.availableVersion")
            Text("Released \(offer.publishedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if offer.isOlder(than: status) {
                Text("Older than the version you’re running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(actionTitle(offer)) {
                if offer.isOlder(than: status) { pendingDowngrade = offer }
                else { model.installUpdate(offer) }
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .accessibilityIdentifier("updates.install")
        }
        .padding(.vertical, 6)
    }

    private func actionTitle(_ release: ExtractorRelease) -> String {
        release.channel == status.runningChannel ? "Install update" : "Switch to \(release.channel.rawValue)"
    }

    private func restoreLabel(_ title: String, version: String, icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(version).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
    }

    private var statusMessage: String? {
        if status.state == .checking { return "Checking official releases…" }
        return status.message
    }

    private var statusIcon: String {
        switch status.state {
        case .current: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        case .staged: "arrow.clockwise.circle"
        default: "info.circle"
        }
    }

    private var statusColor: Color {
        switch status.state {
        case .current: IllucetTheme.success
        case .failed: IllucetTheme.warning
        case .staged: theme.foregroundAccent
        default: .secondary
        }
    }
}
