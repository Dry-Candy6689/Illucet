import Foundation
import Testing
@testable import Illucet

struct UsabilityCleanupTests {
    @Test(arguments: [true, false])
    func chronologicalQueueOrderDoesNotChangeWhenAJobFinishes(newestFirst: Bool) throws {
        func dated<T: Codable>(_ value: T, id: UUID, at date: Double) throws -> T {
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            json["id"] = id.uuidString
            json["createdAt"] = date
            return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
        }
        var older = try dated(DeveloperFixtures.failedThumbnailOnlyJob, id: UUID(), at: 100)
        var newer = try dated(DeveloperFixtures.sponsorBlockAppliedJob, id: UUID(), at: 300)
        var batch = try dated(DeveloperFixtures.completedBatch, id: UUID(), at: 200)
        older.state = .completed
        newer.state = .running
        newer.priority = 99
        batch.state = .running
        var child = try dated(newer, id: UUID(), at: 400)
        child.batchMembership = .init(batchID: batch.id, playlistID: batch.playlistID,
            entryID: "child", playlistTitle: batch.title, playlistIndex: 1,
            playlistItemCount: 1, filenameIndexWidth: 2, relativeOutputDirectory: nil)
        let jobs = [older, child, newer]
        let entries = BatchQueueOrdering.chronologicalEntries(jobs: jobs, batches: [batch], newestFirst: newestFirst)
        let expected = ["job.\(older.id.uuidString)", "batch.\(batch.id.uuidString)", "job.\(newer.id.uuidString)"]
        #expect(entries.map(\.id) == (newestFirst ? Array(expected.reversed()) : expected))
        newer.state = .completed
        newer.updatedAt = .distantFuture
        batch.state = .completed
        #expect(BatchQueueOrdering.chronologicalEntries(jobs: [newer, child, older], batches: [batch],
            newestFirst: newestFirst).map(\.id) == entries.map(\.id))
        #expect(jobs[2].priority == 99)
    }

    @Test @MainActor
    func recommendedDownloadScreensOnlyResetTheTwoScreenPreferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        await model.startupTask?.value
        defer { model.saveTask?.cancel() }
        var settings = model.settings
        settings.experience = .init(skipVideoDetails: true, skipDownloadReview: true, instantQuickStart: true)
        settings.preferredAudioCodec = .mp3
        settings.fastStartMP4 = true
        settings.appearance = .dark
        settings.maximumSimultaneousDownloads = 4
        settings.cropArtworkSquare = false
        model.settings = settings
        let presets = model.quickStartPresets
        model.applyRecommendedDownloadScreens()
        settings.experience.skipVideoDetails = false
        settings.experience.skipDownloadReview = false
        #expect(model.settings == settings)
        #expect(model.quickStartPresets == presets)
    }

    @Test
    func artworkDefaultSurvivesSettingsBackupAndLegacySettingsStayCompatible() throws {
        var settings = AppSettings.defaults
        #expect(settings.configuration().cropArtworkSquare)
        settings.thumbnailBehavior = .thumbnailOnly
        #expect(!settings.configuration().cropArtworkSquare)
        for square in [false, true] {
            settings.cropArtworkSquare = square
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            #expect(restored.configuration().cropArtworkSquare == square)
            let backup = PreferencesBackup(settings: settings, presets: QuickStartPresetLibrary.defaults)
            #expect(try PreferencesBackup.decode(backup.encoded()).settings.cropArtworkSquare == square)
        }
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        old.removeValue(forKey: "cropArtworkSquare")
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(restored.cropArtworkSquare == nil)
        #expect(!restored.configuration().cropArtworkSquare)
    }

    @Test @MainActor
    func badgeContrastFollowsTheActualAccentIncludingAdaptiveExtremes() {
        #expect(!IllucetPalette(dark: false).badgeUsesDarkText)
        #expect(IllucetPalette(dark: true).badgeUsesDarkText)
        #expect(IllucetPalette(selected: .init(red: 1, green: 1, blue: 1), dark: true).badgeUsesDarkText)
        #expect(!IllucetPalette(selected: .init(red: 1, green: 1, blue: 1), dark: false).badgeUsesDarkText)
        #expect(IllucetPalette(selected: .init(red: 0, green: 0, blue: 0), dark: true).badgeUsesDarkText)
        #expect(!IllucetPalette(selected: .init(red: 0, green: 0, blue: 0), dark: false).badgeUsesDarkText)
    }

    @Test
    func standaloneThumbnailDefaultsPreserveFullImageAndExplicitSavedCrop() throws {
        let media = DownloadConfiguration.standard
        #expect(media.cropArtworkSquare)
        var thumbnail = OutputCapabilityMatrix.selectingThumbnailBehavior(.thumbnailOnly, in: media)
        #expect(!thumbnail.cropArtworkSquare)
        #expect(thumbnail.thumbnailFormat == .original)
        thumbnail.cropArtworkSquare = true
        let restored = try JSONDecoder().decode(DownloadConfiguration.self, from: JSONEncoder().encode(thumbnail))
        #expect(OutputCapabilityMatrix.normalized(restored).cropArtworkSquare)
        #expect(OutputCapabilityMatrix.selectingThumbnailBehavior(.thumbnailOnly, in: restored).cropArtworkSquare)
        let switched = OutputCapabilityMatrix.selectingMode(.audioOnly, in: restored)
        #expect(!OutputCapabilityMatrix.selectingThumbnailBehavior(.thumbnailOnly, in: switched).cropArtworkSquare)
        let stock = try #require(QuickStartPresetLibrary.defaults.first { $0.name == "Thumbnail" })
        #expect(try !stock.resolvedConfiguration(metadata: DeveloperFixtures.media).cropArtworkSquare)
    }

    @Test
    func uncroppedStockMigrationPreservesCustomizedPresetsAndReferences() {
        var previous = QuickStartPresetLibrary.defaults
        previous[3].configuration.cropArtworkSquare = true
        #expect(QuickStartPresetLibrary.migratingStockPresets(previous, referencedID: previous[3].id)
            == QuickStartPresetLibrary.defaults)
        var customized = previous
        customized[3].name = "My square artwork"
        #expect(QuickStartPresetLibrary.migratingStockPresets(customized, referencedID: customized[3].id) == customized)
        #expect(QuickStartPresetLibrary.migratingStockPresets(Array(previous.reversed()), referencedID: nil)
            == Array(previous.reversed()))
    }

    @Test
    func embeddedVideoThumbnailIsExplicitAndPreservesLegacySidecarChoices() throws {
        var config = DownloadConfiguration.standard
        config.container = .mp4
        config.bundleStyle = .mediaOnly
        config.thumbnailBehavior = .none
        config = OutputCapabilityMatrix.normalized(config)
        FormatSelection.applyAutomaticSelection(to: &config, metadata: DeveloperFixtures.media)
        let withoutCover = try #require(FormatSelection.estimatedTemporaryBytes(configuration: config, metadata: DeveloperFixtures.media))
        let outputBytes = try #require(FormatSelection.estimatedOutputBytes(configuration: config, metadata: DeveloperFixtures.media))
        config.thumbnailBehavior = .includeVideoThumbnail
        #expect(OutputCapabilityMatrix.normalized(config).thumbnailBehavior == .includeVideoThumbnail)
        try OutputCapabilityMatrix.validate(config, metadata: DeveloperFixtures.media)
        #expect(!config.savesThumbnailSeparately)
        #expect(FormatSelection.estimatedTemporaryBytes(configuration: config, metadata: DeveloperFixtures.media)
            == StorageByteArithmetic.adding(withoutCover, outputBytes))
        config.bundleStyle = .mediaAndThumbnail
        #expect(OutputCapabilityMatrix.normalized(config).thumbnailBehavior == .includeVideoThumbnail)
        #expect(config.savesThumbnailSeparately)
        config.bundleStyle = .mediaOnly
        config.container = .mkv
        #expect(throws: (any Error).self) {
            try OutputCapabilityMatrix.validate(config, metadata: DeveloperFixtures.media)
        }
        config.thumbnailBehavior = .separate
        #expect(OutputCapabilityMatrix.normalized(config).thumbnailBehavior == .separate)
        let decoded = try JSONDecoder().decode(ThumbnailBehavior.self, from: JSONEncoder().encode(ThumbnailBehavior.separate))
        #expect(decoded == .separate)
        #expect(config.savesThumbnailSeparately)
    }

    @Test
    func nonMediaDownloadsIgnoreSponsorBlockAndPreserveMediaPreference() throws {
        var original = DownloadConfiguration.standard
        original.destination = .appDocuments
        original.bundleStyle = .mediaOnly
        original.sponsorBlock = SponsorBlockPolicy(isEnabled: true, selectedCategories: [.sponsor])
        original.sponsorBlock.setAction(.remove, for: .sponsor)
        original.sponsorBlock.removalMode = .fastKeyframe
        for thumbnail in [false, true] {
            var config = thumbnail
                ? OutputCapabilityMatrix.selectingThumbnailBehavior(.thumbnailOnly, in: original)
                : OutputCapabilityMatrix.selectingSubtitlesOnly(in: original)
            if !thumbnail {
                config.subtitleDelivery = .sidecarVTT
                config.subtitleSelections = [try #require(SubtitleSelectionPlanner.defaultEnglishSelection(in: DeveloperFixtures.media.subtitles))]
            }
            config = OutputCapabilityMatrix.normalized(config)
            #expect(config.effectiveSponsorBlock == .disabled)
            #expect(config.sponsorBlock == original.sponsorBlock)
            #expect(SponsorBlockReviewState.resolve(policy: original.sponsorBlock, previewState: .loading,
                metadata: DeveloperFixtures.media, configuration: config) == .ready)
            try QuickStartLaunchPolicy.validate(configuration: config, metadata: DeveloperFixtures.media,
                hasFilesFolder: false, availableBytes: nil, reserveBytes: 0)
            let restored = OutputCapabilityMatrix.selectingMode(.videoAndAudio, in: config)
            #expect(restored.effectiveSponsorBlock == original.sponsorBlock)
        }
    }

    @Test
    func englishSubtitleDefaultPrefersManualThenExactLanguageAndNeverOtherLanguages() throws {
        func track(_ id: String, _ language: String, _ automatic: Bool, _ ext: String = "vtt") -> MediaSubtitleTrack {
            MediaSubtitleTrack(trackID: id, language: language, name: nil, automatic: automatic,
                formats: [MediaSubtitleFormat(formatID: id + "-format", url: URL(string: "https://example.invalid/captions")!, extension: ext, name: nil)])
        }
        let exact = track("manual", "en", false)
        let variant = track("variant", "en-GB", false)
        let auto = track("auto", "en", true)
        let french = track("french", "fr", false)
        #expect(SubtitleSelectionPlanner.defaultEnglishSelection(in: [auto, variant, exact])?.trackID == exact.trackID)
        #expect(SubtitleSelectionPlanner.defaultEnglishSelection(in: [auto, variant])?.trackID == variant.trackID)
        #expect(SubtitleSelectionPlanner.defaultEnglishSelection(in: [french, auto])?.trackID == auto.trackID)
        #expect(SubtitleSelectionPlanner.defaultEnglishSelection(in: [french, track("unsupported", "en", false, "json")]) == nil)
    }

    @Test
    func quickStartWithSubtitlesEnabledDefaultsToEnglish() throws {
        var config = DownloadConfiguration.standard
        config.subtitleDelivery = .sidecarVTT
        config.subtitleSelections = nil
        let preset = QuickStartPreset(name: "English", systemImage: "captions.bubble", configuration: config)
        let resolved = try preset.resolvedConfiguration(metadata: DeveloperFixtures.media)
        #expect(resolved.subtitleSelections?.first?.language == "en")
        #expect(resolved.subtitleSelections?.first?.automatic == false)
    }

    @Test
    func oldSeparateThumbnailDefaultsMigrateWithoutChangingSavedConfigurations() throws {
        for behavior in [ThumbnailBehavior.separate, .separateAndEmbed] {
            var settings = AppSettings.defaults
            settings.thumbnailBehavior = behavior
            #expect(OutputCapabilityMatrix.normalized(settings).thumbnailBehavior == .none)
            var saved = DownloadConfiguration.standard
            saved.thumbnailBehavior = behavior
            let decoded = try JSONDecoder().decode(DownloadConfiguration.self, from: JSONEncoder().encode(saved))
            #expect(decoded.thumbnailBehavior == behavior)
        }
    }

    @Test @MainActor
    func historyFileDeletionRefreshesUsageAndKeepsActiveJobs() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "HistoryModel-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        defer { model.saveTask?.cancel() }
        for _ in 0..<200 where model.startupState.blocksInteraction { try await Task.sleep(for: .milliseconds(20)) }
        let file = root.appending(path: "saved.jpg")
        try Data([1, 2, 3]).write(to: file)
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.state = .running
        job.outputURL = file
        let record = HistoryRecord(job: job)
        model.jobs = [job]
        model.history = [record]
        await model.removeHistoryRecords([record.id], includingFiles: true)
        #expect(model.history.count == 1 && fm.fileExists(atPath: file.path))
        job.state = .completed
        model.jobs = [job]
        await model.refreshStorage()
        let previous = try #require(model.storageRefreshedAt)
        await model.removeHistoryRecords([record.id], includingFiles: true)
        #expect(model.history.isEmpty && !fm.fileExists(atPath: file.path))
        #expect(try #require(model.storageRefreshedAt) > previous)
        #expect(!model.isRefreshingStorage && !model.isRemovingHistoryFiles)
    }

    @Test
    func deletingIllucetDownloadsRemovesOrphansAndKeepsOtherData() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "StorageCleanup-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let downloads = root.appending(path: "Downloads")
        try fm.createDirectory(at: downloads.appending(path: "Bundle"), withIntermediateDirectories: true)
        let settings = root.appending(path: "settings.json")
        try Data(repeating: 0, count: 20).write(to: settings)
        try Data(repeating: 0, count: 600).write(to: downloads.appending(path: "orphan.mp4"))
        try Data(repeating: 0, count: 30).write(to: downloads.appending(path: "Bundle/subtitles.vtt"))
        try fm.createSymbolicLink(at: downloads.appending(path: "outside"), withDestinationURL: settings)
        let storage = StorageManager(documentsURL: root)
        #expect(await storage.snapshot().mediaBytes == 600)
        let exporter = ExportManager(documentsRootURL: downloads)
        #expect(try await exporter.deleteAppDownloads() == 3)
        #expect(fm.fileExists(atPath: settings.path))
        let refreshed = await storage.snapshot()
        #expect(refreshed.appDocumentsBytes == 20 && refreshed.mediaBytes == 0)
        #expect(try await exporter.deleteAppDownloads() == 0)
    }

    @Test
    func historyCleanupRemovesExactFilesAndOnlySelectedInactiveTemporaryJobs() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "HistoryCleanup-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let downloads = root.appending(path: "Downloads")
        let temporary = root.appending(path: "tmp")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.configuration.destination = .appDocuments
        var record = HistoryRecord(job: job)
        let output = downloads.appending(path: "thumbnail.jpg")
        try Data(repeating: 0, count: 90).write(to: output)
        record.fileURL = output
        let other = UUID()
        for id in [job.id, other] {
            let folder = temporary.appending(path: "Illucet-\(id.uuidString)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 100).write(to: folder.appending(path: "source.bin"))
        }
        let storage = StorageManager(documentsURL: downloads, temporaryURL: temporary)
        let report = temporary.appending(path: "Illucet-Diagnostics-\(UUID())")
        try fm.createDirectory(at: report, withIntermediateDirectories: true)
        try Data([1]).write(to: report.appending(path: "report.txt"))
        let result = HistoryFileRemoval.remove(records: [record])
        #expect(result.removedRecordIDs == [record.id])
        #expect(!fm.fileExists(atPath: output.path))
        let protected = try await storage.clearTemporaryFiles(excludingJobIDs: [job.id], onlyJobIDs: [job.id])
        #expect(protected.removedDirectories == 0)
        let cleared = try await storage.clearTemporaryFiles(onlyJobIDs: [job.id])
        #expect(cleared.removedDirectories == 1)
        #expect(await storage.snapshot().temporaryBytes == 101)
        // History cleanup is job-specific; general cleanup still removes old reports.
        #expect(fm.fileExists(atPath: report.path))
        _ = try await storage.clearTemporaryFiles(excludingJobIDs: [other])
        #expect(!fm.fileExists(atPath: report.path))
        #expect(await storage.snapshot().temporaryBytes == 100)
        #expect(HistoryFileRemoval.remove(records: [record]).removedRecordIDs == [record.id])
    }

    @Test
    func historyDeletionRebasesRelocatedSandboxWithoutFollowingEscapingLinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "Relocated-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let downloads = root.appending(path: "Downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let actual = downloads.appending(path: "saved.jpg")
        try Data([1]).write(to: actual)
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.configuration.destination = .appDocuments
        var record = HistoryRecord(job: job)
        let old = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/\(UUID())/Documents/Downloads")
        record.fileURL = old.appending(path: "saved.jpg")
        #expect(HistoryFileRemoval.remove(records: [record], documentsURL: root).removedRecordIDs == [record.id])
        #expect(!fm.fileExists(atPath: actual.path))
        let external = root.appending(path: "keep.jpg")
        try Data([2]).write(to: external)
        try fm.createSymbolicLink(at: downloads.appending(path: "escape"), withDestinationURL: root)
        record.fileURL = old.appending(path: "escape/keep.jpg")
        #expect(HistoryFileRemoval.remove(records: [record], documentsURL: root).failedRecordIDs == [record.id])
        #expect(fm.fileExists(atPath: external.path))
    }

    @Test
    func storageCapacityPreflightDoesNotRequireAnExistingDocumentsTree() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Usage-\(UUID().uuidString)")
        let storage = StorageManager(documentsURL: root, capacity: { _ in 1000 })
        try storage.preflight(requiredBytes: 600, reserveBytes: 400)
        #expect(throws: (any Error).self) { try storage.preflight(requiredBytes: 601, reserveBytes: 400) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 123).write(to: root.appending(path: "movie.MP4"))
        try Data(repeating: 2, count: 17).write(to: root.appending(path: "notes.txt"))
        let snapshot = await storage.snapshot()
        #expect(snapshot.appDocumentsBytes == 140)
        #expect(snapshot.mediaBytes == 123)
        #expect(snapshot.availableBytes == 1000)
    }

    @Test @MainActor
    func delayedProgressCannotRollBackForegroundSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        defer { model.saveTask?.cancel() }
        for _ in 0..<200 where model.startupState.blocksInteraction { try await Task.sleep(for: .milliseconds(20)) }
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.state = .running; job.stage = .downloadingVideo
        job.progress.totalBytes = 100; job.progress.bytesDownloaded = 65
        job.updatedAt = Date(timeIntervalSince1970: 100)
        model.jobs = [job]; model.selectedJob = job
        var stale = job; stale.updatedAt = Date(timeIntervalSince1970: 90)
        stale.progress.bytesDownloaded = 55
        model.handle(.upsertJob(stale))
        #expect(model.jobs.first?.progress.bytesDownloaded == 65)
        #expect(model.selectedJob?.progress.bytesDownloaded == 65)
        job.progress.bytesDownloaded = 70; job.updatedAt = Date(timeIntervalSince1970: 110)
        model.handle(.upsertJob(job))
        #expect(model.jobs.first?.progress.bytesDownloaded == 70)
    }

    #if DEBUG
    @Test @MainActor
    func subtitlesDefaultOnlyWhenEnabledAndRespectExplicitSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        defer { model.saveTask?.cancel(); model.sponsorBlockPreviewTask?.cancel() }
        for _ in 0..<200 where model.startupState.blocksInteraction { try await Task.sleep(for: .milliseconds(20)) }
        model.analyzedMetadata = DeveloperFixtures.media
        model.configuration = .standard
        model.configuration.subtitleDelivery = .none
        model.selectDefaultSubtitlesIfNeeded()
        #expect(model.configuration.subtitleSelections == nil)
        model.selectSubtitleDelivery(.sidecarVTT)
        #expect(model.configuration.subtitleSelections?.first?.language == "en")
        #expect(model.configuration.subtitleSelections?.first?.automatic == false)
        model.configuration.subtitleSelections = []
        model.selectDefaultSubtitlesIfNeeded()
        #expect(model.configuration.subtitleSelections == [])
        let custom = SubtitleTrackSelection(trackID: "custom", formatID: "custom", language: "fr", automatic: false)
        model.configuration.subtitleSelections = [custom]
        model.selectDefaultSubtitlesIfNeeded()
        #expect(model.configuration.subtitleSelections == [custom])
    }

    @Test @MainActor
    func automaticClipboardChecksRespectDraftsBusyStateAndChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        await model.startupTask?.value
        defer { model.saveTask?.cancel(); model.sponsorBlockPreviewTask?.cancel() }
        for _ in 0..<200 where model.startupState.blocksInteraction { try await Task.sleep(for: .milliseconds(20)) }
        model.settings.clipboard = ClipboardPreferences(enabled: true, checkAtStartup: true, explained: true, behavior: .suggest)
        model.URLText = "draft"
        await model.checkClipboardOnActivation(changeCount: 1)
        #expect(model.lastAutomaticClipboardChange == nil)
        #expect(model.URLText == "draft")
        model.URLText = ""
        model.presentsConfiguration = true
        await model.checkClipboardOnActivation(changeCount: 1)
        #expect(model.lastAutomaticClipboardChange == nil)
        model.presentsConfiguration = false
        await model.checkClipboardOnActivation(changeCount: 1)
        #expect(model.clipboardSuggestion == DeveloperFixtures.RickURL)
        model.clipboardSuggestion = nil
        await model.checkClipboardOnActivation(changeCount: 1)
        #expect(model.clipboardSuggestion == nil)
        model.settings.clipboard?.behavior = .fill
        await model.checkClipboardOnActivation(changeCount: 2)
        #expect(model.URLText == DeveloperFixtures.RickURL.absoluteString)
        #expect(!model.isAnalyzing)
        #expect(model.jobs.isEmpty)
        model.URLText = ""
        model.settings.clipboard?.enabled = false
        await model.checkClipboardOnActivation(changeCount: 3)
        #expect(model.URLText.isEmpty)
        #expect(model.lastAutomaticClipboardChange == 2)
    }

    @Test @MainActor
    func automaticClipboardReplacesOnlyDifferentSupportedLinksWhenAllowed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        await model.startupTask?.value
        defer { model.saveTask?.cancel() }
        for _ in 0..<200 where model.startupState.blocksInteraction { try await Task.sleep(for: .milliseconds(20)) }
        model.settings.clipboard = ClipboardPreferences(enabled: true, checkAtStartup: true, explained: true, behavior: .fill)
        model.URLText = ""
        var revision = 1
        var candidate = false
        var text: String? = nil
        var reads = 0
        var detections = 0
        let access = ClipboardAccess(changeCount: { revision }, containsURL: { detections += 1; return candidate },
            readText: { reads += 1; return text }, isActive: { true })
        await model.checkClipboardOnActivation(access: access)
        revision += 1; text = "Ordinary copied text"
        await model.checkClipboardOnActivation(access: access)
        #expect(reads == 0)
        revision += 1; candidate = true; text = "https://www.amazon.com/item"
        await model.checkClipboardOnActivation(access: access)
        #expect(reads == 1)
        #expect(model.URLText.isEmpty)
        revision += 1; text = DeveloperFixtures.RickURL.absoluteString
        await model.checkClipboardOnActivation(access: access)
        #expect(reads == 2)
        #expect(model.URLText == text)
        await model.checkClipboardOnActivation(access: access)
        #expect(reads == 2)
        revision += 1
        text = "https://youtu.be/dQw4w9WgXcQ?si=different-share"
        await model.checkClipboardOnActivation(access: access)
        #expect(reads == 3)
        #expect(model.URLText == DeveloperFixtures.RickURL.absoluteString)
        revision += 1
        text = "https://youtu.be/N94KCRua7NE"
        await model.checkClipboardOnActivation(access: access)
        #expect(reads == 4)
        #expect(model.URLText == text)
        #expect(detections == 6)

        model.settings.clipboard?.replacesExistingURL = false
        revision += 1
        text = DeveloperFixtures.RickURL.absoluteString
        await model.checkClipboardOnActivation(access: access)
        #expect(reads == 4)
        #expect(model.URLText == "https://youtu.be/N94KCRua7NE")
        model.URLText = ""
        await model.checkClipboardOnActivation(access: access)
        #expect(reads == 5)
        #expect(model.URLText == text)
    }

    @Test @MainActor
    func delayedClipboardDetectionCannotReadAfterContextChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        await model.startupTask?.value
        defer { model.saveTask?.cancel() }
        for _ in 0..<200 where model.startupState.blocksInteraction { try await Task.sleep(for: .milliseconds(20)) }
        for scenario in 0..<8 {
            model.settings.clipboard = ClipboardPreferences(enabled: true, checkAtStartup: true, explained: true, behavior: .fill)
            model.URLText = ""
            model.presentsConfiguration = false
            model.replaysPipGuide = false
            model.lastAutomaticClipboardChange = nil
            var revision = 1
            var active = true
            var reads = 0
            var continuation: CheckedContinuation<Bool, any Error>?
            let access = ClipboardAccess(changeCount: { revision }, containsURL: {
                try await withCheckedThrowingContinuation { continuation = $0 }
            }, readText: { reads += 1; return DeveloperFixtures.RickURL.absoluteString }, isActive: { active })
            let check = Task { await model.checkClipboardOnActivation(access: access) }
            for _ in 0..<100 where continuation == nil { await Task.yield() }
            let pending = try #require(continuation)
            switch scenario {
            case 0: model.URLText = "typed while checking"
            case 1: model.presentsConfiguration = true
            case 2: revision += 1
            case 3: active = false
            case 4: model.settings.clipboard?.enabled = false
            case 5: check.cancel()
            case 6: model.replaysPipGuide = true
            default:
                model.URLText = "edited then cleared"
                model.URLText = ""
            }
            pending.resume(returning: true)
            await check.value
            #expect(reads == 0)
            #expect(model.URLText == (scenario == 0 ? "typed while checking" : ""))
        }
    }

    @Test @MainActor
    func clipboardSuggestionUsesExistingValidFieldAndExpiresWhenEdited() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        defer { model.saveTask?.cancel() }
        await model.startupTask?.value
        model.settings.clipboard = ClipboardPreferences(enabled: true, checkAtStartup: true, explained: true)
        model.URLText = "https://youtu.be/N94KCRua7NE"
        await model.checkClipboardOnActivation(changeCount: 1)
        #expect(model.clipboardSuggestion == DeveloperFixtures.RickURL)
        #expect(model.URLText == "https://youtu.be/N94KCRua7NE")
        model.acceptClipboardSuggestion()
        #expect(model.URLText == DeveloperFixtures.RickURL.absoluteString)
        #expect(!model.isAnalyzing)
        model.URLText = "https://youtu.be/N94KCRua7NE"
        await model.checkClipboardOnActivation(changeCount: 2)
        #expect(model.clipboardSuggestion != nil)
        model.URLText = "draft"
        model.acceptClipboardSuggestion()
        #expect(model.URLText == "draft")
        #expect(model.clipboardSuggestion == nil)
    }

    @Test @MainActor
    func sharedRoutingTakesPrecedenceOverHomeShortcuts() async throws {
        for behavior in [SharedLinkBehavior.analyze, .options, .presetConfirmation] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
            for _ in 0..<200 where model.startupState.blocksInteraction { try await Task.sleep(for: .milliseconds(20)) }
            #expect(model.startupState == .ready)
            model.settings.experience.skipVideoDetails = true
            model.settings.experience.skipDownloadReview = true
            model.settings.experience.instantQuickStart = true
            model.settings.sharedLinks = SharedLinkPreferences(behavior: behavior,
                preferredPresetID: QuickStartPresetLibrary.defaults[1].id)
            model.URLText = ""
            model.receiveSharedLink(DeveloperFixtures.RickURL)
            for _ in 0..<200 where model.isAnalyzing { try await Task.sleep(for: .milliseconds(20)) }
            #expect(model.presentsMetadata == (behavior == .analyze))
            #expect(model.presentsConfiguration == (behavior == .options))
            #expect(model.presentsQuickStartConfirmation == (behavior == .presetConfirmation))
            #expect(model.jobs.isEmpty)
            model.saveTask?.cancel()
            model.sponsorBlockPreviewTask?.cancel()
        }
    }
    #endif

    @Test
    func clipboardLinkValidationRejectsUnreadableAndUnsupportedContent() {
        #expect(LinkIntakePolicy.supportedURL(nil) == nil)
        #expect(LinkIntakePolicy.supportedURL(" ") == nil)
        #expect(LinkIntakePolicy.supportedURL("https://example.com") == nil)
        #expect(LinkIntakePolicy.supportedURL(DeveloperFixtures.RickURL.absoluteString) == DeveloperFixtures.RickURL)
    }

    @Test
    func legacyClipboardSettingsDefaultToReplacementWithoutEnablingChecks() throws {
        let legacy = Data(#"{"enabled":false,"checkAtStartup":false,"explained":false,"behavior":"Suggest URL only"}"#.utf8)
        var prefs = try JSONDecoder().decode(ClipboardPreferences.self, from: legacy)
        #expect(!prefs.checksAutomatically)
        #expect(prefs.replacesExistingURL)
        prefs.replacesExistingURL = false
        let restored = try JSONDecoder().decode(ClipboardPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(!restored.replacesExistingURL)
    }

    @Test @MainActor
    func firstPasteTipWaitsForAnAvailablePageAndPersistsWithoutEnablingClipboardChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IllucetPersistence(rootURL: root)
        let model = IllucetAppModel(persistence: persistence, fixtureModeOverride: true)
        await model.startupTask?.value
        defer { model.saveTask?.cancel() }
        model.presentsOnboarding = false
        model.firstRunState.pastePermissionTipShown = nil
        model.settings.clipboard = .init()
        model.clearURL()
        model.recordPastedLink("not a media link")
        #expect(!model.pendingPastePermissionTip)
        let link = DeveloperFixtures.RickURL.absoluteString
        for character in link { model.editURLField(model.URLText + String(character)) }
        #expect(!model.pendingPastePermissionTip, "Typing must not consume the paste tip")
        model.clearURL()
        model.editURLField(link)
        #expect(model.pendingPastePermissionTip)
        model.presentsMetadata = true
        #expect(!model.presentsPastePermissionTip)
        model.presentsMetadata = false
        model.pipGuideStep = .link
        #expect(!model.presentsPastePermissionTip)
        model.pipGuideStep = nil
        #expect(model.presentsPastePermissionTip)
        model.pastePermissionTipDidAppear()
        model.dismissPastePermissionTip()
        model.clearURL()
        model.pasteURL()
        #expect(!model.pendingPastePermissionTip)
        #expect(model.settings.clipboard?.checksAutomatically == false)
        await model.saveNow()
        #expect(try await persistence.load().firstRunState.pastePermissionTipShown == true)
    }

    @Test
    func equivalentYouTubeLinksDoNotNeedReplacement() {
        #expect(LinkIntakePolicy.identifiesSameLink("https://youtu.be/N94KCRua7NE?si=share",
            "https://youtube.com/shorts/N94KCRua7NE"))
        #expect(!LinkIntakePolicy.identifiesSameLink("https://amazon.com/N94KCRua7NE",
            "https://youtube.com/shorts/N94KCRua7NE"))
        #expect(!LinkIntakePolicy.identifiesSameLink("https://youtu.be/dQw4w9WgXcQ",
            "https://youtube.com/shorts/N94KCRua7NE"))
    }

    @Test
    func freshPresetSetupDropsRemovedControlsWithoutChangingStoredConfiguration() throws {
        var preset = QuickStartPresetLibrary.defaults[0]
        preset.configuration.trimStartSeconds = 3
        preset.configuration.trimEndSeconds = 5
        preset.configuration.trimMode = .accurate
        preset.configuration.thumbnailID = "old-video-image"
        let result = try preset.resolvedConfiguration(metadata: DeveloperFixtures.media)
        #expect(result.trimStartSeconds == nil && result.trimEndSeconds == nil && result.trimMode == nil)
        #expect(result.thumbnailID == nil)
        #expect(preset.configuration.trimStartSeconds == 3)
        #expect(preset.configuration.thumbnailID == "old-video-image")
    }

    @Test
    func friendlySourceSummaryOmitsTechnicalIDsAndUnknownMeasurements() throws {
        let original = try #require(DeveloperFixtures.media.formats.first)
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        fields["format_id"] = "private-format-299"
        fields["has_video"] = true
        fields["has_audio"] = false
        fields["width"] = 1920
        fields["height"] = 1080
        fields["format_note"] = "1080p60"
        fields["frames_per_second"] = 60
        fields["audio_bitrate_kbps"] = 0
        fields["exact_file_size_bytes"] = 0
        fields["video_codec"] = "avc1.64002A"
        let format = try JSONDecoder().decode(MediaFormat.self, from: JSONSerialization.data(withJSONObject: fields))
        let friendly = MediaSourceSummary.friendly(format)
        #expect(friendly.contains("1080p"))
        #expect(friendly.contains("60 fps"))
        #expect(!friendly.contains("kbps"))
        #expect(!friendly.contains("private-format"))
        #expect(!friendly.contains("avc1"))
        #expect(MediaSourceSummary.technical(format).contains("private-format-299"))
        #expect(format.formatID == "private-format-299")
    }

    @Test
    func legacySettingsDecodeWithoutExperiencePreferences() throws {
        var settings = AppSettings.defaults
        settings.fastStartMP4 = true
        settings.automaticUpdateInstallation = true
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        object.removeValue(forKey: "downloadExperience")
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.experience == DownloadExperiencePreferences())
        #expect(restored.fastStartMP4)
        #expect(restored.automaticUpdateInstallation)
        var configured = restored
        configured.experience.skipVideoDetails = true
        configured.experience.skipDownloadReview = true
        configured.experience.instantQuickStart = true
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(configured)) == configured)
    }

    @Test
    func stockMigrationPreservesCustomizationsAndSharingReferences() {
        let old = QuickStartPresetLibrary.legacyDefaults
        let fresh = QuickStartPresetLibrary.defaults
        #expect(fresh.map(\.name) == ["Best video", "Best audio", "Compatible video", "Thumbnail"])
        #expect(QuickStartPresetLibrary.migratingStockPresets(old, referencedID: nil) == fresh)
        #expect(QuickStartPresetLibrary.migratingStockPresets(fresh, referencedID: nil) == fresh)
        #expect(QuickStartPresetLibrary.migratingStockPresets(old, referencedID: old[3].id) == old)
        var custom = old
        custom[0].name = "My video"
        #expect(QuickStartPresetLibrary.migratingStockPresets(custom, referencedID: nil) == custom)
        #expect(QuickStartPresetLibrary.migratingStockPresets(Array(old.reversed()), referencedID: nil) == Array(old.reversed()))
        #expect(QuickStartPresetLibrary.migratingStockPresets([], referencedID: nil).isEmpty)
    }

    @Test
    func fourPresetsKeepExactMediaRolesAndNoUnrequestedImage() throws {
        let presets = QuickStartPresetLibrary.defaults
        for preset in presets {
            let config = try preset.resolvedConfiguration(metadata: DeveloperFixtures.media)
            try OutputCapabilityMatrix.validate(config, metadata: DeveloperFixtures.media)
            if preset.name == "Thumbnail" {
                #expect(config.thumbnailBehavior == .thumbnailOnly)
            } else {
                #expect(config.thumbnailBehavior == (config.preset == .compatible ? .includeVideoThumbnail : .none))
                #expect(config.selectedAudioFormatID != nil)
                #expect(config.mode == (preset.name == "Best audio" ? .audioOnly : .videoAndAudio))
            }
        }
        #expect(presets[1].configuration.audioCodec == .original)
        #expect(presets[1].configuration.audioBitrateKbps == nil)
        #expect(!AppSettings.defaults.fastStartMP4)
        #expect(!AppSettings.defaults.notifyProcessingComplete)
    }

    @Test
    func largeSubtitleCatalogSearchKeepsExactIdentityAndSelectedExclusion() throws {
        let tracks = (0..<1000).map { index in
            MediaSubtitleTrack(trackID: "subtitle-\(index)", language: index == 0 ? "en" : "x-\(index)",
                name: index == 0 ? "English" : "Language \(index)", automatic: index % 2 == 0,
                formats: (0..<5).map { format in MediaSubtitleFormat(formatID: "subtitle-format-\(index)-\(format)",
                    url: URL(string: "https://example.invalid/track")!, extension: "vtt", name: "Track \(format)") })
        }
        let catalog = SubtitlePickerCatalog(tracks: tracks, locale: Locale(identifier: "en"))
        #expect(catalog.entries.count == 5000)
        #expect(Set(catalog.entries.map(\.id)).count == 5000)
        let english = catalog.matching("ENGLISH", filter: .automatic, excluding: [], locale: Locale(identifier: "en"))
        #expect(english.count == 5)
        #expect(catalog.matching("English", filter: .manual, excluding: []).isEmpty)
        let selection = try #require(english.first?.selection)
        #expect(catalog.matching("English", filter: .all, excluding: [selection]).count == 4)
        #expect(selection.trackID == "subtitle-0")
        #expect(selection.formatID == "subtitle-format-0-0")
    }

    @Test
    func extractorRankingWinsOverBitrateButCompatibilityStillFilters() throws {
        let original = DeveloperFixtures.media
        var formats = original.formats
        for index in formats.indices {
            formats[index].extractorPreferenceRank = formats[index].formatID == "251" ? 100 : index
        }
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["formats"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(formats))
        let metadata = try JSONDecoder().decode(MediaMetadata.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(FormatSelection.bestAudio(in: metadata)?.formatID == "251")
        #expect(FormatSelection.bestAudio(in: metadata, appleCompatible: true)?.formatID == "140")
        var oldFormat = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(formats[0])) as? [String: Any])
        oldFormat.removeValue(forKey: "extractor_preference_rank")
        #expect(try JSONDecoder().decode(MediaFormat.self, from: JSONSerialization.data(withJSONObject: oldFormat)).extractorPreferenceRank == nil)
    }

    @Test
    func automaticChecksRespectPreferenceCadenceChannelAndPendingActivation() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var status = UpdateStatus.initial
        #expect(AutomaticExtractorUpdatePolicy.isDue(enabled: true, status: status, channel: .stable, now: now))
        #expect(!AutomaticExtractorUpdatePolicy.isDue(enabled: false, status: status, channel: .stable, now: now))
        status.lastCheckedChannel = .stable
        status.lastCheckedAt = now.addingTimeInterval(-86_399)
        #expect(!AutomaticExtractorUpdatePolicy.isDue(enabled: true, status: status, channel: .stable, now: now))
        #expect(AutomaticExtractorUpdatePolicy.isDue(enabled: true, status: status, channel: .nightly, now: now))
        status.lastCheckedAt = now.addingTimeInterval(-86_400)
        #expect(AutomaticExtractorUpdatePolicy.isDue(enabled: true, status: status, channel: .stable, now: now))
        for state: UpdateStatus.State in [.checking, .installing, .testing, .staged] {
            status.state = state
            #expect(!AutomaticExtractorUpdatePolicy.isDue(enabled: true, status: status, channel: .stable, now: now))
        }
    }
}


