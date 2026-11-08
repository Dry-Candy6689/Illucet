import AVKit
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum OutputDetailContext { case history, queue }

struct OutputDetailView: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    @Environment(\.dismiss) private var dismiss
    let record: HistoryRecord
    let context: OutputDetailContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copiedSource = false
    @State private var copyFeedbackID = UUID()
    @State private var confirmsRecordDelete = false
    @State private var confirmsFileDelete = false
    @State private var fileAccess: SavedOutputAccessSession?
    @State private var loadingAccess = true
    @State private var choosesSavedFolder = false
    @State private var accessError: String?
    @State private var savedThumbnail: UIImage?
    @State private var previewFailure: SavedOutputAccessFailure?

    var body: some View {
        NavigationStack {
            ZStack {
                IllucetBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        if loadingAccess && !record.ownedFileURLs.isEmpty {
                            ProgressView("Opening saved file…")
                        } else if record.isSubtitlesOnly {
                            subtitlesOnlyPreview
                        } else if record.isThumbnailOnly,
                           let image = savedThumbnail {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 360)
                                .clipShape(
                                    RoundedRectangle(cornerRadius: 18)
                                )
                                .accessibilityLabel(
                                    "Saved thumbnail preview"
                                )
                        } else if canPlay, let URL = existingFileURL {
                            OutputPlayer(URL: URL, fileAccess: fileAccess).id(fileAccess?.id)
                        } else {
                            playbackUnavailable
                        }
                        header
                        if needsFolderAccess {
                            Button("Choose saved folder") { choosesSavedFolder = true }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("output.reauthorize")
                        }
                        destinationOutcomes
                        if context == .queue { shareActions }
                        if let application = record.sponsorBlockApplication {
                            sponsorBlockDetails(application)
                        }
                        if record.isSubtitlesOnly {
                            subtitleOutputs
                        } else if let probe = record.probe {
                            probeSummary(probe)
                            streamDetails(probe)
                            if !probe.metadata.isEmpty {
                                metadataDetails(probe.metadata)
                            }
                            if !probe.chapters.isEmpty {
                                chapterDetails(probe.chapters)
                            }
                        } else {
                            noProbe
                        }
                        if let extras = record.metadataSidecars, extras.contains(where: { context == .history || $0.kind != nil }) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Extra files").font(.headline)
                                ForEach(extras, id: \.localURL) { extra in
                                    if context == .history {
                                        Text(extra.kind?.rawValue ?? "Thumbnail")
                                        Text(extra.localURL.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                                    } else if let kind = extra.kind, fileAccess?.urls[extra.localURL] != nil {
                                        SavedOutputShareButton(record: record, urls: [extra.localURL], title: kind.rawValue, access: fileAccess)
                                    }
                                }
                            }.illucetCard()
                        }
                        if context == .queue { actionGrid }
                        deletionActions
                    }
                    .padding(18)
                    .padding(.bottom, 30)
                    .illucetContentWidth()
                }
            }
            .navigationTitle("Output details")
            .task(id: record) { await loadFileAccess(record) }
            .fileImporter(isPresented: $choosesSavedFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case let .success(folder):
                    Task {
                        do { let updated = try await model.reauthorizeOutput(record, folder: folder); await loadFileAccess(updated) }
                        catch { accessError = "Access could not be restored. Choose the original saved folder." }
                    }
                case .failure: accessError = "The folder could not be opened. Try choosing it again."
                }
            }
            .alert("Saved folder access", isPresented: Binding(get: { accessError != nil }, set: { if !$0 { accessError = nil } })) {
                Button("OK", role: .cancel) { accessError = nil }
            } message: { Text(accessError ?? "") }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Delete this history record?",
                isPresented: $confirmsRecordDelete,
                titleVisibility: .visible
            ) {
                Button("Delete record", role: .destructive) {
                    model.deleteHistoryRecord(record)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The downloaded file will be kept.")
            }
            .confirmationDialog(
                record.isSubtitlesOnly
                    ? "Delete the downloaded subtitle files?"
                    : "Delete the downloaded file?",
                isPresented: $confirmsFileDelete,
                titleVisibility: .visible
            ) {
                Button("Delete file and record", role: .destructive) {
                    model.deleteHistoryFile(record)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    record.isSubtitlesOnly
                        ? "This removes every owned subtitle file from Illucet storage and cannot be undone."
                        : "This removes the file from Illucet storage and cannot be undone."
                )
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var destinationOutcomes: some View {
        if let receipts = record.publicationReceipts, !receipts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Save results").font(.headline)
                ForEach(receipts) { receipt in
                    Text(receipt.summary)
                    ForEach(receipt.fileURLs, id: \.self) { url in
                        Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if receipts.contains(where: { $0.failureCode == "photos_permission_denied" }) {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                if record.status != .completed,
                   record.errorMessage != ExportPublicationError.inputsUnavailable.localizedDescription,
                   receipts.allSatisfy({ $0.state != .outcomeUnknown && $0.state != .committing }),
                   model.jobs.contains(where: { $0.id == record.jobID && $0.pipelineCheckpoint?.publicationPlan != nil }) {
                    Button("Retry export") {
                        model.retryExport(record)
                        dismiss()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .illucetCard()
        } else if record.status == .failed, let error = record.errorMessage {
            Text(error).frame(maxWidth: .infinity, alignment: .leading).illucetCard()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(record.title)
                .font(.title3.bold())
            if let channel = record.channel {
                Text(channel)
                    .foregroundStyle(.secondary)
            }
            HStack {
                IllucetPill(
                    text: record.status.label,
                    color: record.status.tint(accent: theme.foregroundAccent)
                )
                IllucetPill(
                    text: record.effectiveOutputIdentity.rawValue,
                    color: IllucetTheme.violet
                )
                IllucetPill(
                    text: record.destination.rawValue,
                    color: theme.foregroundAccent
                )
            }
            .lineLimit(1)
            if record.savedToPhotos {
                Label(
                    record.photosAssetLocalIdentifiers?.count == 1
                        ? "Saved to Photos"
                        : "\(record.photosAssetLocalIdentifiers?.count ?? 0) items saved to Photos",
                    systemImage: "photo.on.rectangle.angled"
                )
                .font(.caption)
                .foregroundStyle(IllucetTheme.success)
            }
            if record.exportOutcome == .duplicateSkipped {
                Label(
                    "Skipped because the selected filename already existed",
                    systemImage: "forward.end"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .illucetCard()
    }

    private var playbackUnavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: record.status == .completed
                ? "play.slash"
                : "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(
                    record.status == .completed
                        ? IllucetTheme.warning
                        : IllucetTheme.danger
                )
            Text(
                unavailableMessage
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("history.playbackUnavailable")
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .illucetCard()
    }

    private func sponsorBlockDetails(
        _ application: SponsorBlockApplicationRecord
    ) -> some View {
        informationSection("SponsorBlock") {
            detailRow("Status", application.status.historyLabel)
            detailRow(
                "Requested mode",
                application.requestedRemovalMode.rawValue
            )
            if let actual = application.actualRemovalMode {
                detailRow("Applied mode", actual.rawValue)
            }
            if application.removedSegmentCount > 0 {
                detailRow(
                    "Removed segments",
                    "\(application.removedSegmentCount)"
                )
                detailRow(
                    "Removed duration",
                    application.removedDurationSeconds.conciseDuration
                )
            }
            if application.sponsorBlockChapterCount > 0 {
                detailRow(
                    "SponsorBlock chapters",
                    "\(application.sponsorBlockChapterCount)"
                )
            }
            if application.actualRemovalMode == .fastKeyframe,
               application.requestedRemovalRanges
                != application.actualRemovalRanges,
               !application.actualRemovalRanges.isEmpty {
                Text(
                    "Fast mode adjusted one or more requested boundaries to verified keyframes."
                )
                .font(.caption)
                .foregroundStyle(IllucetTheme.warning)
            }
        }
        .illucetCard()
        .accessibilityIdentifier("history.sponsorblock.result")
    }

    private func sponsorBlockSummary(
        _ application: SponsorBlockApplicationRecord
    ) -> String {
        switch application.status {
        case .applied:
            "Verified changes applied"
        case .fallback:
            "Unavailable — safely not applied"
        case .notApplied:
            "Requested — no matching changes"
        case .requested:
            "Requested — not yet verified"
        case .failed:
            "Not applied — job failed"
        case .cancelled:
            "Not applied — job cancelled"
        }
    }

    private var subtitlesOnlyPreview: some View {
        VStack(spacing: 12) {
            Image(systemName: EffectiveOutputIdentity.subtitlesOnly.systemImage)
                .font(.largeTitle)
                .foregroundStyle(theme.foregroundAccent)
            Text(
                record.status == .completed
                    ? "Verified subtitle files"
                    : "Subtitles Only request"
            )
            .font(.headline)
            Text("No video, audio, or media probe belongs to this request.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .illucetCard()
        .accessibilityIdentifier("history.subtitlesOnly.preview")
    }

    private var subtitleOutputs: some View {
        VStack(alignment: .leading, spacing: 12) {
            IllucetSectionHeader(
                title: "Subtitle outputs",
                subtitle: "Validated VTT or SRT files",
                systemImage: "checkmark.seal"
            )
            let records = record.subtitleSidecars ?? []
            if records.isEmpty {
                Text(
                    record.status == .completed
                        ? "No new files were retained for this completed request."
                        : "No subtitle files were published before the request ended."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                ForEach(Array(records.enumerated()), id: \.offset) {
                    _, sidecar in
                    detailRow(
                        sidecar.selection.automatic
                            ? "Automatic \(sidecar.selection.language)"
                            : "Manual \(sidecar.selection.language)",
                        sidecar.filename
                    )
                }
            }
        }
        .illucetCard()
        .accessibilityIdentifier("history.subtitlesOnly.outputs")
    }

    private func probeSummary(_ probe: MediaProbeResult) -> some View {
        informationSection("Verified output") {
            detailRow("Container", probe.formatNames.joined(separator: ", "))
            detailRow(
                "File size",
                probe.fileSize.formatted(.byteCount(style: .file))
            )
            detailRow(
                "Duration",
                probe.durationSeconds?.conciseDuration ?? "Unknown"
            )
            detailRow(
                "Bitrate",
                probe.bitRate.map { "\($0 / 1_000) kbps" } ?? "Unknown"
            )
            detailRow("Video streams", "\(probe.videoStreamCount)")
            detailRow("Audio streams", "\(probe.audioStreamCount)")
            detailRow("Subtitle streams", "\(probe.subtitleStreamCount)")
        }
        .illucetCard()
    }

    private func streamDetails(_ probe: MediaProbeResult) -> some View {
        informationSection("Streams") {
            ForEach(probe.streams, id: \.index) { stream in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Image(systemName: streamIcon(stream.kind))
                            .foregroundStyle(theme.foregroundAccent)
                        Text(
                            "\(stream.kind.rawValue.capitalized) #\(stream.index)"
                        )
                        .font(.subheadline.bold())
                        Spacer()
                        Text(stream.codecName ?? "Unknown codec")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if let video = stream.video {
                        detailRow(
                            "Dimensions",
                            "\(video.width) × \(video.height)"
                        )
                        detailRow(
                            "Frame rate",
                            video.averageFrameRate?.doubleValue.map {
                                String(format: "%.2f fps", $0)
                            } ?? "Unknown"
                        )
                        detailRow("Dynamic range", video.isHDR ? "HDR" : "SDR")
                    }
                    if let audio = stream.audio {
                        detailRow(
                            "Sample rate",
                            audio.sampleRate.map { "\($0) Hz" } ?? "Unknown"
                        )
                        detailRow(
                            "Channels",
                            audio.channelCount.map(String.init) ?? "Unknown"
                        )
                        detailRow(
                            "Layout",
                            audio.channelLayout ?? "Unknown"
                        )
                    }
                    if stream.disposition.attachedPicture {
                        detailRow("Artwork", "Attached picture")
                    }
                }
                .padding(12)
                .background(
                    theme.input,
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
        }
        .illucetCard()
    }

    private func metadataDetails(_ metadata: [String: String]) -> some View {
        informationSection("Metadata tags") {
            VStack(spacing: 8) {
                ForEach(metadata.keys.sorted(), id: \.self) { key in
                    detailRow(key, metadata[key] ?? "")
                }
            }
            .padding(.top, 10)
        }
        .illucetCard()
    }

    private func chapterDetails(_ chapters: [MediaChapter]) -> some View {
        informationSection("\(chapters.count) chapters") {
            VStack(spacing: 8) {
                ForEach(Array(chapters.enumerated()), id: \.offset) { _, chapter in
                    detailRow(
                        chapter.title,
                        chapter.startSeconds.conciseDuration
                    )
                }
            }
            .padding(.top, 10)
        }
        .illucetCard()
    }

    private var noProbe: some View {
        Label(
            record.isSubtitlesOnly
                ? "Subtitle files are validated directly and do not use the media probe."
                : record.isThumbnailOnly
                ? "The image was decoded and written in the selected format."
                : record.exportOutcome == .duplicateSkipped
                    ? "No new output was created."
                    : record.status == .completed
                ? "No probe record is available for this legacy output."
                : "Output verification did not complete.",
            systemImage: "waveform.badge.exclamationmark"
        )
        .foregroundStyle(.secondary)
        .illucetCard()
    }

    private var actionGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: 10
        ) {
            Button {
                model.redownload(record)
                dismiss()
            } label: {
                Label("Download again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("history.redownload")

            Button {
                UIPasteboard.general.url = URL(string: "https://www.youtube.com/watch?v=\(record.videoID)")
                copiedSource = true
                copyFeedbackID = UUID()
            } label: {
                ZStack {
                    Label("Copy source URL", systemImage: "link").opacity(copiedSource ? 0 : 1)
                    Label("Copied", systemImage: "checkmark").opacity(copiedSource ? 1 : 0)
                }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(copiedSource ? "Copied" : "Copy source URL")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("output.copySource")
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: copiedSource)
            .task(id: copyFeedbackID) {
                guard copiedSource else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                copiedSource = false
            }

        }
    }

    private var shareableURLs: [URL] {
        if record.isSubtitlesOnly {
            return (record.subtitleSidecars ?? []).compactMap(\.localURL)
                .filter { fileAccess?.urls[$0] != nil }
        }
        return record.fileURL.flatMap { fileAccess?.urls[$0] == nil ? nil : [$0] } ?? []
    }

    @ViewBuilder private var shareActions: some View {
        if !shareableURLs.isEmpty {
            if record.shareCompletionState == .failed || record.shareCompletionState == .unconfirmed {
                Button { model.retryShare(record); dismiss() } label: {
                    Label("Retry Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(theme.actionFill).foregroundStyle(theme.actionText)
            } else {
                SavedOutputShareButton(record: record, urls: shareableURLs, access: fileAccess)
                    .buttonStyle(.borderedProminent).tint(theme.actionFill).foregroundStyle(theme.actionText)
                    .accessibilityIdentifier("output.share")
            }
        } else if record.status == .completed && !needsFolderAccess {
            // This belongs to the output being inspected, never a global alert
            // that can outlive this sheet and surface over download configuration.
            Text(unavailableMessage).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("output.fileStatus")
        }
    }

    @ViewBuilder private func informationSection<Content: View>(
        _ title: String, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if context == .history {
            VStack(alignment: .leading, spacing: 11) {
                Text(title).font(.headline)
                content()
            }
        } else {
            DisclosureGroup(title) {
                VStack(alignment: .leading, spacing: 11, content: content).padding(.top, 10)
            }
            .accessibilityIdentifier("output.section." + title)
        }
    }

    private var deletionActions: some View {
        VStack(spacing: 10) {
            Button("Delete history record", role: .destructive) {
                confirmsRecordDelete = true
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.bordered)
            if context == .queue, !record.ownedFileURLs.isEmpty {
                Button(
                    record.isSubtitlesOnly
                        ? "Delete downloaded subtitle files"
                        : "Delete downloaded file",
                    role: .destructive
                ) {
                    confirmsFileDelete = true
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.bordered)
            }
        }
    }

    private var canPlay: Bool {
        guard record.status == .completed, let URL = existingFileURL else {
            return false
        }
        return ["mp4", "mov", "m4v", "m4a", "mp3"].contains(
                URL.pathExtension.lowercased()
            )
    }

    private var existingFileURL: URL? {
        record.fileURL.flatMap { fileAccess?.urls[$0] }
    }

    private var needsFolderAccess: Bool {
        previewFailure == .authorizationRequired || fileAccess?.failures.values.contains(.authorizationRequired) == true
    }

    private func loadFileAccess(_ record: HistoryRecord) async {
        loadingAccess = true
        let resolver = model.outputResolver, bookmark = model.outputFolderBookmark
        let opened = await Task.detached {
            let session = resolver.open(record, fallbackBookmark: bookmark)
            var data: Data?, failure: SavedOutputAccessFailure?
            if record.isThumbnailOnly, let original = record.fileURL, session.urls[original] != nil {
                do { data = try session.read(original) { try Data(contentsOf: $0) } }
                catch {
                    failure = (error as? SavedOutputAccessFailure) ?? .unavailable
                }
            }
            return (session, data, failure)
        }.value
        guard !Task.isCancelled else { return }
        fileAccess = opened.0
        savedThumbnail = opened.1.flatMap(UIImage.init(data:))
        previewFailure = opened.2
        loadingAccess = false
    }

    private var unavailableMessage: String {
        if needsFolderAccess { return SavedOutputAccessFailure.authorizationRequired.localizedDescription }
        if record.savedToPhotos && record.destination == .photos {
            return record.isThumbnailOnly
                ? "The thumbnail was saved to Photos. No Files copy was requested."
                : "The verified media was saved to Photos. No Files copy was requested."
        }
        switch record.exportOutcome {
        case .duplicateSkipped:
            return "Illucet skipped this item because an output with the selected filename already existed."
        case .shared:
            return "The share sheet completed. Share-only output is removed afterward."
        case .shareCancelled:
            return "Sharing was cancelled. The download remains recorded as completed."
        case .shareUnconfirmed:
            return "Sharing ended without a confirmed result. Check the destination before sharing again."
        case .shareFailed:
            return record.shareErrorMessage
                ?? "Sharing did not finish. The staged file is available to retry."
        case .sharePending:
            return "The output is waiting for the share sheet to finish."
        default:
            if let failure = previewFailure ?? record.fileURL.flatMap({ fileAccess?.failures[$0] }) {
                return failure.localizedDescription
            }
            if record.status == .completed,
               existingFileURL != nil,
               record.probe != nil,
               !record.isThumbnailOnly,
               !record.isSubtitlesOnly,
               !canPlay {
                return "This downloaded file is valid. Apple’s built-in player does not support this output’s container or codec. A compatible app may be able to open it."
            }
            return record.status == .completed
                ? (existingFileURL == nil ? "The saved file is unavailable at its recorded location. You can download it again from Queue." : "Apple playback isn’t available for this output here.")
                : record.errorMessage ?? "No playable output was produced."
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 14)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private func streamIcon(_ kind: MediaStreamKind) -> String {
        switch kind {
        case .video: "video"
        case .audio: "waveform"
        case .subtitle: "captions.bubble"
        case .attachment: "paperclip"
        case .data: "doc.binary"
        case .unknown: "questionmark"
        }
    }
}

private extension SponsorBlockApplicationStatus {
    var historyLabel: String {
        switch self {
        case .requested: "Requested"
        case .applied: "Applied"
        case .notApplied: "Not applied"
        case .fallback: "Unavailable fallback"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
