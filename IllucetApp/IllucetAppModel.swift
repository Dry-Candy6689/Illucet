import SwiftUI
import UIKit

@MainActor
final class IllucetAppModel: ObservableObject {
    @Published var clipboardSuggestion: URL?
    @Published var pendingPastePermissionTip = false
    @Published var notificationsAuthorized: Bool?
    var lastAutomaticClipboardChange: Int?
    var clipboardDraftRevision = 0
    @Published var lastPreferencesExportAt: Date?
    @Published var sharedLinkInbox: [SharedLink] = []
    @Published var pendingSharedLink: URL?
    var activeShortcutRequest: SharedLink?
    var pendingShortcutOptions: ShortcutHandoff?
    var deferredShortcutHandoffs: [ShortcutHandoff] = []
    @Published var presentsSharedLinkChoice = false
    var opensFullOptionsAfterAnalysis = false
    var analysisUsesSharedRouting = false
    var configurationReturnsToDetails = false
    @Published var isStartingDownload = false
    var downloadReviewID = UUID()
    var completedDownloadReviewID: UUID?
    var downloadSubmissionInFlight: UUID?
    @Published var selectedTab: AppTab = .download {
        didSet { if selectedTab == .queue { unseenQueueCompletions.removeAll() } }
    }
    @Published var queueSelection = InlineSelectionState()
    @Published var historySelection = InlineSelectionState()
    @Published var unseenQueueCompletions: Set<UUID> = []
    @Published var foregroundDownloadCompletions: [UUID: Date] = [:]
    @Published var settingsNavigationPath: [SettingsDestination] = []
    @Published var pipNavigationAnchor: PipAnchor?
    @Published var URLText = "" {
        didSet {
            if URLText != oldValue {
                clipboardDraftRevision &+= 1
                clipboardSuggestion = nil
            }
            quickStartInputRecovery.URLTextDidChange(
                from: oldValue,
                to: URLText
            )
            if !quickStartInputRecovery.showsGuidance {
                quickStartRecoveryPresentationTask?.cancel()
                quickStartRecoveryPresentationTask = nil
            }
        }
    }
    @Published var accountProfiles: [AccountProfile] = []
    @Published var selectedAccountID: UUID?
    @Published var isAnalyzing = false
    @Published private(set) var isStartingQuickStart = false
    @Published var analyzedMetadata: MediaMetadata?
    @Published var playlistDraft: PlaylistBatchDraft?
    @Published var extractionVersions: ExtractorVersions?
    @Published var configuration = DownloadConfiguration.standard
    @Published var sponsorBlockPreviewState:
        SponsorBlockPreviewState = .idle
    @Published var jobs: [DownloadJob] = [] {
        didSet {
            updateQueueCompletions(previous: Set(oldValue.filter { $0.state == .completed }.map(\.id)),
                current: Set(jobs.filter { $0.state == .completed }.map(\.id)))
        }
    }
    @Published var batches: [DownloadBatch] = [] {
        didSet {
            func completed(_ values: [DownloadBatch]) -> Set<UUID> {
                Set(values.filter { $0.state == .completed
                    && ($0.destinationStructure != .zipArchive || $0.packageURL != nil) }.map(\.id))
            }
            updateQueueCompletions(previous: completed(oldValue), current: completed(batches))
        }
    }
    @Published var packagingBatchIDs: Set<UUID> = []
    @Published var downloadArchive: [DownloadArchiveEntry] = []
    @Published var history: [HistoryRecord] = []
    @Published var recentLinks: [RecentLink] = []
    @Published var quickStartPresets = QuickStartPresetLibrary.defaults
    @Published var activeQuickStartPreset: QuickStartPreset?
    @Published var firstRunState = FirstRunState.initial
    @Published var settings = AppSettings.defaults
    @Published var storage = StorageSnapshot.empty
    @Published var isClearingDiagnostics = false
    @Published var didClearDiagnostics = false
    var clearDiagnosticsFeedbackTask: Task<Void, Never>?
    @Published var isRefreshingStorage = false
    @Published var isDeletingIllucetFiles = false
    @Published var isRemovingHistoryFiles = false
    @Published var storageRefreshedAt: Date?
    var storageRefreshGeneration = 0
    var storageRefreshTask: Task<Void, Never>?
    private(set) var startupTask: Task<Void, Never>?
    let storageSnapshotProvider: @Sendable () async -> StorageSnapshot
    let outputResolver: SavedOutputResolver
    @Published var updateStatus = UpdateStatus.initial
    @Published var diagnosticEntries: [DiagnosticEntry] = []
    @Published var filesFolderName: String?
    @Published var filesFolderAliasDraft = ""
    @Published var filesFolderAliasEditorMode: FilesFolderAliasEditorMode?
    @Published var alert: AppAlert?
    @Published var exportedDiagnosticURL: URL?
    @Published var startupState: IllucetStartupState = .loading
    var isPreparing: Bool { startupState == .loading }
    @Published var isRequestingNotificationAuthorization = false
    @Published var presentsOnboarding = false
    @Published var replaysPipGuide = false
    @Published var pipGuideStep: PipGuideStep?
    var pipGuideOwner: UUID?
    @Published var downloadFocusTarget: DownloadFocusTarget?
    let tabScrollStates = Dictionary(uniqueKeysWithValues: AppTab.allCases.map { ($0, TabScrollState()) })
    var downloadTopRequest: UUID? { tabScrollStates[.download]?.request?.id }
    @Published var highlightsDownloadScreens = false
    @Published private(set) var quickStartInputRecovery =
        QuickStartInputRecoveryState()
    @Published var stage0Report: Stage0ProofReport?
    @Published var isRunningStage0 = false

