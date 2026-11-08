struct IllucetAppPersistedState: Equatable, Sendable {
    var settings: AppSettings
    var jobs: [DownloadJob]
    var batches: [DownloadBatch]
    var downloadArchive: [DownloadArchiveEntry]
    var history: [HistoryRecord]
    var recentLinks: [RecentLink]
    var quickStartPresets: [QuickStartPreset]
    var firstRunState: FirstRunState
    var updateStatus: UpdateStatus

    static func restoring(_ snapshot: IllucetSnapshot, resolver: SavedOutputResolver = .init()) -> Self {
        var restored = Self(
            settings: OutputCapabilityMatrix.normalized(snapshot.settings),
            jobs: snapshot.jobs.map { stored in
                var normalized = stored
                normalized.maximumRetries = min(5, max(0, stored.maximumRetries))
                normalized.configuration = OutputCapabilityMatrix.normalized(
                    stored.configuration
                )
                normalized.outputReferences = resolver.references(for: HistoryRecord(job: normalized).ownedFileURLs,
                    previous: stored.outputReferences, folderBookmark: stored.pipelineCheckpoint?.publicationPlan?.folderBookmark ?? snapshot.filesFolderBookmark)
                return normalized
            },
            batches: snapshot.batches,
            downloadArchive: snapshot.downloadArchive,
            history: snapshot.history.map { stored in
                var normalized = stored
                let job = snapshot.jobs.first { $0.id == stored.jobID }
                normalized.configuration = OutputCapabilityMatrix.normalized(
                    stored.configuration
                )
                normalized.outputReferences = resolver.references(for: normalized.ownedFileURLs,
                    previous: stored.outputReferences ?? job?.outputReferences,
                    folderBookmark: job?.pipelineCheckpoint?.publicationPlan?.folderBookmark ?? snapshot.filesFolderBookmark)
                return normalized
            },
            recentLinks: snapshot.recentLinks,
            quickStartPresets: QuickStartPresetLibrary.migratingStockPresets(
                snapshot.quickStartPresets,
                referencedID: snapshot.settings.shortcutPreferences.preferredPresetID
            ),
            firstRunState: snapshot.firstRunState,
            updateStatus: snapshot.updateStatus.reconciledWithBundledRuntime
        )
        QuickStartPresetLibrary.migrateLaunchBehavior(settings: &restored.settings, presets: &restored.quickStartPresets)
        if restored.firstRunState.migratedNightlyUpdateDefault != true {
            if restored.settings.updateChannel == .stable {
                restored.settings.updateChannel = .nightly
                if restored.updateStatus.state != .staged {
                    restored.updateStatus.invalidateCheck()
                }
            }
            restored.firstRunState.migratedNightlyUpdateDefault = true
        }
        if !restored.settings.pipPreferences.enabled, restored.firstRunState.pip?.disableConfirmed == nil {
            var local = restored.firstRunState.pip ?? .init()
            local.disableConfirmed = true
            restored.firstRunState.pip = local
        }
        return restored
    }

    func applying(to storedSnapshot: IllucetSnapshot) -> IllucetSnapshot {
        var snapshot = storedSnapshot
        snapshot.schemaVersion = IllucetSnapshot.currentSchemaVersion
        snapshot.settings = settings
        snapshot.jobs = jobs
        snapshot.batches = batches
        snapshot.downloadArchive = downloadArchive
        snapshot.history = history
        snapshot.recentLinks = recentLinks
        snapshot.quickStartPresets = quickStartPresets
        snapshot.firstRunState = firstRunState
        snapshot.updateStatus = updateStatus
        return snapshot
    }
}
