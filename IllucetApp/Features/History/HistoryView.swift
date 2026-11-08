import SwiftUI

private enum HistoryStatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case completed = "Completed"
    case failed = "Failed"

    var id: String { rawValue }
}

struct HistoryView: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    @State private var query = ""
    @State private var statusFilter: HistoryStatusFilter = .all
    @State private var modeFilter: EffectiveOutputIdentity?

    @State private var confirmsDeletion = false
    @State private var deleting = false
    private var eligibleItems: Set<SelectionItem> { Set(filteredRecords.map { .history($0.id) }) }

    var body: some View {
        NavigationStack {
            ZStack {
                IllucetBackground()
                if model.history.isEmpty {
                    EmptyStateView(
                        systemImage: "clock.arrow.circlepath",
                        title: "No history yet",
                        message: "Completed and failed jobs will appear here with their exact settings and verification results.",
                        actionTitle: "Paste Link",
                        action: model.openPasteFromEmptyState,
                        secondaryActionTitle: "Open Quick Start",
                        secondaryAction:
                            model.openQuickStartFromEmptyState,
                        accessibilityPrefix: "history.empty"
                    )
                    .accessibilityIdentifier("history.empty")
                } else if filteredRecords.isEmpty {
                    EmptyStateView(
                        systemImage: "line.3.horizontal.decrease.circle",
                        title: "No matches",
                        message: "Try a different search or clear the active filters.",
                        actionTitle: "Clear filters"
                    ) {
                        query = ""
                        statusFilter = .all
                        modeFilter = nil
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            filterBar
                            ForEach(filteredRecords) { record in
                                HistoryCard(record: record)
                                    .environmentObject(model)
                                    .selectableCard(.history(record.id), selection: $model.historySelection)
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 30)
                        .illucetContentWidth()
                    }
                    .tabRootScroll(.history, model: model)
                }
            }
            .navigationTitle("History")
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Title, channel, or video ID"
            )
            .onChange(of: eligibleItems, initial: true) { _, items in model.historySelection.update(items) }
            .safeAreaInset(edge: .bottom, spacing: 8) {
                if model.historySelection.isActive && model.selectedTab == .history {
                    InlineSelectionBar(selection: $model.historySelection, working: deleting) { confirmsDeletion = true }
                }
            }
            .confirmationDialog("Delete selected History entries?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
                Button("Remove records", role: .destructive) { deleteSelection(includingFiles: false) }
                Button("Delete files and records", role: .destructive) { deleteSelection(includingFiles: true) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Removing records keeps files. Photos library items are kept.") }
            .toolbar {
                if !model.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Status", selection: $statusFilter) {
                                ForEach(HistoryStatusFilter.allCases) { filter in
                                    brandedText(filter.rawValue).tag(filter)
                                }
                            }
                            Divider()
                            Button("All modes") { modeFilter = nil }
                            ForEach(
                                EffectiveOutputIdentity.implementedRequestCases
                            ) { identity in
                                Button {
                                    modeFilter = identity
                                } label: {
                                    Label(
                                        identity.rawValue,
                                        systemImage: modeFilter == identity
                                            ? "checkmark"
                                            : identity.systemImage
                                    )
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        .accessibilityLabel("Filter history")
                        .accessibilityIdentifier("history.filters")
                    }
                }
            }
        }
    }

    private func deleteSelection(includingFiles: Bool) {
        let ids = Set(model.historySelection.selected.compactMap { item -> UUID? in
            if case .history(let id) = item { return id }; return nil
        })
        deleting = true
        Task {
            await model.removeHistoryRecords(ids, includingFiles: includingFiles)
            model.historySelection.update(eligibleItems)
            if model.historySelection.selected.isEmpty { model.historySelection.cancel() }
            deleting = false
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                IllucetPill(
                    text: statusFilter.rawValue,
                    color: statusFilter == .all
                        ? theme.foregroundAccent
                        : IllucetTheme.violet
                )
                if let modeFilter {
                    IllucetPill(
                        text: modeFilter.rawValue,
                        color: IllucetTheme.violet,
                        systemImage: modeFilter.systemImage
                    )
                }
                Text("\(filteredRecords.count) records")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filteredRecords: [HistoryRecord] {
        model.history
            .filter { record in
                switch statusFilter {
                case .all: true
                case .completed: record.status == .completed
                case .failed: record.status == .failed
                }
            }
            .filter { record in
                modeFilter == nil
                    || record.effectiveOutputIdentity == modeFilter
            }
            .filter { record in
                guard !query.isEmpty else { return true }
                let haystack = [
                    record.title,
                    record.channel ?? "",
                    record.videoID,
                    record.destination.rawValue,
                    record.effectiveOutputIdentity.rawValue,
                ].joined(separator: " ")
                return haystack.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.completedAt > $1.completedAt }
    }
}

private struct HistoryCard: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    let record: HistoryRecord

    var body: some View {
        Button {
            model.selectedHistoryRecord = record
        } label: {
            HStack(spacing: 13) {
                AsyncImage(url: record.thumbnailURL) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            theme.raisedCard
                            Image(
                                systemName:
                                    record.effectiveOutputIdentity.systemImage
                            )
                                .foregroundStyle(record.status.tint(accent: theme.foregroundAccent))
                                .accessibilityLabel(
                                    "\(record.effectiveOutputIdentity.rawValue) output"
                                )
                                .accessibilityIdentifier(
                                    "history.record.\(record.id.uuidString).outputTypeIcon"
                                )
                        }
                    }
                }
                .frame(width: 88, height: 57)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    HStack {
                        IllucetPill(
                            text: record.status.label,
                            color: record.status.tint(accent: theme.foregroundAccent)
                        )
                        brandedText(record.effectiveOutputIdentity.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(record.completedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 5)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(record.title), \(record.status.label), \(record.effectiveOutputIdentity.rawValue)"
        )
        .illucetCard(padding: 13)
        .accessibilityIdentifier("history.record.\(record.id.uuidString)")
    }
}