    @Published var presentsMetadata = false
    @Published var presentsConfiguration = false
    @Published var presentsConfirmation = false
    @Published var presentsQuickStartConfirmation = false
    @Published var presentsPlaylistBatch = false
    @Published var presentsDownloadArchive = false
    @Published var filesFolderPickerSource: FilesFolderPickerSource?
        = nil
    @Published var selectedHistoryRecord: HistoryRecord?
    @Published var selectedJob: DownloadJob?
    var userPresentationState = IllucetAppPresentationState()
    var activeShareOutcomes: [UUID: ShareOutcomeArbiter] = [:]

    let runtime: RuntimeEnvironment
    let persistence: IllucetPersistence
    let diagnostics: DiagnosticStore
    let storageManager: StorageManager
    let exporter: ExportManager
    let updateService: ExtractorUpdateService
    let notifications: UserNotificationService
    let liveActivityController = LiveActivityController()
    let coordinator: DownloadCoordinator
    let batchController: DownloadBatchController
    let batchPackageService: BatchPackageService
    let sponsorBlockService: any SponsorBlockServing
    let sponsorBlockDiagnostics: SponsorBlockDiagnosticLogger

    var snapshot = IllucetSnapshot.empty
    var updateTask: Task<Void, Never>?
    var batchUpdateTask: Task<Void, Never>?
    var saveTask: Task<Void, Never>?
    var extractorUpdateCheckTask: Task<Void, Never>?
    var extractorUpdateCheckID: UUID?
    var extractorUpdateCheckIsAutomatic = false
    private var quickStartRecoveryPresentationTask: Task<Void, Never>?
    var sponsorBlockPreviewTask: Task<Void, Never>?
    var packageTasks: [UUID: Task<Void, Never>] = [:]
    var pendingRedownloadConfiguration: DownloadConfiguration?
    var pendingStartupDeepLink: URL?
    @Published var shortcutHandoff: ShortcutHandoff?
    var shortcutOperations: [UUID: ShortcutDownloadOperation] = [:]
    let fixtureMode: Bool
    var sceneEventRevision: UInt64 = 0

    var usesDeterministicFolderPicker: Bool {
        fixtureMode && ProcessInfo.processInfo.arguments.contains(
            "--ui-folder-picker-fixture"
        )
    }

    var usesDocumentsFolderPickerFixture: Bool {
        fixtureMode && ProcessInfo.processInfo.arguments.contains(
            "--ui-folder-documents-fixture"
        )
    }

