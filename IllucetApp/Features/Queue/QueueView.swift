import SwiftUI

private enum QueueDisplayOrder: String, CaseIterable, Identifiable {
    case newestFirst = "Newest first"
    case oldestFirst = "Oldest first"
    var id: String { rawValue }
}

struct QueueView: View {
    @EnvironmentObject private var model: IllucetAppModel
    @State private var confirmsCancelAll = false

    @State private var confirmsDeletion = false
    @State private var deleting = false
    @AppStorage("queue.displayOrder") private var displayOrder: QueueDisplayOrder = .newestFirst

    var body: some View {
        NavigationStack {
            ZStack {
                IllucetBackground()
                if model.batches.isEmpty && unbatchedJobs.isEmpty {
                    EmptyStateView(
                        systemImage: "tray",
                        title: "Queue is clear",
                        message: "Paste a link to begin, or jump to your saved Quick Start presets.",
                        actionTitle: "Paste Link",
                        action: model.openPasteFromEmptyState,
                        secondaryActionTitle: "Open Quick Start",
                        secondaryAction:
                            model.openQuickStartFromEmptyState,
                        accessibilityPrefix: "queue.empty"
                    )
                    .accessibilityIdentifier("queue.empty")
                } else {
                    ScrollViewReader { scroll in
                        List {
                            ForEach(displayedEntries) { entry in
                                Group {
                                    switch entry {
                                    case .job(let job):
                                        QueueJobCard(job: job).queueListRow()
                                    case .batch(let batch):
                                        BatchQueueCard(batch: batch, jobs: jobs(in: batch)).queueListRow()
                                    }
                                }
                                .id(entry.id)
                            }
                        }
                        .tabRootScroll(.queue, model: model) {
                            if let first = displayedEntries.first { scroll.scrollTo(first.id, anchor: .top) }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .illucetContentWidth()
                    }
                }
            }
            .navigationTitle("Queue")
            .onAppear {
                if UserDefaults.standard.string(forKey: "queue.displayOrder") == "Queue priority" {
                    UserDefaults.standard.set(QueueDisplayOrder.newestFirst.rawValue, forKey: "queue.displayOrder")
                    displayOrder = .newestFirst
                }
            }
            .onChange(of: model.queueSelectableItems, initial: true) { _, items in model.queueSelection.update(items) }
            .safeAreaInset(edge: .bottom, spacing: 8) {
                if model.queueSelection.isActive && model.selectedTab == .queue {
                    InlineSelectionBar(selection: $model.queueSelection, working: deleting) { confirmsDeletion = true }
                }
            }
            .confirmationDialog("Remove selected Queue entries?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
                Button("Delete entries", role: .destructive) {
                    deleting = true
                    Task {
                        await model.removeQueueSelection()
                        deleting = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Downloaded files and History are kept.") }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.presentsDownloadArchive = true
                    } label: {
                        Image(systemName: "checkmark.rectangle.stack")
                    }
                    .accessibilityLabel("Playlist Archive")
                    .accessibilityIdentifier("queue.archive")
                }
                if !model.batches.isEmpty || !unbatchedJobs.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Sort queue", selection: $displayOrder) {
                                ForEach(QueueDisplayOrder.allCases) { order in
                                    brandedText(order.rawValue).tag(order)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .accessibilityLabel("Sort queue")
                        .accessibilityValue(displayOrder.rawValue)
                        .accessibilityIdentifier("queue.sort")
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                model.pauseAll()
                            } label: {
                                Label("Pause all", systemImage: "pause.circle")
                            }
                            .disabled(!model.jobs.contains(where: \.canPause) && !model.batches.contains { !$0.state.isTerminal && $0.admissionPaused != true })
                            Button {
                                model.resumeAll()
                            } label: {
                                Label("Resume all", systemImage: "play.circle")
                            }
                            .disabled(!model.jobs.contains { $0.state == .paused } && !model.batches.contains { $0.admissionPaused == true || $0.state == .paused })
                            Button {
                                model.clearCompletedJobs()
                            } label: {
                                Label(
                                    "Clear completed",
                                    systemImage: "checkmark.circle"
                                )
                            }
                            Button(role: .destructive) {
                                confirmsCancelAll = true
                            } label: {
                                Label("Cancel all", systemImage: "xmark.circle")
                            }
                            .disabled(!model.hasCancellableWork)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Queue actions")
                        .accessibilityIdentifier("queue.actions")
                    }
                }
            }
            .confirmationDialog(
                "Cancel every active job?",
                isPresented: $confirmsCancelAll,
                titleVisibility: .visible
            ) {
                Button("Cancel all jobs", role: .destructive) {
                    model.cancelAll()
                }
                Button("Keep downloading", role: .cancel) {}
            }
        }
    }

    private var unbatchedJobs: [DownloadJob] {
        model.orderedJobs.filter { $0.batchMembership == nil }
    }

    private var displayedEntries: [QueueDisplayEntry] {
        BatchQueueOrdering.activeFirstEntries(jobs: model.jobs, batches: model.batches,
            packaging: model.packagingBatchIDs, newestFirst: displayOrder == .newestFirst)
    }

    private func jobs(in batch: DownloadBatch) -> [DownloadJob] {
        model.jobs.filter {
            $0.batchMembership?.batchID == batch.id
        }
    }
}

