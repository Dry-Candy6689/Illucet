import SwiftUI

@MainActor
extension IllucetAppModel {
    func prepare() async {
        await diagnostics.load()
        do {
            snapshot = try await persistence.load()
        } catch {
            guard (error as? PersistenceError)?.recoveredWithEmptyState == true
            else {
                // Without the saved job list, startup cleanup cannot know
                // which temporary outputs belong to unfinished downloads.
                startupState = .blocked(
                    (error as? PersistenceError) ?? .stateUnavailable
                )
                await coordinator.rejectPendingNativeReceipts()
                return
            }
            snapshot = .empty
            alert = .error(error)
        }
        let restored = IllucetAppPersistedState.restoring(snapshot, resolver: outputResolver)
        lastPreferencesExportAt = snapshot.lastPreferencesExportAt
        settings = restored.settings
        await sponsorBlockDiagnostics.setEnabled(
            settings.sponsorBlockDiagnosticLoggingEnabled
        )
        jobs = restored.jobs
        batches = restored.batches
        downloadArchive = restored.downloadArchive
        history = restored.history
        recentLinks = restored.recentLinks
        quickStartPresets = restored.quickStartPresets
        firstRunState = restored.firstRunState
        updateStatus = restored.updateStatus
        diagnosticEntries = await diagnostics.allEntries()
        if !fixtureMode { await restoreDownloadState() }
        await refreshAccounts()
        if let bookmark = snapshot.filesFolderBookmark {
            do {
                let access = try await exporter.testFolderAccessDetail(
                    bookmark: bookmark
                )
                filesFolderName = updateFilesFolderPresentation(
                    resolved: access.displayName,
                    folderURL: access.folderURL
                )
            } catch {
                await invalidateFilesFolderAccess()
            }
        }
        if fixtureMode {
            if ProcessInfo.processInfo.arguments.contains("--ui-polish-reset") {
                settings = .defaults
                settings.experience.skipVideoDetails = ProcessInfo.processInfo.arguments.contains("--ui-skip-details")
                settings.experience.skipDownloadReview = ProcessInfo.processInfo.arguments.contains("--ui-skip-review")
                settings.experience.instantQuickStart = ProcessInfo.processInfo.arguments.contains("--ui-instant-quick-start")
                if ProcessInfo.processInfo.arguments.contains("--ui-accent=black") {
                    settings.accentColor = .init(red: 0, green: 0, blue: 0)
                } else if ProcessInfo.processInfo.arguments.contains("--ui-accent=white") {
                    settings.accentColor = .init(red: 1, green: 1, blue: 1)
                }
                settings.oledDarkBackground = ProcessInfo.processInfo.arguments.contains("--ui-oled")
            }
            var completedFirstRun = FirstRunState.initial
            completedFirstRun.completeWithoutNotifications()
            firstRunState = completedFirstRun
            // Existing UI fixtures predate the first-paste tip. Opt in only in
            // its focused fixture so unrelated tests keep their original flow.
            firstRunState.pastePermissionTipShown = !ProcessInfo.processInfo.arguments.contains("--ui-first-paste")
            var experiencedPip = PipLocalState()
            let selectionHints = ProcessInfo.processInfo.arguments.contains("--ui-selection-hints")
            experiencedPip.queueSelectionHintShown = !selectionHints
            experiencedPip.historySelectionHintShown = !selectionHints
            experiencedPip.notificationHintShown = true
            firstRunState.pip = experiencedPip
            presentsOnboarding = false
            settings.wifiOnly = true
            if ProcessInfo.processInfo.arguments.contains("--ui-dark-appearance") {
                settings.appearance = .dark
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-light-appearance") {
                settings.appearance = .light
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-clipboard-unexplained") {
                settings.clipboard = ClipboardPreferences()
            }
            quickStartPresets = QuickStartPresetLibrary.defaults
            QuickStartPresetLibrary.migrateLaunchBehavior(settings: &settings, presets: &quickStartPresets)
            URLText = DeveloperFixtures.RickURL.absoluteString
            if ProcessInfo.processInfo.arguments.contains(
                "--ui-folder-unavailable"
            ) {
                snapshot.filesFolderBookmark = Data(
                    "unavailable-folder-bookmark".utf8
                )
                snapshot.filesFolderSelectionIdentity = nil
                snapshot.filesFolderDisplayName = "Unavailable folder"
                snapshot.filesFolderAlias = nil
                snapshot.filesFolderAliasOfferShown = false
                filesFolderName = "Unavailable folder"
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--ui-folder-alias-reset"
            ) {
                snapshot.filesFolderBookmark = nil
                snapshot.filesFolderSelectionIdentity = nil
                snapshot.filesFolderDisplayName = nil
                snapshot.filesFolderAlias = nil
                snapshot.filesFolderAliasOfferShown = false
                filesFolderName = nil
                filesFolderAliasDraft = ""
                filesFolderAliasEditorMode = nil
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--ui-empty-state"
            ) {
                jobs = []
                batches = []
                downloadArchive = []
                history = []
                URLText = ""
            }
            if let tabArgument = ProcessInfo.processInfo.arguments.first(
                where: { $0.hasPrefix("--ui-tab=") }
            )?.split(separator: "=", maxSplits: 1).last,
               let tab = AppTab(
                   rawValue: String(tabArgument).capitalized
               ) {
                selectedTab = tab
            }
            if let screenArgument = ProcessInfo.processInfo.arguments.first(
                where: { $0.hasPrefix("--ui-screen=") }
            )?.split(separator: "=", maxSplits: 1).last {
                let fixtureMetadata = screenArgument == "configuration-large-subtitles"
                    ? DeveloperFixtures.largeSubtitleMedia
                    : screenArgument == "configuration-video-only-source"
                        ? DeveloperFixtures.videoOnlyMedia : DeveloperFixtures.media
                analyzedMetadata = fixtureMetadata
                configuration = OutputCapabilityMatrix.normalized(
                    settings.configuration()
                )
                FormatSelection.applyAutomaticSelection(
                    to: &configuration,
                    metadata: fixtureMetadata
                )
                switch screenArgument {
                case "shortcut-handoff":
                    settings.shortcuts = .init(behavior: .ask)
                    URLText = ""
                    shortcutHandoff = .init(request: .init(id: UUID(), url: DeveloperFixtures.RickURL,
                        createdAt: .now, isShortcutRequest: true), reason: "Choose how to download this link.",
                        prepared: .init(metadata: fixtureMetadata, configuration: configuration, version: nil))
                case "shared-link-choice":
                    settings.sharedLinks = SharedLinkPreferences()
                    pendingSharedLink = DeveloperFixtures.RickURL
                    presentsSharedLinkChoice = true
                case "onboarding":
                    firstRunState = .initial
                    presentsOnboarding = true
                case "updater":
                    selectedTab = .settings
                    settingsNavigationPath = [.updates]
                    settings.updateChannel = .nightly
                    updateStatus = .initial
                    updateStatus.lastCheckedAt = .now
                    updateStatus.lastCheckedChannel = .nightly
                    updateStatus.state = .current
                    updateStatus.message = "You’re up to date on Nightly."
                    if ProcessInfo.processInfo.arguments.contains("--ui-update-installed") {
                        updateStatus.activeChannel = .master
                        updateStatus.activeYTDLPVersion = "2026.11.04.071645"
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-update-offer") {
                        settings.updateChannel = .master
                        updateStatus.lastCheckedChannel = .master
                        updateStatus.state = .updateAvailable
                        updateStatus.message = nil
                        updateStatus.availableRelease = .init(channel: .master, version: "2026.11.04.071645",
                            publishedAt: Date(timeIntervalSince1970: 1_793_776_917))
                    }
                case "pip-first-download":
                    var local = PipLocalState()
                    local.guideFinishedAt = .now
                    local.analyzedFirstVideo = true
                    local.startedFirstDownload = true
                    firstRunState.pip = local
                case "pip-notifications":
                    var local = PipLocalState()
                    local.guideFinishedAt = .now.addingTimeInterval(-120)
                    local.startedFirstDownload = true
                    local.downloadScreensHintShown = true
                    local.queueSelectionHintShown = true
                    local.historySelectionHintShown = true
                    firstRunState.pip = local
                case "metadata":
                    presentsMetadata = true
                case "configuration-large-subtitles":
                    configuration.subtitleDelivery = .sidecarVTT
                    presentsConfiguration = true
                case "configuration":
                    presentsConfiguration = true
                case "navigation-refinement":
                    jobs = (0..<24).map { index in
                        DownloadJob(id: UUID(), sourceURL: DeveloperFixtures.RickURL, videoID: "fixture-\(index)",
                            title: "Sample download \(index + 1)", createdAt: Date(timeIntervalSince1970: Double(index * 60)),
                            updatedAt: .now, configuration: .standard, state: .failed, stage: .complete,
                            progress: .zero, priority: 0, retryCount: 0, maximumRetries: 1, selectedFormatIDs: [])
                    }
                    history = jobs.map(HistoryRecord.init(job:))
                case "transfer-limit":
                    var video = DeveloperFixtures.failedThumbnailOnlyJob
                    video.state = .running; video.stage = .downloadingVideo; video.title = "Video transfer"
                    var audio = DeveloperFixtures.failedSubtitlesOnlyJob
                    audio.configuration = video.configuration
                    audio.state = .running; audio.stage = .downloadingAudio; audio.title = "Audio transfer"
                    jobs = [video, audio]
                    presentsConfirmation = true
                case "configuration-files-and-photos":
                    snapshot.filesFolderBookmark = nil
                    snapshot.filesFolderSelectionIdentity = nil
                    snapshot.filesFolderDisplayName = nil
                    snapshot.filesFolderAlias = nil
                    snapshot.filesFolderAliasOfferShown = false
                    filesFolderName = nil
                    configuration.destination = .filesAndPhotos
                    presentsConfiguration = true
                case "configuration-video-only-source":
                    configuration = OutputCapabilityMatrix.normalized(
                        .standard
                    )
                    FormatSelection.applyAutomaticSelection(
                        to: &configuration,
                        metadata: fixtureMetadata
                    )
                    presentsConfiguration = true
                case "configuration-thumbnail":
                    configuration = OutputCapabilityMatrix.selectingThumbnailBehavior(.thumbnailOnly, in: configuration)
                    presentsConfiguration = true
                case "queue-badge-attention", "queue-badge-downloading", "queue-badge-processing",
                     "queue-badge-waiting", "queue-badge-paused", "queue-badge-completed":
                    var job = DeveloperFixtures.failedThumbnailOnlyJob
                    job.title = "Queue status fixture"
                    job.errorCode = nil; job.errorMessage = nil
                    switch screenArgument {
                    case "queue-badge-attention": job.state = .failed
                    case "queue-badge-downloading": job.state = .running; job.stage = .downloadingThumbnail
                    case "queue-badge-processing": job.state = .running; job.stage = .converting
                    case "queue-badge-waiting": job.state = .waitingForWiFi
                    case "queue-badge-paused": job.state = .paused
                    default: job.state = .completed; job.stage = .complete
                    }
                    selectedTab = .download
                    jobs = [job]; batches = []; history = []
                    if job.state == .completed { unseenQueueCompletions = [job.id] }
                case "photos-incompatible":
                    configuration.mode = .audioOnly
                    configuration.audioCodec = .mp3
                    configuration.destination = .photos
                    configuration = OutputCapabilityMatrix.normalized(
                        configuration
                    )
                    FormatSelection.applyAutomaticSelection(
                        to: &configuration,
                        metadata: fixtureMetadata
                    )
                    presentsConfiguration = true
                case "sponsorblock":
                    var policy = SponsorBlockPolicy(
                        isEnabled: true,
                        selectedCategories: [.sponsor, .intro]
                    )
                    policy.setAction(.remove, for: .sponsor)
                    policy.setAction(.markAsChapter, for: .intro)
                    configuration.sponsorBlock = policy
                    presentsConfiguration = true
                    beginSponsorBlockPreview()
                case "sponsorblock-empty":
                    var policy = SponsorBlockPolicy(isEnabled: true, selectedCategories: [.sponsor])
                    policy.replaceSelection(videoID: fixtureMetadata.videoID,
                        queriedCategories: policy.requestedDiscoveryCategories, segments: [])
                    configuration.sponsorBlock = policy
                    sponsorBlockPreviewState = .empty
                    presentsConfiguration = true
                case "sponsorblock-fast":
                    configuration.thumbnailBehavior = .none
                    configuration.container = .mp4
                    configuration.videoCodec = .h264
                    configuration.audioCodec = .aac
                    FormatSelection.applyAutomaticSelection(
                        to: &configuration,
                        metadata: fixtureMetadata
                    )
                    var policy = SponsorBlockPolicy(
                        isEnabled: true,
                        selectedCategories: [.sponsor]
                    )
                    policy.setAction(.remove, for: .sponsor)
                    configuration.sponsorBlock = policy
                    presentsConfiguration = true
                    beginSponsorBlockPreview()
                case "sponsorblock-loaded-blocker":
                    let duration = fixtureMetadata.durationSeconds ?? 213
                    var policy = SponsorBlockPolicy(
                        isEnabled: true,
                        selectedCategories: [.sponsor]
                    )
                    policy.replaceSelection(
                        videoID: fixtureMetadata.videoID,
                        queriedCategories: policy.requestedDiscoveryCategories,
                        segments: [
                            DeveloperFixtures.sponsorBlockSegments[0],
                            SponsorBlockSegment(
                                segmentID: "fixture-outside-001",
                                category: .sponsor,
                                startSeconds: duration - 1,
                                endSeconds: duration + 10,
                                description: "Outside analyzed duration",
                                submittedVideoDuration: duration + 10,
                                serverAction: .skip,
                                votes: 1,
                                isLocked: false
                            ),
                        ]
                    )
                    configuration.sponsorBlock = policy
                    sponsorBlockPreviewState = .loaded(count: 2)
                    presentsConfiguration = true
                case "sponsorblock-failure-required",
                     "sponsorblock-failure-optional":
                    let required = screenArgument
                        == "sponsorblock-failure-required"
                    var policy = SponsorBlockPolicy(
                        isEnabled: true,
                        selectedCategories: [required ? .sponsor : .intro]
                    )
                    policy.setAction(
                        required ? .remove : .keep,
                        for: required ? .sponsor : .intro
                    )
                    policy.replaceSelection(
                        videoID: fixtureMetadata.videoID,
                        queriedCategories: policy.requestedDiscoveryCategories,
                        segments: [
                            SponsorBlockSegment(
                                segmentID: required
                                    ? "fixture-required-001"
                                    : "fixture-optional-001",
                                category: required ? .sponsor : .intro,
                                startSeconds: 1,
                                endSeconds: 2,
                                description: nil,
                                submittedVideoDuration:
                                    fixtureMetadata.durationSeconds ?? 213,
                                serverAction: .skip,
                                votes: 1,
                                isLocked: false
                            ),
                        ]
                    )
                    configuration.sponsorBlock = policy
                    presentsConfiguration = true
                    beginSponsorBlockPreview()
                case "sponsorblock-history":
                    let job = DeveloperFixtures.sponsorBlockAppliedJob
                    selectedTab = .history
                    jobs = []
                    batches = []
                    history = [HistoryRecord(job: job)]
                case "confirmation":
                    snapshot.filesFolderBookmark = nil
                    snapshot.filesFolderSelectionIdentity = nil
                    snapshot.filesFolderDisplayName = nil
                    snapshot.filesFolderAlias = nil
                    snapshot.filesFolderAliasOfferShown = false
                    filesFolderName = nil
                    configuration.preset = .compatible
                    configuration.container = .mp4
                    configuration.videoCodec = .h264
                    configuration.audioCodec = .aac
                    configuration = OutputCapabilityMatrix.normalized(
                        configuration
                    )
                    FormatSelection.applyAutomaticSelection(
                        to: &configuration,
                        metadata: fixtureMetadata
                    )
                    presentsConfirmation = true
                case "photos-success":
                    var job = DeveloperFixtures.sponsorBlockAppliedJob
                    job.configuration.destination = .photos
                    job.outputURL = nil
                    job.exportOutcome = .photos
                    job.photosAssetLocalIdentifiers = [
                        "fixture-photo-asset",
                    ]
                    handle(.addHistory(HistoryRecord(job: job)))
                case "output-access-relocated", "output-access-external", "output-access-revoked":
                    let fm = FileManager.default
                    let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let relative = "D5-UI-\(UUID())/retained.png"
                    let external = screenArgument != "output-access-relocated"
                    let folder = documents.appending(path: external ? "D5-External" : "Downloads")
                    let actual = folder.appending(path: relative)
                    try? fm.createDirectory(at: actual.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image { renderer in
                        UIColor.systemTeal.setFill()
                        renderer.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
                    }
                    try? image.pngData()?.write(to: actual)
                    var job = DeveloperFixtures.failedThumbnailOnlyJob
                    job.title = external ? "External Output Fixture" : "Retained Output Fixture"
                    job.state = .completed; job.stage = .complete; job.exportOutcome = .file
                    job.errorCode = nil; job.errorMessage = nil
                    job.configuration.destination = external ? .filesFolder : .appDocuments
                    job.outputURL = external ? actual : URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/\(UUID())/Documents/Downloads/" + relative)
                    if external, let bookmark = try? folder.bookmarkData(options: .minimalBookmark) {
                        job.outputReferences = outputResolver.references(for: [actual], folderBookmark: bookmark)
                        if screenArgument == "output-access-revoked" { job.outputReferences?.folderBookmark = Data("revoked-fixture".utf8) }
                    }
                    snapshot.filesFolderBookmark = nil // Access must come from the retained record.
                    selectedTab = .queue
                    jobs = [job]; batches = []; history = [HistoryRecord(job: job)]
                case "history-apple-unsupported", "queue-output-cleanup", "configure-existing-missing":
                    let URL = FileManager.default.temporaryDirectory
                        .appending(path: "Illucet-valid-output.webm")
                    try? Data([0, 1, 2, 3]).write(to: URL)
                    var job = DeveloperFixtures.sponsorBlockAppliedJob
                    job.title = "Valid WebM Fixture"
                    job.configuration.destination = .appDocuments
                    job.configuration.container = .webm
                    job.configuration.videoCodec = .vp9
                    job.outputURL = URL
                    job.outputProbe = MediaProbeResult(
                        fileURL: URL,
                        formatNames: ["matroska", "webm"],
                        formatLongName: "Matroska / WebM",
                        durationSeconds: 10,
                        startTimeSeconds: 0,
                        bitRate: 1_000_000,
                        fileSize: 4,
                        metadata: [:],
                        streams: [],
                        chapters: []
                    )
                    job.exportOutcome = .file
                    let record = HistoryRecord(job: job)
                    selectedTab = .history
                    jobs = []
                    history = [record]
                    if screenArgument == "queue-output-cleanup" {
                        selectedTab = .queue
                        jobs = [job]
                    } else if screenArgument == "configure-existing-missing" {
                        try? FileManager.default.removeItem(at: URL)
                        selectedTab = .download
                        URLText = DeveloperFixtures.RickURL.absoluteString
                        settings.experience.skipVideoDetails = true
                    } else {
                        selectedHistoryRecord = record
                    }
                case "quick-confirmation":
                    if let preset = quickStartPresets.first(where: {
                        $0.configuration.mode == .audioOnly
                    }) {
                        activeQuickStartPreset = preset
                        configuration = (
                            try? preset.resolvedConfiguration(
                                metadata: DeveloperFixtures.media
                            )
                        ) ?? configuration
                        if ProcessInfo.processInfo.arguments.contains(
                            "--ui-quick-files"
                        ) {
                            snapshot.filesFolderBookmark = nil
                            snapshot.filesFolderSelectionIdentity = nil
                            snapshot.filesFolderDisplayName = nil
                            snapshot.filesFolderAlias = nil
                            snapshot.filesFolderAliasOfferShown = false
                            filesFolderName = nil
                            configuration.destination = .filesFolder
                        }
                        presentsQuickStartConfirmation = true
                    }
                case "playlist":
                    URLText = DeveloperFixtures.playlistURL.absoluteString
                    playlistDraft = PlaylistBatchDraft(
                        analysis: DeveloperFixtures.playlist,
                        configuration: settings.configuration()
                    )
                    presentsPlaylistBatch = true
                case "batch-queue":
                    selectedTab = .queue
                    jobs = []
                    batches = [DeveloperFixtures.completedBatch]
                    downloadArchive = DeveloperFixtures.archive
                case "output-truth":
                    let job = DeveloperFixtures.failedThumbnailOnlyJob
                    selectedTab = .queue
                    jobs = [job]
                    batches = []
                    history = [HistoryRecord(job: job)]
                case "queue-progress-stability", "queue-stage-progress":
                    var job = DeveloperFixtures.sponsorBlockAppliedJob
                    job.title = "Download Progress Fixture"
                    // Restore as terminal; the fixture supplies synthetic updates below.
                    job.state = .completed
                    job.stage = .downloadingVideo
                    job.progress = .zero
                    job.progress.totalBytes = 1_000_000_000
                    job.progress.overallFraction = 0.27
                    selectedTab = .queue
                    jobs = [job]
                    batches = []
                    Task { @MainActor [weak self] in
                        let estimates: [Double?] = [nil, 178, 164, 59, 3_601, 25]
                        for tick in 0..<120 {
                            try? await Task.sleep(for: .milliseconds(500))
                            guard let self, let index = self.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                            self.jobs[index].state = .running
                            self.jobs[index].stage = .downloadingVideo
                            self.jobs[index].progress.bytesDownloaded = Int64(tick + 1) * 7_000_000
                            self.jobs[index].progress.sampleCount = 4
                            self.jobs[index].progress.smoothedBytesPerSecond = tick % 2 == 0 ? 900_000 : 125_000_000
                            self.jobs[index].progress.downloadETASeconds = estimates[tick % estimates.count]
                            if screenArgument == "queue-stage-progress" {
                                self.jobs[index].progress.bytesDownloaded = 1_000_000_000
                                if tick >= 12 {
                                    self.jobs[index].stage = .converting
                                    self.jobs[index].progress.processingFraction = 0.4
                                }
                            }
                        }
                    }
                case "queue-background-wait", "queue-transfer-cleanup":
                    var job = DeveloperFixtures.sponsorBlockAppliedJob
                    let waiting = screenArgument == "queue-background-wait"
                    job.title = waiting ? "Background Time Fixture" : "Transfer Cleanup Fixture"
                    job.state = .completed // Synthetic state follows restoration; no transport is admitted.
                    job.stage = waiting ? .waitingForBackgroundTime : .waiting
                    job.thumbnailURL = nil
                    job.progress = .zero
                    selectedTab = .queue
                    jobs = [job]; batches = []; history = []
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard let self, let index = self.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                        self.jobs[index].state = waiting ? .running : .needsAttention
                        self.jobs[index].stage = waiting ? .waitingForBackgroundTime : .waiting
                        if !waiting {
                            self.jobs[index].errorCode = "transfer_cleanup_pending"
                            self.jobs[index].errorMessage = "Waiting for transfer cleanup. Reopen Illucet if it does not finish."
                        }
                    }
                case "queue-slot-wait":
                    var job = DeveloperFixtures.sponsorBlockAppliedJob
                    job.title = "Waiting Transfer Fixture"
                    job.state = .completed // Keep the synthetic fixture out of admission.
                    job.stage = .waitingForTransfer
                    job.thumbnailURL = nil
                    job.progress.bytesDownloaded = 73_400_320
                    job.progress.totalBytes = 104_857_600
                    job.progress.overallFraction = 0.7
                    selectedTab = .queue
                    jobs = [job]
                    batches = []
                    history = []
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard let self, let index = self.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                        self.jobs[index].state = .running
                        self.jobs[index].stage = .waitingForTransfer
                    }
                case "queue-processing-truth":
                    var job = DeveloperFixtures.sponsorBlockAppliedJob
                    job.title = "Processing Metrics Fixture"
                    job.state = .completed
                    job.stage = .verifyingOutput
                    job.progress.bytesDownloaded = 73_400_320
                    job.progress.totalBytes = 104_857_600
                    job.progress.smoothedBytesPerSecond = 8_388_608
                    job.progress.downloadETASeconds = 0
                    job.progress.processingFraction = 0.4
                    job.progress.overallFraction = 0.7
                    job.progress.sampleCount = 5
                    selectedTab = .queue
                    jobs = [job]
                    batches = []
                    history = []
                case "history-export-recovery":
                    var job = DeveloperFixtures.sponsorBlockAppliedJob
                    job.title = "Partial Export Fixture"
                    job.state = .failed
                    job.configuration.thumbnailBehavior = .thumbnailOnly
                    job.configuration.destination = .filesAndPhotos
                    job.sponsorBlockApplication = nil
                    job.outputProbe = nil
                    job.errorMessage = ExportPublicationError.destinationFailed(.photos, "photos_permission_denied").localizedDescription
                    let retained = FileManager.default.temporaryDirectory.appending(path: "D2-retained.png")
                    let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aDU4AAAAASUVORK5CYII=")!
                    try? data.write(to: retained)
                    job.outputURL = retained
                    job.exportOutcome = .file
                    job.pipelineCheckpoint = DownloadPipelineCheckpoint(phase: .exporting)
                    job.pipelineCheckpoint?.publicationPlan = ExportPublicationPlan(items: [
                        ExportPublicationItem(sourceURL: retained, filename: "D2-retained", role: .primary,
                            assetKind: .image, handling: .addNumber)
                    ], probe: nil, destination: .filesAndPhotos, folderBookmark: nil)
                    job.pipelineCheckpoint?.publicationReceipts = [
                        .init(id: "files", destination: .files, state: .committed, fileURLs: [retained]),
                        .init(id: "photos.0", destination: .photos, failureCode: "photos_permission_denied")
                    ]
                    selectedTab = .history
                    jobs = [job]
                    batches = []
                    let record = HistoryRecord(job: job)
                    history = [record]
                    selectedHistoryRecord = record
                case "queue-completed-details":
                    var media = DeveloperFixtures.sponsorBlockAppliedJob
                    media.title = "Completed Media Fixture"
                    media.state = .completed
                    media.stage = .complete
                    media.progress.currentStream = "140"
                    media.progress.processingFraction = 1
                    media.progress.downloadETASeconds = 60
                    var subtitles = DeveloperFixtures.completedSubtitlesOnlyJob
                    subtitles.progress.currentStream = "140"
                    subtitles.progress.processingFraction = nil
                    selectedTab = .queue
                    jobs = [media, subtitles]
                    batches = []
                    history = []
                case "runtime-proof-inspection":
                    selectedTab = .settings
                    stage0Report = DeveloperFixtures
                        .runtimeProofInspectionReport
                case "subtitles-output-truth":
                    let failed = DeveloperFixtures.failedSubtitlesOnlyJob
                    let completed = DeveloperFixtures.completedSubtitlesOnlyJob
                    selectedTab = .queue
                    jobs = [failed, completed]
                    batches = []
                    history = [
                        HistoryRecord(job: failed),
                        HistoryRecord(job: completed),
                    ]
                case "download-archive":
                    selectedTab = .queue
                    jobs = []
                    batches = [DeveloperFixtures.completedBatch]
                    downloadArchive = DeveloperFixtures.archive
                    presentsDownloadArchive = true
                case "duplicate":
                    enqueuePresentation(.duplicate(DuplicateConflict(
                        jobID: UUID(),
                        videoID: DeveloperFixtures.media.videoID,
                        desiredURL: FileManager.default.temporaryDirectory
                            .appending(path: "Never Gonna Give You Up.mp4"),
                        playlistItemID: nil
                    )))
                case "duplicate-queue":
                    let names = [
                        "Alpha Existing.mp4",
                        "Beta Existing.mp4",
                        "Gamma Existing.mp4",
                    ]
                    for (index, name) in names.enumerated() {
                        let conflict = DuplicateConflict(
                            id: UUID(
                                uuidString:
                                    "00000000-0000-0000-0000-00000000010\(index)"
                            )!,
                            jobID: UUID(),
                            videoID: DeveloperFixtures.media.videoID,
                            desiredURL: FileManager.default.temporaryDirectory
                                .appending(path: name),
                            playlistItemID: nil
                        )
                        enqueuePresentation(.duplicate(conflict))
                    }
                case "share", "share-queue":
                    let fixtureCount = screenArgument == "share" ? 1 : 3
                    for index in 0..<fixtureCount {
                        let jobID = UUID(
                            uuidString:
                                "00000000-0000-0000-0000-00000000020\(index)"
                        )!
                        let title = fixtureCount == 1
                            ? "Illucet Share Fixture"
                            : "Illucet Share Fixture \(index + 1)"
                        let source = FileManager.default.temporaryDirectory
                            .appending(path: "\(title).txt")
                        try? Data(title.utf8).write(
                            to: source,
                            options: .atomic
                        )
                        if let result = try? await exporter.export(
                            sourceURL: source,
                            destination: .share,
                            filename: title,
                            folderBookmark: nil,
                            duplicateHandling: .addNumber,
                            videoID: DeveloperFixtures.media.videoID,
                            jobID: jobID,
                            title: title,
                            assetKind: .image
                        ), let request = result.shareRequest {
                            enqueuePresentation(.share(request))
                        }
                        try? FileManager.default.removeItem(at: source)
                    }
                case "cellular":
                    enqueuePresentation(
                        .network(
                            NetworkAccessRequest(
                                id: UUID(
                                    uuidString:
                                        "00000000-0000-0000-0000-000000000301"
                                )!,
                                jobID: UUID(),
                                title: DeveloperFixtures.media.title,
                                reason: .cellular
                            )
                        )
                    )
                default:
                    break
                }
            }
        } else {
            presentsOnboarding = firstRunState.shouldPresentOnboarding
        }
        if !fixtureMode { await refreshExtractorStatus() }
        // Keep this presentation fixture's two distinct transfer stages frozen;
        // no network or coordinator execution is part of its UI assertion.
        if fixtureMode && !ProcessInfo.processInfo.arguments.contains("--ui-screen=transfer-limit") { await restoreDownloadState() }
        if settings.automaticallyCleanTemporaryFiles {
            let cutoff = Date.now.addingTimeInterval(
                -Double(max(1, settings.autoCleanupDays)) * 86_400
            )
            _ = try? await storageManager.clearTemporaryFiles(
                olderThan: cutoff,
                excludingJobIDs: protectedTemporaryJobIDs
            )
        }
        let pendingShares = history.filter {
            $0.shareCompletionState == .pending
        }.sorted {
            $0.completedAt < $1.completedAt
        }
        var repairedMissingShare = false
        for pending in pendingShares {
            let restored = await coordinator.presentPendingShare(
                jobID: pending.jobID,
                title: pending.title
            )
            if !restored,
               let index = history.firstIndex(where: {
                   $0.jobID == pending.jobID
               }) {
                history[index].shareCompletionState = .failed
                history[index].shareErrorMessage =
                    "The staged share files are no longer available."
                history[index].exportOutcome = .shareFailed
                repairedMissingShare = true
            }
        }
        if repairedMissingShare {
            scheduleSave()
        }
        await refreshStorage()
        updateIdleTimer()
        startupState = .ready
        scheduleSave()
        if let deepLink = pendingStartupDeepLink {
            pendingStartupDeepLink = nil
            receiveDeepLink(deepLink)
        }
        refreshSharedLinks()
        if UIApplication.shared.applicationState == .active { await refreshQueueOnActivation() }
        await checkClipboardOnActivation()
    }
    private func restoreDownloadState() async {
        await coordinator.configure(
            settings: settings,
            folderBookmark: snapshot.filesFolderBookmark
        )
        await coordinator.setPublicationWriter { [weak self] job in
            guard let self else { throw ExportPublicationError.persistenceUnavailable }
            try await self.persistPublicationCheckpoint(job)
        }
        // Badge fixtures contain display-only running jobs, with no real
        // transport checkpoint. Production restoration must still reject those.
        let usesSyntheticQueueBadge = fixtureMode && ProcessInfo.processInfo.arguments.contains {
            $0.hasPrefix("--ui-screen=queue-badge-")
        }
        await coordinator.restore(usesSyntheticQueueBadge ? [] : jobs)
        let restoredJobs = await coordinator.currentJobs()
        if !usesSyntheticQueueBadge { jobs = restoredJobs }
        await batchController.restore(
            batches,
            jobs: restoredJobs,
            archive: downloadArchive
        )
    }

}