    init(
        sponsorBlockService: (any SponsorBlockServing)? = nil,
        persistence: IllucetPersistence? = nil,
        fixtureModeOverride: Bool? = nil,
        storageManager: StorageManager? = nil,
        storageSnapshot: (@Sendable () async -> StorageSnapshot)? = nil,
        outputResolver: SavedOutputResolver = .init()
    ) {
        let fixtureMode = IllucetLaunchRouting.usesUITestFixtures(
            arguments: ProcessInfo.processInfo.arguments,
            override: fixtureModeOverride
        )
        self.fixtureMode = fixtureMode
        self.outputResolver = outputResolver
        let activeDiagnostics = DiagnosticStore()
        diagnostics = activeDiagnostics
        let activeSponsorBlockDiagnostics = SponsorBlockDiagnosticLogger(
            store: activeDiagnostics
        )
        sponsorBlockDiagnostics = activeSponsorBlockDiagnostics
        if let sponsorBlockService {
            self.sponsorBlockService = sponsorBlockService
        } else if fixtureMode,
                  ProcessInfo.processInfo.arguments.contains(
                    "--ui-sponsorblock-failure"
                  ) {
            self.sponsorBlockService = SponsorBlockUnavailableFixtureService()
        } else if fixtureMode {
            self.sponsorBlockService = SponsorBlockStaticService(
                availableSegments: DeveloperFixtures.sponsorBlockSegments
            )
        } else {
            self.sponsorBlockService = SponsorBlockService.live(
                diagnostics: activeSponsorBlockDiagnostics
            )
        }
        let runtime = RuntimeEnvironment()
        self.runtime = runtime
        self.persistence = persistence ?? IllucetPersistence()
        let activeStorage = storageManager ?? StorageManager()
        self.storageManager = activeStorage
        storageSnapshotProvider = storageSnapshot ?? { await activeStorage.snapshot() }
        exporter = ExportManager()
        batchPackageService = BatchPackageService(exporter: exporter)
        updateService = ExtractorUpdateService()
        notifications = UserNotificationService(foregroundCompletionTime: {
            UIApplication.shared.applicationState == .active ? .now : nil
        })
        if !fixtureMode {
            ContinuedProcessingController.shared.setReporter { jobID, attempt, status in
                await activeDiagnostics.record(.info, subsystem: "background", event: "execution_lease",
                    detail: "job=\(jobID); attempt=\(attempt); state=\(status.state.rawValue); reason=\(status.reason?.rawValue ?? "none"); finishingTime=\(status.hasFinishingTime); requested=\(status.requestedAt?.timeIntervalSince1970 ?? 0); changed=\(status.updatedAt.timeIntervalSince1970)")
            }
        }
        let downloader = StreamDownloadService(fragmentResumeEvent: { jobID, _, reason in
            Task {
                await activeDiagnostics.record(.info, subsystem: "downloads",
                    event: "fragment_resume_restart", detail: "job=\(jobID); reason=\(reason.rawValue)")
            }
        })
        let processor = NativeFFmpegMediaProcessor()
        let DASHAssembler = DASHLocalStreamAssembler(
            mediaProcessor: processor
        )
        let HLSAssembler = HLSLocalStreamAssembler(
            mediaProcessor: processor
        )
        let thumbnails = ThumbnailService()
        let coordinator = DownloadCoordinator(
            runtime: runtime,
            downloader: downloader,
            DASHDownloader: downloader,
            DASHAssembler: DASHAssembler,
            HLSDownloader: downloader,
            HLSAssembler: HLSAssembler,
            mediaProcessor: processor,
            storage: activeStorage,
            exporter: exporter,
            thumbnails: thumbnails,
            diagnostics: diagnostics,
            sponsorBlockDiagnostics: activeSponsorBlockDiagnostics,
            notifications: notifications,
            processingContinuation: fixtureMode ? nil : ContinuedProcessingController.shared
        )
        self.coordinator = coordinator
        let childFactory = PlaylistChildJobFactory(
            loadAccountMetadata: { URL, accountID in
                if fixtureMode,
                   let videoID = LiveExtractionValidator.youtubeVideoID(
                       from: URL
                   ),
                   let entry = DeveloperFixtures.playlist.entries.first(
                       where: { $0.videoID == videoID }
                   ) {
                    try await Task.sleep(for: .milliseconds(35))
                    return DeveloperFixtures.media(for: entry)
                }
                let extractor = try await runtime.extractor(accountID: accountID)
                return try await extractor.analyze(url: URL)
            },
            enqueue: { metadata, configuration, version, membership in
                try await coordinator.enqueue(
                    metadata: metadata,
                    configuration: configuration,
                    extractorVersion: version,
                    batchMembership: membership
                )
            }
        )
        batchController = DownloadBatchController(
            childFactory: childFactory,
            commands: DownloadBatchJobCommands(
                pause: { await coordinator.pause($0) },
                resume: { await coordinator.resume($0) },
                cancel: { await coordinator.cancel($0) },
                retry: { await coordinator.retry($0) }
            )
        )
        observeCoordinator()
        observeBatchController()
        startupTask = Task { await prepare() }
    }