private extension View {
    func queueListRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(
                EdgeInsets(
                    top: 6,
                    leading: 16,
                    bottom: 6,
                    trailing: 16
                )
            )
    }
}

struct QueueJobCard: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    let job: DownloadJob
    @State private var confirmsCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Button {
                model.selectedJob = job
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 5) {
                        Text(job.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                        HStack {
                            IllucetPill(
                                text: job.isWaitingForTransferSlot || job.isWaitingForBackgroundTime ? "Waiting" : job.state.label,
                                color: job.state.tint(accent: theme.foregroundAccent)
                            )
                            brandedText(job.effectiveOutputIdentity.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !job.state.isTerminal || job.state == .completed {
                progressBlock
            }

            if let error = job.errorMessage,
               job.state == .failed || job.state == .needsAttention {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(IllucetTheme.warning)
                    .lineLimit(3)
            }

            controls
        }
        .illucetCard(padding: 14)
        .selectableCard(.job(job.id), selection: $model.queueSelection)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue.job.\(job.id.uuidString)")
        .confirmationDialog(
            "Cancel “\(job.title)”?",
            isPresented: $confirmsCancel,
            titleVisibility: .visible
        ) {
            Button("Cancel job", role: .destructive) {
                model.cancel(job)
            }
            Button("Keep job", role: .cancel) {}
        }
    }

    private var thumbnail: some View {
        AsyncImage(url: job.thumbnailURL) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    theme.raisedCard
                    Image(systemName: job.effectiveOutputIdentity.systemImage)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            "\(job.effectiveOutputIdentity.rawValue) output"
                        )
                        .accessibilityIdentifier(
                            "queue.job.\(job.id.uuidString).outputTypeIcon"
                        )
                }
            }
        }
        .frame(width: 82, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private var progressBlock: some View {
        VStack(spacing: 8) {
            HStack {
                Text(JobStatusPresentation(job: job).stage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(job.state.tint(accent: theme.foregroundAccent))
                    .accessibilityIdentifier(
                        "queue.job.\(job.id.uuidString).stage"
                    )
                Spacer()
                ZStack(alignment: .trailing) {
                    // Keep 9%, 10% and 100% from reflowing the adjacent stage label.
                    Text(1.0, format: .percent.precision(.fractionLength(0)))
                        .hidden().accessibilityHidden(true)
                    if let fraction = JobStatusPresentation(job: job).fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .accessibilityIdentifier("queue.job.\(job.id.uuidString).stagePercent")
                    } else {
                        Text("—").foregroundStyle(.secondary)
                            .accessibilityLabel("Progress unknown")
                    }
                }
                .font(.caption.monospacedDigit().weight(.semibold))
                .fixedSize()
            }
            if job.state == .running || job.state == .completed {
                ProgressView(value: JobStatusPresentation(job: job).fraction)
                    .tint(theme.foregroundAccent)
                    .accessibilityLabel("Current stage progress")
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
            }
            VStack(alignment: .leading, spacing: 4) {
                if job.stage.presentsTransferMetrics || job.isWaitingForTransferSlot {
                    HStack(spacing: 12) {
                        Text(job.progress.bytesDownloaded > 0
                            ? job.progress.bytesDownloaded.formatted(.byteCount(style: .file)) + totalBytesSuffix
                            : "—")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("queue.job.\(job.id.uuidString).transferBytes")
                        Text(JobStatusPresentation(job: job).speed ?? "—")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .accessibilityIdentifier("queue.job.\(job.id.uuidString).transferSpeed")
                    }
                }
                if job.state == .running && (job.stage.presentsTransferMetrics || job.stage.isProcessingWork) {
                    Text(JobStatusPresentation(job: job).remaining ?? "Time remaining unknown")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("queue.job.\(job.id.uuidString).remainingETA")
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .transaction { $0.animation = nil }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if horizontalSizeClass == .compact && (job.isWaitingForTransferSlot || [
            DownloadJobState.queued, .waitingForNetwork, .waitingForWiFi,
            .waitingForCellularApproval, .waitingForRetry, .waitingForPower
        ].contains(job.state)) {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    control("Pause", "pause.fill") { model.pause(job) }
                    control("Cancel", "xmark", role: .destructive) { confirmsCancel = true }
                }
                control("Prioritize", "arrow.up.to.line") { model.prioritize(job) }
            }
        } else {
            HStack(spacing: 10) {
                switch job.state {
                case .running:
                    if job.isWaitingForTransferSlot {
                        control("Prioritize", "arrow.up.to.line") { model.prioritize(job) }
                    }
                    if job.stage.supportsTransferPause {
                        control("Pause", "pause.fill") {
                            model.pause(job)
                        }
                    } else {
                        Label(
                            job.stage.isProcessingWork
                                ? "Processing can’t pause"
                                : job.stage.rawValue,
                            systemImage: "hourglass"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    }
                    control("Cancel", "xmark", role: .destructive) {
                        confirmsCancel = true
                    }
                case .paused:
                    control("Resume", "play.fill") {
                        model.resume(job)
                    }
                    control("Cancel", "xmark", role: .destructive) {
                        confirmsCancel = true
                    }
                case .queued, .waitingForNetwork, .waitingForWiFi,
                     .waitingForCellularApproval, .waitingForRetry,
                     .waitingForPower:
                    control("Pause", "pause.fill") { model.pause(job) }
                    control("Prioritize", "arrow.up.to.line") {
                        model.prioritize(job)
                    }
                    control("Cancel", "xmark", role: .destructive) {
                        confirmsCancel = true
                    }
                case .failed, .needsAttention, .cancelled:
                    if job.isAwaitingTransferCleanup {
                        control("Cancel", "xmark", role: .destructive) { confirmsCancel = true }
                    } else {
                        control("Retry", "arrow.clockwise") { model.retry(job) }
                    }
                    control("Details", "info.circle") {
                        model.selectedJob = job
                    }
                case .completed:
                    control("Details", "checkmark.circle") {
                        model.selectedJob = job
                    }
                    if let outputURL = job.outputURL {
                        SavedOutputShareButton(record: model.history.first { $0.jobID == job.id } ?? HistoryRecord(job: job), urls: [outputURL])
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func control(
        _ title: String,
        _ image: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: image)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier(
            "queue.job.\(job.id.uuidString).\(title.lowercased())"
        )
    }

    private var totalBytesSuffix: String {
        guard let total = job.progress.totalBytes else { return "" }
        return " / \(total.formatted(.byteCount(style: .file)))"
    }
}

struct JobDetailView: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    @Environment(\.dismiss) private var dismiss
    let job: DownloadJob

    private var current: DownloadJob {
        model.jobs.first(where: { $0.id == job.id }) ?? job
    }

    var body: some View {
        NavigationStack {
            ZStack {
                IllucetBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        header
                        if current.state != .completed { liveProgress }
                        technicalDetails
                        actions
                    }
                    .padding(18)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Job details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(current.title)
                .font(.title3.bold())
            if let channel = current.channel {
                Text(channel)
                    .foregroundStyle(.secondary)
            }
            HStack {
                IllucetPill(
                    text: current.isWaitingForTransferSlot || current.isWaitingForBackgroundTime ? "Waiting" : current.state.label,
                    color: current.state.tint(accent: theme.foregroundAccent)
                )
                IllucetPill(
                    text: current.effectiveOutputIdentity.rawValue,
                    color: IllucetTheme.violet
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .illucetCard()
    }

    private var liveProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            IllucetSectionHeader(
                title: JobStatusPresentation(job: current).stage,
                subtitle: current.progress.currentStream.map {
                    "Stream \($0)"
                },
                systemImage: "chart.line.uptrend.xyaxis"
            )
            if current.state == .running || current.state == .completed {
                ProgressView(value: JobStatusPresentation(job: current).fraction)
                    .tint(theme.foregroundAccent)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
            }
            if current.stage.presentsTransferMetrics || current.isWaitingForTransferSlot {
                detailRow(
                    "Downloaded",
                    current.progress.bytesDownloaded.formatted(
                        .byteCount(style: .file)
                    )
                )
                detailRow(
                    "Total",
                    current.progress.totalBytes?.formatted(
                        .byteCount(style: .file)
                    ) ?? "Unknown"
                )
                if current.stage.presentsTransferMetrics {
                    detailRow("Average speed", JobStatusPresentation(job: current).speed ?? "Unavailable")
                }
            }
            detailRow("Time remaining", JobStatusPresentation(job: current).remaining ?? "Unknown")
            detailRow(
                "Processing",
                current.progress.processingFraction.map {
                    $0.formatted(.percent.precision(.fractionLength(0)))
                } ?? "Not started"
            )
            detailRow(
                "Retries",
                "\(current.retryCount) of \(current.maximumRetries)"
            )
        }
        .illucetCard()
    }

    private var technicalDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            IllucetSectionHeader(
                title: "Selection",
                systemImage: "slider.horizontal.3"
            )
            detailRow("Video ID", current.videoID)
            detailRow(
                "Output",
                current.effectiveOutputIdentity.rawValue
            )
            if current.configuration.isSubtitlesOnly {
                detailRow(
                    "Subtitle format",
                    current.configuration.subtitleDelivery == .sidecarSRT
                        ? "SRT"
                        : "WebVTT"
                )
                detailRow(
                    "Selected tracks",
                    "\(current.configuration.subtitleSelections?.count ?? 0)"
                )
                ForEach(
                    Array((current.subtitleSidecars ?? []).enumerated()),
                    id: \.offset
                ) { _, sidecar in
                    detailRow(
                        sidecar.selection.automatic
                            ? "Automatic \(sidecar.selection.language)"
                            : "Manual \(sidecar.selection.language)",
                        sidecar.filename
                    )
                }
            } else {
                detailRow(
                    "Format IDs",
                    current.selectedFormatIDs.joined(separator: " + ")
                )
                detailRow(
                    "Container",
                    current.configuration.container.rawValue
                )
                detailRow(
                    "Video codec",
                    current.configuration.videoCodec.rawValue
                )
                detailRow(
                    "Audio codec",
                    current.configuration.audioCodec.rawValue
                )
            }
            detailRow(
                "Destination",
                current.configuration.destination.rawValue
            )
            if let error = current.errorMessage {
                Divider()
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(IllucetTheme.warning)
            }
        }
        .illucetCard()
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            if current.state == .running {
                if current.isWaitingForTransferSlot {
                    Button("Prioritize") { model.prioritize(current) }.buttonStyle(.bordered)
                }
                if current.stage.supportsTransferPause {
                    Button("Pause") { model.pause(current) }
                        .buttonStyle(.borderedProminent).tint(theme.actionFill).foregroundStyle(theme.actionText)
                        .accessibilityIdentifier("job.detail.pause")
                } else {
                    Label(
                        current.stage.isProcessingWork
                            ? "Processing can’t pause"
                            : current.stage.rawValue,
                        systemImage: "hourglass"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier(
                        "job.processingPauseUnavailable"
                    )
                }
            } else if current.canPause {
                Button("Pause") { model.pause(current) }.buttonStyle(.bordered)
                Button("Prioritize") { model.prioritize(current) }.buttonStyle(.bordered)
            } else if current.state == .paused {
                Button("Resume") { model.resume(current) }
                    .buttonStyle(.borderedProminent).tint(theme.actionFill).foregroundStyle(theme.actionText)
            } else if current.state == .failed
                || current.state == .cancelled
                || current.state == .needsAttention {
                Button("Retry") { model.retry(current) }
                    .disabled(current.hasUnknownPublication || current.isAwaitingTransferCleanup)
                    .buttonStyle(.borderedProminent).tint(theme.actionFill).foregroundStyle(theme.actionText)
                    .accessibilityIdentifier("job.detail.retry")
            }
            if !current.state.isTerminal || current.isAwaitingTransferCleanup {
                Button("Cancel job", role: .destructive) {
                    model.cancel(current)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("job.detail.cancel")
            }
            if current.state.isTerminal {
                NavigationLink("Open output details") {
                    OutputDetailView(record: model.history.first { $0.jobID == current.id } ?? HistoryRecord(job: current), context: .queue)
                        .environmentObject(model)
                }.buttonStyle(.bordered)
            }
            if let URL = current.outputURL {
                SavedOutputShareButton(record: model.history.first { $0.jobID == current.id } ?? HistoryRecord(job: current),
                    urls: [URL], title: "Share output")
                .buttonStyle(.bordered)
            }
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
}
