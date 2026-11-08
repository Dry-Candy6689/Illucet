import SwiftUI

struct BatchQueueCard: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    let batch: DownloadBatch
    let jobs: [DownloadJob]

    @State private var isExpanded = true
    @State private var confirmsCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Button {
                withAnimation(.snappy) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 5) {
                        Text(batch.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                        HStack(spacing: 7) {
                            IllucetPill(
                                text: batch.state.label,
                                color: batch.state.tint(accent: theme.foregroundAccent)
                            )
                            Text(
                                "\(batch.progress.completedItems + batch.progress.failedItems + batch.progress.skippedItems) of \(batch.progress.totalItems)"
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(
                        systemName: isExpanded
                            ? "chevron.up"
                            : "chevron.down"
                    )
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .selectableCard(.batch(batch.id), selection: $model.queueSelection)

            progress

            if let error = batch.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(IllucetTheme.warning)
                    .lineLimit(3)
            }

            packageStatus

            if isExpanded {
                Divider().opacity(0.55)
                VStack(spacing: 11) {
                    ForEach(visibleItems) { item in
                        BatchItemRow(
                            batch: batch,
                            item: item,
                            job: jobs.first { $0.id == item.jobID }
                        )
                        .environmentObject(model)
                        if item.id != visibleItems.last?.id {
                            Divider().opacity(0.35)
                        }
                    }
                    if visibleItems.isEmpty {
                        Label(
                            "Completed items cleared from the queue",
                            systemImage: "checkmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if canClearCompletedItems {
                        Button {
                            model.clearCompletedItems(in: batch)
                        } label: {
                            Label(
                                "Clear completed items",
                                systemImage: "checkmark.circle.badge.xmark"
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(
                            "queue.batch.\(batch.id.uuidString).clearCompleted"
                        )
                    }
                }
            }

            controls
        }
        .illucetCard(padding: 14)
        .overlay {
            if model.queueSelection.selected.contains(.batch(batch.id)) {
                RoundedRectangle(cornerRadius: 18).strokeBorder(theme.foregroundAccent, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "queue.batch.\(batch.id.uuidString)"
        )
        .confirmationDialog(
            "Cancel “\(batch.title)”?",
            isPresented: $confirmsCancel,
            titleVisibility: .visible
        ) {
            Button("Cancel batch", role: .destructive) {
                model.cancel(batch)
            }
            Button("Keep batch", role: .cancel) {}
        } message: {
            Text(
                "Unfinished child jobs will be cancelled. Completed files remain available."
            )
        }
    }

    @ViewBuilder
    private var packageStatus: some View {
        if batch.destinationStructure == .zipArchive {
            if model.isPackaging(batch) {
                HStack(spacing: 9) {
                    ProgressView()
                    Text("Creating final ZIP package…")
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(theme.foregroundAccent)
                .accessibilityIdentifier(
                    "queue.batch.\(batch.id.uuidString).packaging"
                )
            } else if let error = batch.packageErrorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        error,
                        systemImage: "archivebox.badge.xmark"
                    )
                    .font(.caption)
                    .foregroundStyle(IllucetTheme.warning)
                    Button {
                        model.retryPackage(for: batch)
                    } label: {
                        Label("Retry ZIP", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier(
                        "queue.batch.\(batch.id.uuidString).retryZip"
                    )
                }
            } else if let URL = batch.packageURL {
                HStack {
                    Label(
                        URL.lastPathComponent,
                        systemImage: "archivebox.fill"
                    )
                    .font(.caption)
                    .lineLimit(1)
                    Spacer()
                    ShareLink(item: URL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share ZIP package")
                }
                .foregroundStyle(IllucetTheme.success)
            } else if batch.state == .completedWithFailures
                        || batch.state == .failed {
                Label(
                    "Retry failed items before the final ZIP can be created.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(IllucetTheme.warning)
            } else if batch.state.isTerminal {
                Label(
                    "ZIP packaging is waiting to start.",
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var thumbnail: some View {
        AsyncImage(url: batch.thumbnailURL) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    theme.raisedCard
                    Image(systemName: "rectangle.stack.fill")
                        .foregroundStyle(theme.foregroundAccent)
                }
            }
        }
        .frame(width: 82, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private var visibleItems: [DownloadBatchItem] {
        batch.items.filter { $0.isDismissedFromQueue != true }
    }

    private var canClearCompletedItems: Bool {
        let packageAllowsRemoval =
            batch.destinationStructure != .zipArchive
                || batch.packageURL != nil
        return packageAllowsRemoval && batch.items.contains {
            $0.state == .completed && $0.isDismissedFromQueue != true
        }
    }

    private var progress: some View {
        VStack(spacing: 8) {
            HStack {
                Text(batch.destinationStructure.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(batch.state.tint(accent: theme.foregroundAccent))
                Spacer()
                if let fraction = batch.progress.overallFraction {
                    Text(
                        fraction,
                        format: .percent.precision(.fractionLength(0))
                    )
                    .font(.caption.monospacedDigit().weight(.semibold))
                }
            }
            ProgressView(value: batch.progress.overallFraction)
                .tint(batch.state == .completed ? theme.foregroundAccent : batch.state.tint(accent: theme.foregroundAccent))
                .accessibilityLabel("Batch progress")
            HStack(spacing: 9) {
                if batch.progress.bytesDownloaded > 0 {
                    Text(
                        batch.progress.bytesDownloaded.formatted(
                            .byteCount(style: .file)
                        )
                    )
                }
                if batch.progress.failedItems > 0 {
                    Text("\(batch.progress.failedItems) failed")
                        .foregroundStyle(IllucetTheme.warning)
                }
                if batch.progress.skippedItems > 0 {
                    Text("\(batch.progress.skippedItems) skipped")
                }
                Spacer()
                brandedText(batch.configuration.effectiveOutputIdentity.rawValue)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 9) {
            switch batch.state {
            case .paused:
                batchButton("Resume", "play.fill") {
                    model.resume(batch)
                }
                batchButton(
                    "Cancel",
                    "xmark",
                    role: .destructive
                ) {
                    confirmsCancel = true
                }
            case .preparing, .queued, .running, .needsAttention:
                batchButton("Pause", "pause.fill") {
                    model.pause(batch)
                }
                batchButton(
                    "Cancel",
                    "xmark",
                    role: .destructive
                ) {
                    confirmsCancel = true
                }
            case .failed, .completedWithFailures:
                batchButton("Retry failed", "arrow.clockwise") {
                    model.retryFailed(in: batch)
                }
                .disabled(!batch.items.contains { $0.isDismissedFromQueue != true && ($0.state == .failed || $0.state == .needsAttention || $0.errorCode == "stopped_after_failure") })
                batchButton("Remove", "trash", role: .destructive) {
                    model.remove(batch)
                }
            case .cancelled:
                batchButton("Remove", "trash", role: .destructive) {
                    model.remove(batch)
                }
            case .completed:
                batchButton("Remove", "trash", role: .destructive) {
                    model.remove(batch)
                }
            }
        }
    }

    private func batchButton(
        _ title: String,
        _ image: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: image)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier(
            "queue.batch.\(batch.id.uuidString).\(title.lowercased())"
        )
    }
}

private struct BatchItemRow: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    let batch: DownloadBatch
    let item: DownloadBatchItem
    let job: DownloadJob?

    var body: some View {
        HStack(spacing: 10) {
            Text(
                String(
                    format: "%0\(batch.filenameIndexWidth)d",
                    item.playlistIndex
                )
            )
            .font(.caption.monospacedDigit().bold())
            .foregroundStyle(.secondary)
            .frame(width: 28)

            Button {
                if let job {
                    model.selectedJob = job
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(item.state.label)
                            .foregroundStyle(item.state.tint(accent: theme.foregroundAccent))
                        if let job, !job.state.isTerminal {
                            brandedText(job.stage.rawValue)
                        }
                        if let fraction = job.flatMap({ JobStatusPresentation(job: $0).fraction }) {
                            Text(
                                fraction,
                                format: .percent.precision(
                                    .fractionLength(0)
                                )
                            )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(job == nil)

            if !item.state.isTerminal {
                Button {
                    model.skip(item, in: batch)
                } label: {
                    Image(systemName: "forward.end")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .accessibilityLabel("Skip \(item.title)")
                .accessibilityIdentifier(
                    "queue.batch.item.\(item.id).skip"
                )
            } else {
                Image(systemName: item.state.systemImage)
                    .foregroundStyle(item.state.tint(accent: theme.foregroundAccent))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "queue.batch.item.\(item.id)"
        )
        .selectableCard(batch.state.isTerminal ? .batch(batch.id) : .batchItem(batch.id, item.id), selection: $model.queueSelection)
    }
}

struct DownloadArchiveView: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                IllucetBackground()
                if model.downloadArchive.isEmpty {
                    ContentUnavailableView {
                        Label(
                            "Playlist Archive is empty",
                            systemImage: "checkmark.rectangle.stack"
                        )
                    } description: {
                        Text(
                            "Completed playlist items appear here when archive skipping is enabled."
                        )
                    }
                } else {
                    List {
                        Section {
                            ForEach(orderedEntries) { entry in
                                archiveRow(entry)
                                    .listRowBackground(
                                        theme.card
                                    )
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            model.removeArchiveEntry(
                                                entry
                                            )
                                        } label: {
                                            Label(
                                                "Remove",
                                                systemImage: "trash"
                                            )
                                        }
                                    }
                            }
                        } footer: {
                            Text(
                                "Removing an archive entry does not delete its media or history."
                            )
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Playlist Archive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("archive.sheet")
    }

    private var orderedEntries: [DownloadArchiveEntry] {
        model.downloadArchive.sorted {
            $0.completedAt > $1.completedAt
        }
    }

    private func archiveRow(
        _ entry: DownloadArchiveEntry
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(IllucetTheme.success)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.videoID)
                    .font(.subheadline.monospaced().weight(.semibold))
                Text(
                    "\(entry.site.capitalized) • \(entry.completedAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                model.removeArchiveEntry(entry)
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Remove \(entry.videoID) from archive")
            .accessibilityIdentifier(
                "archive.remove.\(entry.videoID)"
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("archive.entry.\(entry.videoID)")
    }
}

extension DownloadBatchState {
    var label: String {
        switch self {
        case .preparing: "Preparing"
        case .queued: "Queued"
        case .running: "Running"
        case .paused: "Paused"
        case .needsAttention: "Needs attention"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .completed: "Complete"
        case .completedWithFailures: "Complete with issues"
        }
    }

    func tint(accent: Color) -> Color {
        switch self {
        case .completed: IllucetTheme.success
        case .failed, .cancelled: IllucetTheme.danger
        case .completedWithFailures, .needsAttention:
            IllucetTheme.warning
        case .running: accent
        case .paused: IllucetTheme.warning
        case .preparing, .queued: .secondary
        }
    }
}

extension DownloadBatchItemState {
    var label: String {
        switch self {
        case .pendingAnalysis: "Waiting for analysis"
        case .analyzing: "Analyzing"
        case .queued: "Queued"
        case .running: "Running"
        case .paused: "Paused"
        case .needsAttention: "Needs attention"
        case .archivedSkipped: "Already downloaded"
        case .skipped: "Skipped"
        case .unavailable: "Unavailable"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .completed: "Complete"
        }
    }

    func tint(accent: Color) -> Color {
        switch self {
        case .completed: IllucetTheme.success
        case .failed, .cancelled, .unavailable: IllucetTheme.danger
        case .needsAttention: IllucetTheme.warning
        case .running, .analyzing: accent
        case .paused: IllucetTheme.warning
        case .archivedSkipped, .skipped, .pendingAnalysis, .queued:
            .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .completed: "checkmark.circle.fill"
        case .failed, .unavailable: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .archivedSkipped: "checkmark.rectangle.stack"
        case .skipped: "forward.end.fill"
        case .needsAttention: "exclamationmark.circle.fill"
        case .paused: "pause.circle"
        case .running, .analyzing: "arrow.down.circle"
        case .pendingAnalysis, .queued: "clock"
        }
    }
}