    deinit {
        startupTask?.cancel()
        storageRefreshTask?.cancel()
        updateTask?.cancel()
        batchUpdateTask?.cancel()
        saveTask?.cancel()
        extractorUpdateCheckTask?.cancel()
        quickStartRecoveryPresentationTask?.cancel()
        sponsorBlockPreviewTask?.cancel()
        for task in packageTasks.values {
            task.cancel()
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch settings.appearance {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }

    var orderedJobs: [DownloadJob] {
        jobs.sorted {
            if $0.state.isTerminal != $1.state.isTerminal {
                return !$0.state.isTerminal
            }
            return $0.priority < $1.priority
        }
    }

    var activeJobCount: Int {
        jobs.count { !$0.state.isTerminal }
    }

    var queueTabBadge: QueueTabBadge? {
        QueueTabBadge.resolve(jobs: jobs, batches: batches, packaging: packagingBatchIDs,
            hasPendingAction: pendingUserPresentations.count > 0,
            hasNewCompletion: !unseenQueueCompletions.isEmpty)
    }

    private func updateQueueCompletions(previous: Set<UUID>, current: Set<UUID>) {
        unseenQueueCompletions.subtract(previous.subtracting(current))
        // Restoring old History is not a new completion. A completion already
        // visible in Queue has also been seen; this acknowledgement is session-local.
        guard startupState == .ready, selectedTab != .queue else { return }
        unseenQueueCompletions.formUnion(current.subtracting(previous))
    }

    var pendingUserPresentations: PendingUserPresentationQueue {
        userPresentationState.queue
    }

    var pendingDuplicateConflict: DuplicateConflict? {
        userPresentationState.pendingDuplicateConflict
    }

    var pendingShareRequest: SharePresentationRequest? {
        userPresentationState.pendingShareRequest
    }

    var pendingNetworkAccessRequest: NetworkAccessRequest? {
        userPresentationState.pendingNetworkAccessRequest
    }

    func pasteURL() {
        if fixtureMode {
            URLText = DeveloperFixtures.RickURL.absoluteString
            recordPastedLink(URLText)
            return
        }
        lastAutomaticClipboardChange = UIPasteboard.general.changeCount
        if let value = UIPasteboard.general.string {
            URLText = value.trimmingCharacters(in: .whitespacesAndNewlines)
            recordPastedLink(URLText)
        }
    }

    func clearURL() {
        cancelQuickStartInputRecovery()
        sponsorBlockPreviewTask?.cancel()
        sponsorBlockPreviewTask = nil
        sponsorBlockPreviewState = .idle
        URLText = ""
        analyzedMetadata = nil
        playlistDraft = nil
        presentsMetadata = false
        presentsConfiguration = false
        presentsConfirmation = false
        presentsQuickStartConfirmation = false
        presentsPlaylistBatch = false
        activeQuickStartPreset = nil
    }

    func openPasteFromEmptyState() {
        selectedTab = .download
        downloadFocusTarget = .mediaLink
        pasteURL()
    }

    func openQuickStartFromEmptyState() {
        selectedTab = .download
        downloadFocusTarget = .quickStart
    }

    func downloadFocusDidComplete(_ target: DownloadFocusTarget) {
        guard downloadFocusTarget == target else { return }
        downloadFocusTarget = nil
    }

    func analyze() {
        analyze(
            quickStartPreset: quickStartInputRecovery.pendingPreset
        )
    }

    func startQuickStart(_ preset: QuickStartPreset) {
        guard !startupState.blocksInteraction, !isAnalyzing, !isStartingQuickStart else { return }
        if preset.launchBehavior == .immediate && !analysisUsesSharedRouting {
            if URLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let url = LinkIntakePolicy.clipboardURL(readClipboardText(), currentInput: URLText) {
                URLText = url.absoluteString
                recordPastedLink(URLText)
            }
            if QuickStartInputRecoveryState.requiresRecovery(for: URLText) {
                beginQuickStartInputRecovery(for: preset, offersClipboard: false)
                return
            }
        }
        guard !QuickStartInputRecoveryState.requiresRecovery(
            for: URLText
        ) else {
            beginQuickStartInputRecovery(for: preset)
            return
        }
        cancelQuickStartInputRecovery()
        analyze(quickStartPreset: preset)
    }

    func declineQuickStartClipboardContinuation() {
        quickStartInputRecovery.declineClipboardContinuation()
    }

    func acceptQuickStartClipboardContinuation() {
        guard let continuation =
            quickStartInputRecovery.acceptClipboardContinuation(
                readClipboardText: readClipboardText
            )
        else {
            return
        }
        quickStartRecoveryPresentationTask?.cancel()
        quickStartRecoveryPresentationTask = nil
        URLText = continuation.URLText
        recordPastedLink(URLText)
        analyze(quickStartPreset: continuation.preset)
    }

    private func beginQuickStartInputRecovery(
        for preset: QuickStartPreset, offersClipboard: Bool = true
    ) {
        quickStartRecoveryPresentationTask?.cancel()
        quickStartInputRecovery.begin(
            preset: preset,
            readClipboardText: { offersClipboard ? self.readClipboardText() : nil }
        )
        selectedTab = .download
        downloadFocusTarget = .mediaLink
        quickStartRecoveryPresentationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.quickStartInputRecovery.hideGuidance()
            self?.quickStartRecoveryPresentationTask = nil
        }
    }

    func cancelQuickStartInputRecovery() {
        quickStartRecoveryPresentationTask?.cancel()
        quickStartRecoveryPresentationTask = nil
        quickStartInputRecovery.cancel()
    }

    func readClipboardText() -> String? {
        if fixtureMode {
            if ProcessInfo.processInfo.arguments.contains(
                "--ui-clipboard=unsupported"
            ) {
                return "This is not a supported media URL"
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--ui-clipboard=empty"
            ) {
                return nil
            }
            return DeveloperFixtures.RickURL.absoluteString
        }
        return UIPasteboard.general.string
    }

    private func analyze(quickStartPreset: QuickStartPreset?) {
        guard !startupState.blocksInteraction, !isAnalyzing, !isStartingDownload else { return }
        let value = URLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            alert = .error(IllucetError.emptyURL)
            return
        }
        guard let URL = Foundation.URL(string: value) else {
            alert = .error(IllucetError.invalidURL)
            return
        }
        let intent: YouTubeMediaURLIntent
        do {
            intent = try YouTubeURLIntentClassifier.classify(URL)
        } catch {
            alert = .error(error)
            return
        }
        if quickStartInputRecovery.isActive {
            _ = quickStartInputRecovery.analysisDidBegin()
            quickStartRecoveryPresentationTask?.cancel()
            quickStartRecoveryPresentationTask = nil
        }
        resetDownloadReview()
        isAnalyzing = true
        sponsorBlockPreviewTask?.cancel()
        sponsorBlockPreviewTask = nil
        sponsorBlockPreviewState = .idle
        analyzedMetadata = nil
        playlistDraft = nil
        let accountID = pendingRedownloadConfiguration != nil
            ? pendingRedownloadConfiguration?.accountID
            : (activeShortcutRequest?.url == URL ? quickStartPreset?.configuration.accountID : nil) ?? selectedAccountID
        Task {
            defer { isAnalyzing = false; opensFullOptionsAfterAnalysis = false; analysisUsesSharedRouting = false }
            do {
                switch intent {
                case .video:
                    try await finishVideoAnalysis(
                        URL: URL,
                        quickStartPreset: quickStartPreset, accountID: accountID
                    )
                case .playlist:
                    try await finishPlaylistAnalysis(
                        URL: URL,
                        quickStartPreset: quickStartPreset, accountID: accountID
                    )
                }
            } catch {
                alert = .error(error)
                await diagnostics.record(
                    .error,
                    subsystem: "extraction",
                    event: "analysis_failed",
                    detail: nil
                )
                if error is AccountError { await refreshAccounts() }
            }
        }
    }