extension UsabilityCleanupTests {
    @Test func explicitFileDeletionIncludesDocumentsOutsideDownloadsAndKeepsPreferences() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "DocumentsCleanup-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let docs = root.appending(path: "Documents"), support = root.appending(path: "Support")
        let outside = root.appending(path: "external.txt")
        for path in ["Documents/Downloads/saved.mp4", "Documents/Audit-Invalid-Preferences/Audit-04-Oversized.json",
                     "Support/State.json", "external.txt"] {
            let url = root.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0, count: 10).write(to: url)
        }
        try fm.createSymbolicLink(at: docs.appending(path: "link"), withDestinationURL: outside)
        let storage = StorageManager(documentsURL: docs, temporaryURL: root.appending(path: "tmp"), applicationSupportURL: support)
        #expect(try await storage.deleteOtherDocuments() == 2)
        #expect(fm.fileExists(atPath: docs.appending(path: "Downloads/saved.mp4").path))
        #expect(fm.fileExists(atPath: support.appending(path: "State.json").path))
        #expect(fm.fileExists(atPath: outside.path))
        #expect(await storage.snapshot().appDocumentsBytes == 10)
    }

    @Test func manualTemporaryCleanupReclaimsOldNetworkAndPreferenceCopiesOnlyWhenJobsAreSafe() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "OrphanCleanup-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let export = root.appending(path: UUID().uuidString)
        let unknown = root.appending(path: UUID().uuidString)
        try fm.createDirectory(at: export, withIntermediateDirectories: true)
        try fm.createDirectory(at: unknown, withIntermediateDirectories: true)
        let backup = try PreferencesBackup(settings: .defaults, presets: []).encoded()
        try backup.write(to: export.appending(path: "Illucet-Preferences.json"))
        try Data([9]).write(to: unknown.appending(path: "user.txt"))
        let network = root.appending(path: "CFNetworkDownload_old.tmp")
        let recent = root.appending(path: "CFNetworkDownload_recent.tmp")
        try Data(repeating: 0, count: 32_768).write(to: network)
        try Data([1]).write(to: recent)
        let cutoff = Date.now.addingTimeInterval(-86_400)
        for url in [network, export, unknown] {
            try fm.setAttributes([.modificationDate: cutoff.addingTimeInterval(-60)], ofItemAtPath: url.path)
        }
        let storage = StorageManager(documentsURL: root, temporaryURL: root)
        #expect(try await storage.clearTemporaryFiles().removedBytes == 0)
        #expect(try await storage.clearTemporaryFiles(excludingJobIDs: [UUID()], orphanedBefore: cutoff).removedBytes == 0)
        let result = try await storage.clearTemporaryFiles(orphanedBefore: cutoff)
        #expect(result.removedDirectories == 2 && result.removedBytes == 32_768 + Int64(backup.count))
        #expect(fm.fileExists(atPath: recent.path))
        #expect(fm.fileExists(atPath: unknown.appending(path: "user.txt").path))
    }

    @Test
    func storageExplainsDocumentsAndUnownedTemporaryRemainders() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "StorageBreakdown-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let docs = root.appending(path: "Documents"), temporary = root.appending(path: "tmp")
        let support = root.appending(path: "Support")
        let active = UUID(), inactive = UUID()
        let values: [(URL, Int)] = [
            (docs.appending(path: "Downloads/saved.jpg"), 500),
            (docs.appending(path: "Audit-Invalid-Preferences/oversized.json"), 1_048_640),
            (temporary.appending(path: "Illucet-\(active)/.range/part"), 40),
            (temporary.appending(path: "Illucet-\(inactive)/part"), 70),
            (temporary.appending(path: "CFNetworkDownload_fixture.tmp"), 32_768),
            (temporary.appending(path: "export/Illucet-Preferences.json"), 8_192),
            (temporary.appending(path: "Illucet-unrecognized/user.txt"), 10),
            (support.appending(path: "Diagnostics.json"), 2_000)]
        for (url, count) in values {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0, count: count).write(to: url)
        }
        let store = StorageManager(documentsURL: docs, temporaryURL: temporary, applicationSupportURL: support)
        let before = await store.snapshot()
        let usage = try #require(before.breakdown)
        #expect(before.appDocumentsBytes == 1_049_140)
        #expect(usage.savedDownloadsBytes == 500)
        #expect(usage.activityLogBytes == 2_000)
        #expect(usage.otherDocuments == [.init(relativePath: "Audit-Invalid-Preferences", byteCount: 1_048_640)])
        #expect(usage.temporaryEntries.reduce(0) { $0 + $1.byteCount } == before.temporaryBytes)
        #expect(usage.temporaryEntries.filter(\.isCleanupCandidate).count == 2)
        let result = try await store.clearTemporaryFiles(excludingJobIDs: [active])
        #expect(result.removedBytes == 70 && result.protectedBytes == 40 && result.failedPaths.isEmpty)
        let after = await store.snapshot()
        #expect(after.temporaryBytes == before.temporaryBytes - 70)
        #expect(after.appDocumentsBytes == before.appDocumentsBytes)
        #expect(fm.fileExists(atPath: temporary.appending(path: "Illucet-unrecognized/user.txt").path))
    }

    @Test
    func cleanupReportsPartialFailuresAndProtectsAnOpenDiagnosticShare() async throws {
        let fm = CleanupFailureFileManager()
        let root = FileManager.default.temporaryDirectory.appending(path: "StorageFailures-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["Illucet-\(UUID())", "Illucet-\(UUID())", "Illucet-Diagnostics-\(UUID())"]
        for name in names {
            let folder = root.appending(path: name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 20).write(to: folder.appending(path: "payload"))
        }
        fm.failedName = names[1]
        let store = StorageManager(fileManager: fm, documentsURL: root, temporaryURL: root)
        let result = try await store.clearTemporaryFiles(excludingPaths: [names[2]])
        #expect(result.removedDirectories == 1 && result.removedBytes == 20)
        #expect(result.protectedDirectories == 1 && result.protectedBytes == 20)
        #expect(result.failedPaths == [names[1]])
        #expect(await store.snapshot().temporaryBytes == 40)
    }
}

private final class CleanupFailureFileManager: FileManager, @unchecked Sendable {
    var failedName: String?
    override func removeItem(at url: URL) throws {
        if url.lastPathComponent == failedName { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}
