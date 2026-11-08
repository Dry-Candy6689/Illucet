import SwiftUI

struct SponsorBlockPolicyControls: View {
    @Binding var policy: SponsorBlockPolicy
    let showsCategoryDefaults: Bool
    let showsExplanations: Bool

    init(
        policy: Binding<SponsorBlockPolicy>,
        showsCategoryDefaults: Bool = true,
        showsExplanations: Bool = true
    ) {
        _policy = policy
        self.showsCategoryDefaults = showsCategoryDefaults
        self.showsExplanations = showsExplanations
    }

    var body: some View {
        Toggle("Enable SponsorBlock", isOn: enabled)
            .accessibilityIdentifier("sponsorblock.enabled")
        if policy.isEnabled {
            if showsExplanations {
            Text(
                "Illucet sends only a four-character SHA-256 video-ID prefix to the official SponsorBlock API and verifies the exact video locally."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            }

            if showsCategoryDefaults {
                ForEach(SponsorBlockCategory.stableOrder) { category in
                    HStack {
                    SponsorBlockCategoryLabel(category: category).layoutPriority(1)
                    Spacer(minLength: 8)
                    Picker(category.title, selection: action(category)) {
                        ForEach(category.editableActions) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("sponsorblock.category.\(category.rawValue).action")
                    }
                }
            }
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { policy.isEnabled },
            set: { value in
                var updated = policy
                updated.setEnabled(value)
                policy = updated
            }
        )
    }

    private func action(
        _ category: SponsorBlockCategory
    ) -> Binding<SponsorBlockAction> {
        Binding(
            get: { policy.categoryDownloadAction(for: category) },
            set: { value in
                var updated = policy
                updated.setDefaultAction(value, for: category)
                policy = updated
            }
        )
    }
}

struct SponsorBlockDownloadOptions: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    @State private var editingCategory: SponsorBlockCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            IllucetSectionHeader(
                title: "SponsorBlock",
                subtitle: subtitle,
                systemImage: "forward.end.fill"
            )
            SponsorBlockPolicyControls(
                policy: policy,
                showsCategoryDefaults: false
            )
            if model.configuration.sponsorBlock.needsSegmentReview {
                removalMode
                Divider()
                preview
            }
        }
        .illucetCard()
        .sheet(item: $editingCategory) { category in
            SponsorBlockCategoryEditor(category: category, policy: policy)
        }
    }

    private var policy: Binding<SponsorBlockPolicy> {
        Binding(
            get: { model.configuration.sponsorBlock },
            set: { model.updateSponsorBlockPolicy($0) }
        )
    }

    private var subtitle: String {
        let value = model.configuration.sponsorBlock
        guard value.isEnabled else { return "Off — no API request" }
        return "Choose actions by category"
    }

    private var removalMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                "Removal mode",
                selection: Binding(
                    get: {
                        model.configuration.sponsorBlock.removalMode
                    },
                    set: { mode in
                        var updated = model.configuration.sponsorBlock
                        updated.removalMode = mode
                        model.updateSponsorBlockPolicy(updated)
                    }
                )
            ) {
                Text("Accurate").tag(SponsorBlockRemovalMode.accurate)
                Text("Fast (Keyframe-Aligned)")
                    .tag(SponsorBlockRemovalMode.fastKeyframe)
                    .disabled(!model.sponsorBlockFastModeAvailable)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("sponsorblock.removalMode")

            if model.configuration.sponsorBlock.removalMode
                == .fastKeyframe {
                Label(
                    "Fast mode uses nearby proven keyframes. Removal boundaries may move and History records the actual applied ranges.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(IllucetTheme.warning)
                .accessibilityIdentifier("sponsorblock.fast.warning")
            } else if !model.sponsorBlockFastModeAvailable {
                Text(
                    "Fast mode is available only for compatible MP4/MOV video output without trim, subtitles, or embedded artwork."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch model.sponsorBlockPreviewState {
        case .idle:
            Label("Waiting for analyzed media", systemImage: "clock")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("sponsorblock.preview.idle")
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading SponsorBlock segments…")
            }
            .accessibilityIdentifier("sponsorblock.preview.loading")
        case .empty:
            Label(
                "No SponsorBlock segments found for this video.",
                systemImage: "checkmark.circle"
            )
            .foregroundStyle(IllucetTheme.success)
            .accessibilityIdentifier("sponsorblock.preview.empty")
        case let .failed(error):
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "SponsorBlock preview unavailable",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(IllucetTheme.warning)
                .accessibilityIdentifier("sponsorblock.preview.failed")
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    model.configuration.sponsorBlock.requiresRemoval
                        ? "Retry SponsorBlock before downloading with removal."
                        : "You can continue without SponsorBlock."
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    model.configuration.sponsorBlock.requiresRemoval
                        ? IllucetTheme.danger
                        : IllucetTheme.warning
                )
                .accessibilityIdentifier(
                    model.configuration.sponsorBlock.requiresRemoval
                        ? "sponsorblock.failure.required"
                        : "sponsorblock.failure.optional"
                )
                Button("Retry") {
                    model.retrySponsorBlockPreview()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("sponsorblock.preview.retry")
            }
        case let .loaded(count):
            VStack(alignment: .leading, spacing: 12) {
                Text("\(count) segment\(count == 1 ? "" : "s")")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("sponsorblock.preview.loaded")
                ForEach(returnedCategories) { category in
                    categoryCard(category)
                }
                if case let .blocked(blocker) = model.sponsorBlockReviewState {
                    Label(
                        blocker.message,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(IllucetTheme.danger)
                    .accessibilityIdentifier("sponsorblock.review.blocker")
                }
            }
        }
    }

    private var returnedCategories: [SponsorBlockCategory] {
        SponsorBlockCategory.stableOrder.filter { category in
            segments(in: category).isEmpty == false
        }
    }

    private func segments(in category: SponsorBlockCategory) -> [SponsorBlockSegmentSelection] {
        (policy.wrappedValue.selectionSnapshot?.segments ?? []).filter { $0.category == category }
    }

    private func categoryCard(_ category: SponsorBlockCategory) -> some View {
        let segments = segments(in: category)
        let duration = segments.reduce(0) { $0 + $1.endSeconds - $1.startSeconds }
        let inherited = policy.wrappedValue.categoryDefaultAction(for: category)
        let overrides = segments.filter { $0.actionOverride != nil }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    SponsorBlockCategoryLabel(category: category)
                    Text("\(segments.count) segment\(segments.count == 1 ? "" : "s") · \(duration.conciseDuration)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { editingCategory = category } label: {
                    Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.foregroundAccent)
                .accessibilityLabel("Edit \(category.title) segments")
                .accessibilityIdentifier("sponsorblock.category.\(category.rawValue).segments")
            }
            SponsorBlockActionPicker(category: category, inherited: inherited, selection: Binding(
                get: { policy.wrappedValue.categoryOverride(for: category) },
                set: { value in
                    var updated = policy.wrappedValue
                    updated.setCategoryOverride(value, for: category)
                    policy.wrappedValue = updated
                }))
                .accessibilityIdentifier("sponsorblock.category.\(category.rawValue).action")
            if overrides > 0 {
                Text("\(overrides) individual override\(overrides == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(theme.raisedCard, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SponsorBlockActionPicker: View {
    let category: SponsorBlockCategory
    let inherited: SponsorBlockAction
    @Binding var selection: SponsorBlockAction?

    var body: some View {
        Picker("Action", selection: Binding(
            get: { selection == inherited ? nil : selection },
            set: { selection = $0 })) {
            Text("Category default (\(inherited.title))").tag(SponsorBlockAction?.none)
            ForEach(category.editableActions.filter { $0 != inherited }) { action in
                Text(action.title).tag(SponsorBlockAction?.some(action))
            }
        }
        .pickerStyle(.menu)
    }
}

private struct SponsorBlockCategoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    let category: SponsorBlockCategory
    @Binding var policy: SponsorBlockPolicy

    var body: some View {
        NavigationStack {
            Form {
                Section("Individual segments") {
                    ForEach((policy.selectionSnapshot?.segments ?? []).filter { $0.category == category }) { segment in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(time(segment.startSeconds))–\(time(segment.endSeconds))")
                                .font(.subheadline.monospacedDigit())
                            if let description = segment.description {
                                Text(description).font(.caption).foregroundStyle(.secondary)
                            }
                            SponsorBlockActionPicker(category: category, inherited: policy.categoryDownloadAction(for: category),
                                selection: Binding(
                                    get: { policy.selectionSnapshot?.segments.first { $0.id == segment.id }?.actionOverride },
                                    set: { policy.setSegmentOverride($0, segmentID: segment.id) }))
                                .accessibilityIdentifier("sponsorblock.segment.\(segment.id).action")
                        }
                    }
                }
            }
            .settingsFormBackground()
            .navigationTitle(category.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func time(_ seconds: Double) -> String {
        String(format: "%d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}