    private func finishVideoAnalysis(
        URL: URL,
        quickStartPreset: QuickStartPreset?, accountID: UUID?
    ) async throws {
        let metadata: MediaMetadata
        if fixtureMode {
            try await Task.sleep(for: .milliseconds(180))
            metadata = DeveloperFixtures.media
        } else {
            let extractor = try await runtime.extractor(accountID: accountID)
            async let metadataValue = extractor.analyze(url: URL)
            async let versionsValue = extractor.versions()
            metadata = try await metadataValue
            extractionVersions = try? await versionsValue
        }
        analyzedMetadata = metadata
        var pipLocal = firstRunState.pip ?? .init()
        pipLocal.analyzedFirstVideo = true
        firstRunState.pip = pipLocal
        scheduleSave()
        configurationReturnsToDetails = false
        if let quickStartPreset {
            do {
                configuration = try quickStartPreset.resolvedConfiguration(metadata: metadata)
                activeQuickStartPreset = quickStartPreset
            } catch {
                // An incompatible preferred preset must leave the shared link
                // available and present the complete configuration decisions.
                if opensFullOptionsAfterAnalysis {
                    configuration = OutputCapabilityMatrix.normalized(settings.configuration())
                    FormatSelection.applyAutomaticSelection(to: &configuration, metadata: metadata)
                    configuration.accountID = accountID
                    activeQuickStartPreset = nil
                    selectDefaultSubtitlesIfNeeded()
                    beginSponsorBlockPreview()
                    addRecent(metadata)
                    presentsConfiguration = true
                    opensFullOptionsAfterAnalysis = false
                    return
                }
                throw error
            }
        } else {
            configuration = pendingRedownloadConfiguration
                ?? settings.configuration()
            pendingRedownloadConfiguration = nil
            configuration.trimStartSeconds = nil
            configuration.trimEndSeconds = nil
            configuration.trimMode = nil
            configuration.thumbnailID = nil
            configuration = OutputCapabilityMatrix.normalized(
                configuration
            )
            if configuration.shouldRefreshAutomaticFormatSelection {
                FormatSelection.applyAutomaticSelection(
                    to: &configuration,
                    metadata: metadata
                )
            }
        }
        configuration.accountID = accountID
        selectDefaultSubtitlesIfNeeded()
        beginSponsorBlockPreview()
        addRecent(metadata)
        if opensFullOptionsAfterAnalysis && activeShortcutRequest?.url == metadata.canonicalURL {
            presentsConfiguration = true
        } else if let quickStartPreset {
            if configuration.sponsorBlock.needsSegmentReview {
                presentsQuickStartConfirmation = false
                presentsConfiguration = true
            } else if quickStartPreset.launchBehavior == .immediate {
                await launchQuickStart()
            } else {
                presentsQuickStartConfirmation = true
            }
        } else if opensFullOptionsAfterAnalysis
            || (settings.experience.skipVideoDetails && !analysisUsesSharedRouting) {
            presentsConfiguration = true
        } else {
            presentsMetadata = true
        }
        opensFullOptionsAfterAnalysis = false
        await diagnostics.record(
            .info,
            subsystem: "extraction",
            event: "metadata_analyzed",
            detail:
                "video_id=\(metadata.videoID), formats=\(metadata.formats.count)"
        )
    }

