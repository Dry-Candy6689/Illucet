import Network
import SwiftUI
import UIKit

@MainActor
private final class NetworkPathObserver: ObservableObject, @unchecked Sendable {
    @Published var label = "Checking…"
    @Published var expensive = false
    @Published var constrained = false
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.local.illucet.network-path")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.expensive = path.isExpensive
                self.constrained = path.isConstrained
                if path.status != .satisfied {
                    self.label = "Offline"
                } else if path.usesInterfaceType(.wifi) {
                    self.label = "Wi-Fi"
                } else if path.usesInterfaceType(.cellular) {
                    self.label = "Cellular"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.label = "Ethernet"
                } else {
                    self.label = "Connected"
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

struct DownloadConfirmationView: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var network = NetworkPathObserver()
    @State private var acknowledgedLongJob = false
    @State private var presentsDestinationSelection = false
    let metadata: MediaMetadata

    var body: some View {
        NavigationStack {
            ZStack {
                IllucetBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        titleCard
                        AccountBindingLabel(accountID: model.configuration.accountID)
                        outputSummary
                        resourceSummary
                        if !warnings.isEmpty {
                            warningCard
                        }
                        destinationCard
                        reliabilityNote
                        Button {
                            model.confirmDownload()
                        } label: {
                            Label(
                                isThumbnailOnly
                                    ? "Save thumbnail"
                                    : isSubtitlesOnly
                                        ? "Add subtitles to queue"
                                        : "Add to queue",
                                systemImage: isThumbnailOnly
                                    ? "photo.badge.arrow.down"
                                    : isSubtitlesOnly
                                        ? "captions.bubble.fill"
                                        : "arrow.down.circle.fill"
                            )
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(model.isStartingDownload || (requiresAcknowledgement && !acknowledgedLongJob))
                        .accessibilityIdentifier("confirmation.start")
                    }
                    .padding(18)
                    .padding(.bottom, 30)
                    .illucetContentWidth()
                }
            }
            .navigationTitle(
                isThumbnailOnly
                    ? "Ready to save thumbnail"
                    : isSubtitlesOnly
                        ? "Ready to save subtitles"
                        : "Ready to download"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") {
                        dismiss()
                        model.presentsConfiguration = true
                    }
                }
            }
        }
        .presentationDetents([.large])
        .confirmationDialog(
            "Choose destination",
            isPresented: $presentsDestinationSelection,
            titleVisibility: .visible
        ) {
            ForEach(confirmationDestinations) { destination in
                Button(destination.rawValue) {
                    model.changeConfirmationDestination(to: destination)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the destination will change. Other download options stay selected.")
        }
        .filesFolderImporter(model: model, source: .confirmation)
        .appAlertPresenter(model: model)
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        .accessibilityIdentifier("confirmation.sheet")
    }

    private var titleCard: some View {
        HStack(spacing: 13) {
            AsyncImage(url: metadata.thumbnails.last?.url) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    theme.raisedCard
                        .overlay(Image(systemName: "play.rectangle"))
                }
            }
            .frame(width: 102, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(metadata.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(metadata.channel ?? metadata.uploader ?? metadata.videoID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .illucetCard()
    }

    private var outputSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            IllucetSectionHeader(
                title: "Output",
                systemImage: "checklist"
            )
            if isSubtitlesOnly {
                summaryRow("Mode", outputIdentity.rawValue)
                summaryRow("Selected tracks", subtitleTrackSummary)
                summaryRow(
                    "Output format",
                    model.configuration.subtitleDelivery == .sidecarSRT
                        ? "SRT"
                        : "WebVTT"
                )
                summaryRow("Media streams", "None")
                summaryRow(
                    "Files",
                    "\(model.configuration.subtitleSelections?.count ?? 0) deterministic title-based files"
                )
            } else if isThumbnailOnly {
                summaryRow("Mode", outputIdentity.rawValue)
                summaryRow(
                    "Image format",
                    model.configuration.thumbnailFormat.rawValue
                )
                summaryRow(
                    "Crop",
                    model.configuration.cropArtworkSquare
                        ? "Square"
                        : "Preserve full image"
                )
                summaryRow("Media streams", "None")
            } else {
                summaryRow("Mode", outputIdentity.rawValue)
                summaryRow("Format IDs", formatIDs)
                summaryRow("Resolution", resolutionText)
                summaryRow("Frame rate", model.configuration.frameRate.rawValue)
                summaryRow(
                    "Video codec",
                    outputPlan?.expectedVideoCodec?.rawValue.uppercased()
                        ?? "None"
                )
                summaryRow("Audio", audioText)
                summaryRow(
                    "Container",
                    outputPlan.map {
                        "\($0.container.rawValue.uppercased()) (.\($0.fileExtension))"
                    } ?? "Unavailable"
                )
                summaryRow(
                    "Processing",
                    outputPlan?.needsConversion == true
                        ? "Conversion required"
                        : "Stream copy / merge"
                )
            }
            if !isSubtitlesOnly {
                summaryRow(
                    "Thumbnail",
                    model.configuration.thumbnailBehavior.displayName
                )
                summaryRow(
                    "Subtitles",
                    subtitleSummary
                )
                summaryRow("Final filename", filenamePreview)
            }
        }
        .illucetCard()
    }

    private var subtitleSummary: String {
        guard model.configuration.subtitleDelivery != .none else {
            return SubtitleDelivery.none.rawValue
        }
        let count = model.configuration.subtitleSelections?.count ?? 0
        return "\(model.configuration.subtitleDelivery.rawValue) • \(count) selected"
    }

    private var subtitleTrackSummary: String {
        let selections = model.configuration.subtitleSelections ?? []
        return selections.map {
            "\($0.language) \($0.automatic ? "automatic" : "manual")"
        }.joined(separator: ", ")
    }

    private var resourceSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            IllucetSectionHeader(
                title: "Before starting",
                systemImage: "gauge.with.dots.needle.bottom.50percent"
            )
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 12
            ) {
                metric(
                    "Download",
                    estimatedDownload,
                    "arrow.down"
                )
                metric(
                    "Temporary",
                    estimatedTemporary,
                    "externaldrive"
                )
                metric(
                    "Free space",
                    model.storage.availableBytes.formatted(
                        .byteCount(style: .file)
                    ),
                    "internaldrive"
                )
                metric("Network", network.label, "network")
                metric("Battery", batteryText, "battery.50percent")
                metric(
                    "Difficulty",
                    processingDifficulty,
                    "gauge.open.with.lines.needle.33percent"
                )
            }
            if network.expensive || network.constrained {
                Label(
                    network.constrained
                        ? "Low Data Mode is active."
                        : "This is an expensive network connection.",
                    systemImage: "antenna.radiowaves.left.and.right.slash"
                )
                .font(.caption)
                .foregroundStyle(IllucetTheme.warning)
            }
        }
        .illucetCard()
    }

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            IllucetSectionHeader(
                title: "Review this job",
                subtitle: "These conditions may make it take longer",
                systemImage: "exclamationmark.triangle"
            )
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(IllucetTheme.warning)
            }
            if requiresAcknowledgement {
                Toggle(
                    "I’m ready to start this demanding job",
                    isOn: $acknowledgedLongJob
                )
                .tint(IllucetTheme.warning)
                .accessibilityIdentifier("confirmation.acknowledge")
            }
        }
        .illucetCard()
    }

    private var destinationCard: some View {
        HStack(spacing: 13) {
            Image(systemName: model.configuration.destination.systemImage)
                .font(.title3)
                .foregroundStyle(theme.foregroundAccent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text("Destination")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                brandedText(model.configuration.destination.rawValue)
                    .font(.subheadline.weight(.semibold))
                if let filesFolderName = model.filesFolderName,
                   [
                       ExportDestination.filesFolder,
                       .filesAndPhotos,
                   ].contains(model.configuration.destination) {
                    Text(filesFolderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Change") {
                presentsDestinationSelection = true
            }
            .font(.subheadline.weight(.semibold))
        }
        .illucetCard()
    }

    private var confirmationDestinations: [ExportDestination] {
        ExportDestination.allCases.filter { destination in
            destination != .askEveryTime
                && (!isSubtitlesOnly || destination.supportsSubtitlesOnly)
        }
    }

    private var reliabilityNote: some View {
        Label {
            brandedText(isSubtitlesOnly
                ? "Illucet will retrieve and validate only the selected subtitle tracks, then publish the complete file set. No video, audio, or FFmpeg processing will run."
                : "This download or conversion may take a long time. Keep Illucet open for the most reliable result, connect to power when possible, and do not force-quit the app. Network transfer may continue in the background, but iOS can pause or stop merging and conversion.")
        } icon: { Image(systemName: "info.circle") }
        .font(.caption)
        .foregroundStyle(.secondary)
        .illucetCard()
        .accessibilityElement(children: .combine)
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 20)
            Text(value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private func metric(
        _ title: String,
        _ value: String,
        _ icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(theme.foregroundAccent)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            theme.input,
            in: RoundedRectangle(cornerRadius: 14)
        )
        .accessibilityElement(children: .combine)
    }

    private var selectedFormats: [MediaFormat] {
        metadata.formats.filter {
            model.configuration.selectedFormatIDs.contains($0.formatID)
        }
    }

    private var formatIDs: String {
        let IDs = model.configuration.selectedFormatIDs
        return IDs.isEmpty ? "Automatic" : IDs.joined(separator: " + ")
    }

    private var resolutionText: String {
        selectedFormats.compactMap(\.pResolution).max().map { "\($0)p" }
            ?? "Source"
    }

    private var audioText: String {
        guard let codec = outputPlan?.expectedAudioCodec else {
            return "None"
        }
        if let rate = outputPlan?.expectedAudioBitRate {
            return "\(codec.rawValue.uppercased()), \(rate / 1_000) kbps"
        }
        return codec.rawValue.uppercased()
    }

    private var filenamePreview: String {
        let stem = FilenameSystem.render(
            template: model.configuration.filenameTemplate,
            metadata: metadata,
            configuration: model.configuration,
            format: selectedFormats.first
        )
        if isThumbnailOnly {
            return "\(stem).\(thumbnailFileExtension)"
        }
        return outputPlan.map { "\(stem).\($0.fileExtension)" } ?? stem
    }

    private var estimatedDownload: String {
        if isSubtitlesOnly {
            return "Subtitle sizes unknown"
        }
        if isThumbnailOnly {
            return "Image size unknown"
        }
        return FormatSelection.estimatedDownloadBytes(
            configuration: model.configuration,
            metadata: metadata
        )?.formatted(.byteCount(style: .file)) ?? "Unknown"
    }

    private var estimatedTemporary: String {
        if isSubtitlesOnly {
            let count = model.configuration.subtitleSelections?.count ?? 0
            return "Up to \(max(1, count) * 4) MB"
        }
        if isThumbnailOnly {
            return "Up to 50 MB"
        }
        return FormatSelection.estimatedTemporaryBytes(
            configuration: model.configuration,
            metadata: metadata
        )?.formatted(.byteCount(style: .file)) ?? "Unknown"
    }

    private var processingDifficulty: String {
        if isSubtitlesOnly { return "Light" }
        guard outputPlan?.needsConversion == true else { return "Light" }
        let resolution = selectedFormats.compactMap(\.pResolution).max() ?? 0
        return resolution >= 2_160
            ? "Very high"
            : resolution >= 1_080 ? "High" : "Moderate"
    }

    private var batteryText: String {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return "Unknown" }
        return "\(Int(level * 100))%"
    }

    private var warnings: [String] {
        var values: [String] = []
        if let size = FormatSelection.estimatedDownloadBytes(
            configuration: model.configuration,
            metadata: metadata
        ), size > model.settings.largeDownloadWarningBytes {
            values.append(
                "Large download: \(size.formatted(.byteCount(style: .file)))"
            )
        }
        if (selectedFormats.compactMap(\.pResolution).max() ?? 0) >= 2_160 {
            values.append("4K or higher source")
        }
        if outputPlan?.needsConversion == true {
            values.append("CPU-heavy media conversion")
        }
        if UIDevice.current.batteryLevel >= 0,
           UIDevice.current.batteryLevel < 0.20 {
            values.append("Battery below 20%")
        }
        if network.expensive {
            values.append("Cellular or expensive network")
        }
        return values
    }

    private var requiresAcknowledgement: Bool {
        warnings.contains { warning in
            warning.contains("Large")
                || warning.contains("4K")
                || warning.contains("conversion")
        }
    }

    private var outputPlan: OutputPlan? {
        try? OutputCapabilityMatrix.makePlan(
            configuration: model.configuration,
            metadata: metadata
        )
    }

    private var isThumbnailOnly: Bool {
        outputIdentity == .thumbnailOnly
    }

    private var isSubtitlesOnly: Bool {
        outputIdentity == .subtitlesOnly
    }

    private var outputIdentity: EffectiveOutputIdentity {
        model.configuration.effectiveOutputIdentity
    }

    private var thumbnailFileExtension: String {
        switch model.configuration.thumbnailFormat {
        case .jpeg: "jpg"
        case .png: "png"
        case .webp: "webp"
        case .original:
            metadata.thumbnails.first(where: {
                $0.id == model.configuration.thumbnailID
            })?.url.pathExtension.nilIfEmpty
                ?? metadata.thumbnails.last?.url.pathExtension.nilIfEmpty
                ?? "jpg"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
