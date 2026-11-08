import SwiftUI

struct DownloadView: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @FocusState private var URLFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                IllucetBackground()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            hero
                                .id(DownloadFocusTarget.top)
                            URLCard
                                .pipAnchor(.link)
                                .id(DownloadFocusTarget.mediaLink)
                            if let suggestion = model.clipboardSuggestion {
                                VStack(alignment: .leading) {
                                    Text("Clipboard link available").font(.headline)
                                    Text(suggestion.absoluteString).font(.caption).lineLimit(2)
                                    HStack {
                                        Button("Use link") { model.acceptClipboardSuggestion() }
                                        Button("Dismiss") { model.clipboardSuggestion = nil }
                                    }
                                }.illucetCard()
                            }
                            if model.pendingSharedLink != nil && !model.presentsSharedLinkChoice {
                                Button("Continue shared link") { model.presentsSharedLinkChoice = true }.illucetCard()
                            }
                            if !model.sharedLinkInbox.isEmpty {
                                DisclosureGroup("Saved shared links (\(model.sharedLinkInbox.count))") {
                                    ForEach(model.sharedLinkInbox) { link in
                                        VStack(alignment: .leading) {
                                            Text(link.url.absoluteString).font(.caption).lineLimit(2)
                                            HStack {
                                                Button("Open link") { model.openSavedSharedLink(link) }
                                                Button("Remove") { model.removeSavedSharedLink(link) }
                                            }
                                        }.padding(.vertical, 4)
                                    }
                                }.illucetCard()
                            }
                            AccountSelectionView()
                            quickPresets
                                .id(DownloadFocusTarget.quickStart)
                            recentLinks
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 36)
                        .illucetContentWidth()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .tabRootScroll(.download, model: model)
                    .dismissesKeyboardFromUnusedSpace(
                        identifier: "download.unusedSpace",
                        isFocused: URLFieldFocused
                    ) {
                        URLFieldFocused = false
                    }
                    .task(id: model.pipGuideStep) { @MainActor in
                        let step = model.pipGuideStep
                        guard let step, [.welcome, .link, .presets, .finish].contains(step) else { return }
                        URLFieldFocused = false
                        await Task.yield()
                        guard !Task.isCancelled, model.selectedTab == .download else { return }
                        withAnimation(systemReduceMotion ? nil : .easeInOut(duration: 0.25)) {
                            if step == .welcome || step == .finish {
                                model.tabScrollStates[.download]?.position.scrollTo(edge: .top)
                            } else {
                                proxy.scrollTo(step == .presets ? DownloadFocusTarget.quickStart : step == .link ? .mediaLink : .top, anchor: .top)
                            }
                        }
                    }
                    .onChange(of: model.downloadTopRequest) { _, request in
                        if request != nil { URLFieldFocused = false }
                    }
                    .onChange(of: model.downloadFocusTarget) {
                        _, target in
                        guard let target else { return }
                        if systemReduceMotion {
                            proxy.scrollTo(target, anchor: .center)
                        } else {
                            withAnimation(.snappy) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                        if target == .mediaLink {
                            URLFieldFocused = true
                        }
                        model.downloadFocusDidComplete(target)
                    }
                }
            }
            .sheet(isPresented: $model.presentsSharedLinkChoice) {
                SharedLinkChoiceView().environmentObject(model)
            }
            .navigationTitle(AppIdentity.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    brandedText("Illucet").font(.system(.title2, design: .serif, weight: .semibold)).tracking(0.4)
                }
            }
            .confirmationDialog(
                "Paste clipboard URL?",
                isPresented: quickStartClipboardOfferBinding,
                titleVisibility: .visible
            ) {
                Button("Paste and Continue") {
                    URLFieldFocused = false
                    model.acceptQuickStartClipboardContinuation()
                }
                Button("Not Now", role: .cancel) {
                    model.declineQuickStartClipboardContinuation()
                }
            } message: {
                Text(
                    "Illucet found a supported media link. Paste it and continue with the selected Quick Start?"
                )
            }
        }
    }

    private var quickStartClipboardOfferBinding: Binding<Bool> {
        Binding(
            get: {
                model.quickStartInputRecovery
                    .offersClipboardContinuation
            },
            set: { isPresented in
                if !isPresented {
                    Task { @MainActor in
                        model.declineQuickStartClipboardContinuation()
                    }
                }
            }
        )
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save it for later.")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("download.hero")
    }

    private var URLCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            IllucetSectionHeader(
                title: "Start with a link",
                subtitle: "A video, a track, or a whole playlist",
                systemImage: "link"
            )
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                    .padding(.top, 13)
                    .accessibilityHidden(true)
                TextField(
                    "https://youtu.be/…",
                    text: Binding(get: { model.URLText }, set: model.editURLField),
                    axis: .vertical
                )
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .lineLimit(1 ... 4)
                .focused($URLFieldFocused)
                .padding(.vertical, 11)
                .accessibilityLabel("Media or playlist URL")
                .accessibilityIdentifier("download.urlField")
                if !model.URLText.isEmpty {
                    Button {
                        model.clearURL()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Clear URL")
                    .accessibilityIdentifier("download.clear")
                }
            }
            .padding(.horizontal, 13)
            .background(
                theme.input,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        model.quickStartInputRecovery.showsGuidance
                            ? theme.accent
                            : Color.clear,
                        lineWidth: 2
                    )
                    .shadow(
                        color: model.quickStartInputRecovery.showsGuidance
                            ? theme.accent.opacity(0.35)
                            : Color.clear,
                        radius: 6
                    )
                    .accessibilityHidden(true)
            }
            .animation(
                systemReduceMotion
                    ? nil : .easeInOut(duration: 0.2),
                value: model.quickStartInputRecovery.showsGuidance
            )

            if model.quickStartInputRecovery.showsGuidance {
                Text("Enter or paste a URL first")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.foregroundAccent)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityIdentifier(
                        "download.quickRecovery.guidance"
                    )
            }

            actionLayout {
                Button {
                    model.pasteURL()
                    URLFieldFocused = !model.pendingPastePermissionTip
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("download.paste")

                Button {
                    URLFieldFocused = false
                    model.analyze()
                } label: {
                    HStack {
                        if model.isAnalyzing {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "sparkle.magnifyingglass")
                        }
                        Text(model.isAnalyzing ? "Analyzing" : model.settings.experience.skipVideoDetails ? "Configure download" : "Analyze")
                    }
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(model.isAnalyzing)
                .accessibilityIdentifier("download.analyze")
            }
        }
        .illucetCard(padding: 20)
    }

    private var actionLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    private var quickPresets: some View {
        VStack(alignment: .leading, spacing: 13) {
            IllucetSectionHeader(
                title: "Quick start",
                subtitle: "Your favorite settings, ready to go",
                systemImage: "bolt"
            )
            .pipAnchor(.presets)
            if model.quickStartPresets.isEmpty {
                ContentUnavailableView {
                    Label("No presets", systemImage: "bolt.slash")
                } description: {
                    Text("Create a Quick Start preset to begin.")
                }
            } else {
                LazyVGrid(
                    columns: presetColumns,
                    spacing: 12
                ) {
                    ForEach(model.quickStartPresets) { preset in
                        quickPreset(preset)
                            .pipAnchor(.presets, active: preset.id == model.quickStartPresets.first?.id)
                    }
                }
            }
            NavigationLink {
                HomeQuickStartSettingsView()
            } label: {
                Label("Manage presets", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("download.managePresets")
        }
        .illucetCard()
    }

    private var presetColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return Array(
            repeating: GridItem(.flexible(), alignment: .top),
            count: horizontalSizeClass == .regular ? 3 : 2
        )
    }

    private func quickPreset(
        _ preset: QuickStartPreset
    ) -> some View {
        Button {
            model.startQuickStart(preset)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: preset.systemImage)
                        .font(.title3)
                        .foregroundStyle(theme.foregroundAccent)
                    Spacer()
                    if preset.launchBehavior == .immediate {
                        Image(systemName: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(IllucetTheme.warning)
                    }
                }
                Text(preset.name)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(preset.qualityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .padding(16)
            .background(
                theme.raisedCard,
                in: RoundedRectangle(cornerRadius: 16)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isAnalyzing)
        .accessibilityLabel(
            "\(preset.name), \(preset.configuration.effectiveOutputIdentity.rawValue), \(preset.qualityLabel)"
        )
        .accessibilityIdentifier(
            "download.quick.\(preset.id.uuidString)"
        )
    }

    @ViewBuilder
    private var recentLinks: some View {
        if !model.recentLinks.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                IllucetSectionHeader(
                    title: "Recent links",
                    systemImage: "clock"
                )
                ForEach(model.recentLinks.prefix(4)) { link in
                    Button {
                        model.useRecent(link)
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: link.thumbnailURL) { phase in
                                if case let .success(image) = phase {
                                    image.resizable().scaledToFill()
                                } else {
                                    ZStack {
                                        theme.raisedCard
                                        Image(systemName: "play.rectangle")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(width: 72, height: 44)
                            .clipShape(
                                RoundedRectangle(cornerRadius: 9)
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(link.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)
                                TimelineView(
                                    .periodic(from: .now, by: 60)
                                ) { context in
                                    Text(
                                        RelativeTimestampFormatter.string(
                                            from: link.analyzedAt,
                                            relativeTo: context.date
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Analyze recent link \(link.title)")
                }
            }
            .illucetCard()
        }
    }

}