    private func finishPlaylistAnalysis(
        URL: URL,
        quickStartPreset: QuickStartPreset?, accountID: UUID?
    ) async throws {
        let analysis: PlaylistAnalysis
        if fixtureMode {
            try await Task.sleep(for: .milliseconds(180))
            analysis = DeveloperFixtures.playlist
        } else {
            let analyzer = try await runtime.playlistAnalyzer(accountID: accountID)
            async let analysisValue = analyzer.analyze(
                url: URL,
                maximumEntries: settings.configuration()
                    .maximumPlaylistItems
            )
            async let versionsValue = runtime.extractor().versions()
            analysis = try await analysisValue
            extractionVersions = try? await versionsValue
        }
        var baseConfiguration = quickStartPreset?.configuration
            ?? pendingRedownloadConfiguration
            ?? settings.configuration()
        pendingRedownloadConfiguration = nil
        baseConfiguration.accountID = accountID
        baseConfiguration.selectedVideoFormatID = nil
        baseConfiguration.selectedAudioFormatID = nil
        playlistDraft = PlaylistBatchDraft(
            analysis: analysis,
            configuration: baseConfiguration
        )
        activeQuickStartPreset = nil
        addRecent(
            URL: URL,
            title: analysis.title,
            thumbnailURL: analysis.thumbnailURL
        )
        presentsPlaylistBatch = true
        await diagnostics.record(
            .info,
            subsystem: "extraction",
            event: "playlist_analyzed",
            detail:
                "playlist_id=\(analysis.playlistID), loaded=\(analysis.entries.count)"
        )
    }

    func continuePlaylistSelection() {
        guard var draft = playlistDraft else { return }
        do {
            _ = try draft.resolvedEntries()
            draft.step = .options
            playlistDraft = draft
        } catch {
            alert = .error(error)
        }
    }

    func reloadPlaylistInventory(detailed: Bool = false) {
        guard !isAnalyzing,
              let current = playlistDraft,
              let URL = URL(string: URLText)
        else {
            return
        }
        let limit = current.configuration.maximumPlaylistItems
        isAnalyzing = true
        Task {
            defer { isAnalyzing = false }
            do {
                let analysis: PlaylistAnalysis
                if fixtureMode {
                    try await Task.sleep(for: .milliseconds(120))
                    analysis = DeveloperFixtures.playlist
                } else {
                    let analyzer = try await runtime.playlistAnalyzer(accountID: current.configuration.accountID)
                    analysis = try await analyzer.analyze(
                        url: URL,
                        maximumEntries: limit,
                        detailed: detailed
                    )
                }
                var replacement = PlaylistBatchDraft(
                    analysis: analysis,
                    configuration: current.configuration
                )
                replacement.destinationStructure =
                    current.destinationStructure
                replacement.skipArchivedItems =
                    current.skipArchivedItems
                playlistDraft = replacement
            } catch {
                alert = .error(error)
            }
        }
    }

    func reviewPlaylistBatch() {
        Task { await reviewPlaylistBatchAfterAccessCheck() }
    }

    private func reviewPlaylistBatchAfterAccessCheck() async {
        guard var draft = playlistDraft else { return }
        draft.normalizeConfiguration()
        if [
            ExportDestination.filesFolder,
            .filesAndPhotos,
        ].contains(draft.configuration.destination),
           !(await ensureFilesFolderAccess(presentingFrom: .playlist)) {
            return
        }
        do {
            try validatePlaylistDraft(draft)
            draft.step = .review
            playlistDraft = draft
            refreshAvailableStorage()
        } catch {
            if (error as? PlaylistBatchDraftError)
                == .filesFolderRequired {
                requestFilesFolderPicker(from: .playlist)
            }
            alert = .error(error)
        }
    }

    func returnToPlaylistStep(_ step: PlaylistBatchFlowStep) {
        guard var draft = playlistDraft else { return }
        draft.step = step
        playlistDraft = draft
    }

    func cancelPlaylistBatchFlow() {
        presentsPlaylistBatch = false
        playlistDraft = nil
    }

    func startPlaylistBatch() {
        guard !startupState.blocksInteraction,
              let draft = playlistDraft else { return }
        do {
            try validatePlaylistDraft(draft)
        } catch {
            alert = .error(error)
            return
        }
        Task {
            do {
                _ = try await batchController.createBatch(
                    analysis: draft.analysis,
                    selection: draft.selection,
                    configuration: draft.configuration,
                    itemOverrides: draft.itemOverrides,
                    destinationStructure: draft.destinationStructure,
                    skipArchivedItems: draft.skipArchivedItems
                )
                presentsPlaylistBatch = false
                playlistDraft = nil
                selectedTab = .queue
            } catch {
                alert = .error(error)
            }
        }
    }

    func pause(_ batch: DownloadBatch) {
        Task { await batchController.pause(batch.id) }
    }

    func resume(_ batch: DownloadBatch) {
        Task { await batchController.resume(batch.id) }
    }

    func cancel(_ batch: DownloadBatch) {
        for job in jobs where job.batchMembership?.batchID == batch.id {
            discardActionPresentations(for: job.id)
        }
        Task { await batchController.cancel(batch.id) }
    }

    func retryFailed(in batch: DownloadBatch) {
        Task { await batchController.retryFailed(batch.id) }
    }

    func skip(_ item: DownloadBatchItem, in batch: DownloadBatch) {
        Task {
            await batchController.skipItem(
                batchID: batch.id,
                itemID: item.id
            )
        }
    }

    func clearCompletedItems(in batch: DownloadBatch) {
        Task {
            let childJobIDs = await batchController.dismissCompletedItems(
                batch.id
            )
            await coordinator.removeTerminalJobs(childJobIDs)
        }
    }

    func remove(_ batch: DownloadBatch) {
        packageTasks.removeValue(forKey: batch.id)?.cancel()
        packagingBatchIDs.remove(batch.id)
        Task {
            let childJobIDs = await batchController.remove(batch.id)
            await coordinator.removeTerminalJobs(childJobIDs)
        }
    }

    func retryPackage(for batch: DownloadBatch) {
        guard batch.destinationStructure == .zipArchive,
              batch.state.isTerminal
        else {
            return
        }
        Task { await batchController.retryPackage(batch.id) }
    }

    func isPackaging(_ batch: DownloadBatch) -> Bool {
        packagingBatchIDs.contains(batch.id)
    }

    func removeArchiveEntry(_ entry: DownloadArchiveEntry) {
        Task {
            await batchController.removeArchiveEntry(
                site: entry.site,
                videoID: entry.videoID
            )
        }
    }

    private func validatePlaylistDraft(
        _ draft: PlaylistBatchDraft
    ) throws {
        let selected = try draft.resolvedEntries()
        guard !selected.isEmpty else {
            throw PlaylistModelError.emptySelection
        }
        if draft.configuration.destination == .askEveryTime {
            throw PlaylistBatchDraftError.unsupportedBatchDestination
        }
        if [
            ExportDestination.filesFolder,
            .filesAndPhotos,
        ].contains(draft.configuration.destination),
           snapshot.filesFolderBookmark == nil {
            throw PlaylistBatchDraftError.filesFolderRequired
        }
        let configurations = [draft.configuration]
            + selected.compactMap { draft.itemOverrides[$0.id] }
        if configurations.contains(where: {
            $0.sponsorBlock.needsSegmentReview
        }) {
            throw SponsorBlockPlanningError.previewRequired
        }
        if configurations.contains(where: { $0.mode == .audioOnly }),
           [
               ExportDestination.photos,
               .filesAndPhotos,
           ].contains(draft.configuration.destination) {
            throw IllucetError.photosIncompatible
        }
        if draft.destinationStructure.needsBatchDirectory,
           [
               ExportDestination.photos,
               .share,
           ].contains(draft.configuration.destination) {
            throw PlaylistBatchDraftError.unsupportedBatchDestination
        }
        if draft.destinationStructure == .zipArchive {
            guard [
                ExportDestination.appDocuments,
                .filesFolder,
            ].contains(draft.configuration.destination) else {
                throw PlaylistBatchDraftError
                    .unsupportedBatchDestination
            }
            if settings.duplicateHandling == .ask {
                throw PlaylistBatchDraftError
                    .zipDuplicateDecisionRequired
            }
        }
    }

    func launchQuickStart() async {
        guard activeQuickStartPreset != nil, let claim = claimDownloadSubmission() else { return }
        await performQuickStartLaunch(claim: claim)
    }

    func performQuickStartLaunch(claim: UUID) async {
        var submitted = false
        defer { finishDownloadSubmission(claim, succeeded: submitted) }
        guard downloadSubmissionInFlight == claim, !startupState.blocksInteraction,
              !isStartingQuickStart,
              let analyzedMetadata,
              activeQuickStartPreset != nil
        else {
            return
        }
        if let reason = configuration.sourceModeAvailability(
            in: analyzedMetadata
        ).unavailableReason {
            presentsQuickStartConfirmation = true
            alert = AppAlert(
                title: "Output mode unavailable",
                message: "\(reason) Choose Edit details and select an available output mode."
            )
            return
        }
        isStartingQuickStart = true
        defer { isStartingQuickStart = false }
        refreshAvailableStorage()
        do {
            if [
                ExportDestination.filesFolder,
                .filesAndPhotos,
            ].contains(configuration.destination),
               !(await ensureFilesFolderAccess(
                   presentingFrom: .quickStart
               )) {
                presentsQuickStartConfirmation = true
                return
            }
            try QuickStartLaunchPolicy.validate(
                configuration: configuration,
                metadata: analyzedMetadata,
                hasFilesFolder: filesFolderName != nil,
                availableBytes: storage.availableBytes,
                reserveBytes: settings.minimumFreeSpaceReserveBytes
            )
            let overLimit = try await approveTransferAdmission()
            if let request = activeShortcutRequest, request.url == analyzedMetadata.canonicalURL {
                _ = try await enqueueShortcut(metadata: analyzedMetadata, configuration: configuration,
                    version: extractionVersions?.ytDLP, request: request, transferLimitOverride: overLimit)
                activeShortcutRequest = nil
            } else {
                _ = try await coordinator.enqueue(metadata: analyzedMetadata, configuration: configuration,
                    extractorVersion: extractionVersions?.ytDLP, transferLimitOverride: overLimit)
            }
            submitted = true
            presentsQuickStartConfirmation = false
            activeQuickStartPreset = nil
            selectedTab = .queue
        } catch is CancellationError {
            presentsQuickStartConfirmation = true
        } catch {
            presentsQuickStartConfirmation = true
            if (error as? IllucetError) == .filesDestinationUnavailable {
                requestFilesFolderPicker(from: .quickStart)
            }
            alert = .error(error)
        }
    }

    func useRecent(_ link: RecentLink) {
        cancelQuickStartInputRecovery()
        URLText = link.url.absoluteString
        analyze()
    }

    func receiveDeepLink(_ URL: URL) {
        if URL.scheme?.lowercased() == AppIdentity.URLScheme, URL.host() == "job",
           let id = UUID(uuidString: URL.lastPathComponent) {
            guard !startupState.blocksInteraction else { pendingStartupDeepLink = URL; return }
            selectedTab = .queue
            selectedJob = jobs.first { $0.id == id }
            return
        }
        guard
            URL.scheme?.lowercased() == AppIdentity.URLScheme,
            URL.host()?.lowercased() == "add",
            let mediaValue = URLComponents(
                url: URL,
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: { $0.name == "url" })?.value
        else { return }
        guard !startupState.blocksInteraction else {
            pendingStartupDeepLink = URL
            return
        }
        guard let url = Foundation.URL(string: mediaValue),
              let safe = SharedLinkParser.canonicalURL(url),
              (try? YouTubeURLIntentClassifier.classify(safe)) != nil else { return }
        receiveSharedLink(safe)
    }

    func retryStartupRecovery() {
        guard startupState.recoveryError != nil else { return }
        startupState = .loading
        alert = nil
        Task { await prepare() }
    }

}
