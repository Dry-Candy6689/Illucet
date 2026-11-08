import Foundation

extension IllucetAppModel {
    func settingsChanged() {
        if !settings.pipPreferences.enabled && firstRunState.pip?.disableConfirmed != true {
            var local = firstRunState.pip ?? .init()
            local.disableConfirmed = true
            firstRunState.pip = local
        }
        let normalized = OutputCapabilityMatrix.normalized(settings)
        if normalized != settings {
            settings = normalized
            return
        }
        snapshot.settings = settings
        let currentSettings = settings
        let bookmark = snapshot.filesFolderBookmark
        Task {
            await liveActivityController.synchronize(jobs: jobs, enabled: settings.liveActivities && !fixtureMode)
            await sponsorBlockDiagnostics.setEnabled(
                currentSettings.sponsorBlockDiagnosticLoggingEnabled
            )
            await coordinator.configure(
                settings: currentSettings,
                folderBookmark: bookmark
            )
        }
        scheduleSave()
        updateIdleTimer()
    }

    func requestFilesFolderPicker(from source: FilesFolderPickerSource) {
        filesFolderPickerSource = source
    }

    func dismissFilesFolderPicker(from source: FilesFolderPickerSource) {
        guard filesFolderPickerSource == source else { return }
        filesFolderPickerSource = nil
    }

    func chooseFixtureFilesFolder() {
        chooseFixtureFilesFolder(named: "Illucet UI Test Files")
    }

    func chooseFixtureDocumentsFolder() {
        chooseFixtureFilesFolder(named: "Documents")
    }

    func chooseFixtureAlternateFilesFolder() {
        chooseFixtureFilesFolder(named: "Illucet UI Other Files")
    }

    private func chooseFixtureFilesFolder(named name: String) {
        let URL = FileManager.default.temporaryDirectory
            .appending(
                path: "Illucet UI File Provider",
                directoryHint: .isDirectory
            )
            .appending(path: name, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: URL,
                withIntermediateDirectories: true
            )
            chooseFilesFolder(URL)
        } catch {
            alert = .error(error)
        }
    }

    func changeConfirmationDestination(to destination: ExportDestination) {
        configuration.destination = destination
        if [
            ExportDestination.photos,
            .filesAndPhotos,
        ].contains(destination),
           let analyzedMetadata {
            do {
                try OutputCapabilityMatrix.validate(
                    configuration,
                    metadata: analyzedMetadata
                )
            } catch {
                alert = .error(error)
                return
            }
        }
        guard [
            ExportDestination.filesFolder,
            .filesAndPhotos,
        ].contains(destination) else {
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            requestFilesFolderPicker(from: .confirmation)
        }
    }

    func chooseFilesFolder(_ URL: URL) {
        Task {
            do {
                let previousSelectionIdentity: String?
                if let stored = snapshot.filesFolderSelectionIdentity {
                    previousSelectionIdentity = stored
                } else if let bookmark = snapshot.filesFolderBookmark,
                          let previousAccess = try? await exporter
                              .testFolderAccessDetail(bookmark: bookmark) {
                    previousSelectionIdentity = FilesFolderDisplayIdentity
                        .selectionIdentity(for: previousAccess.folderURL)
                } else {
                    previousSelectionIdentity = nil
                }
                let selection = try await exporter.bookmarkSelection(
                    for: URL
                )
                let access = try await exporter.testFolderAccessDetail(
                    bookmark: selection.data
                )
                let resolvedSelection = FilesFolderResolvedSelection(
                    selection: selection,
                    access: access
                )
                let selectionIdentity = resolvedSelection.selectionIdentity
                let resolvedDisplayName = resolvedSelection.displayName
                let representsSameFolder = previousSelectionIdentity
                    == selectionIdentity
                if !representsSameFolder {
                    snapshot.filesFolderAlias = nil
                    snapshot.filesFolderAliasOfferShown = false
                    filesFolderAliasEditorMode = nil
                    filesFolderAliasDraft = ""
                }
                snapshot.filesFolderBookmark = resolvedSelection.bookmarkData
                snapshot.filesFolderSelectionIdentity = selectionIdentity
                snapshot.filesFolderDisplayName = resolvedDisplayName
                filesFolderName = FilesFolderDisplayIdentity.presentedName(
                    alias: snapshot.filesFolderAlias,
                    resolved: resolvedDisplayName
                )
                await coordinator.configure(
                    settings: settings,
                    folderBookmark: resolvedSelection.bookmarkData
                )
                if !representsSameFolder,
                   !snapshot.filesFolderAliasOfferShown,
                   FilesFolderDisplayIdentity.shouldOfferAlias(
                       for: resolvedDisplayName
                   ) {
                    snapshot.filesFolderAliasOfferShown = true
                    beginFilesFolderAliasEditing(mode: .offer)
                }
                scheduleSave()
            } catch {
                alert = .error(error)
            }
        }
    }

    func testFilesFolder() {
        guard let bookmark = snapshot.filesFolderBookmark else {
            requestFilesFolderPicker(from: .settings)
            return
        }
        Task {
            do {
                let access = try await exporter.testFolderAccessDetail(
                    bookmark: bookmark
                )
                let displayName = updateFilesFolderPresentation(
                    resolved: access.displayName,
                    folderURL: access.folderURL
                )
                filesFolderName = displayName
                alert = AppAlert(
                    title: "Folder available",
                    message: "\(displayName) is writable."
                )
            } catch {
                await invalidateFilesFolderAccess()
                alert = AppAlert(
                    title: "Select the Files folder again",
                    message: error.localizedDescription
                )
            }
        }
    }

    func ensureFilesFolderAccess(
        presentingFrom source: FilesFolderPickerSource
    ) async -> Bool {
        guard let bookmark = snapshot.filesFolderBookmark else {
            requestFilesFolderPicker(from: source)
            return false
        }
        do {
            let access = try await exporter.testFolderAccessDetail(
                bookmark: bookmark
            )
            filesFolderName = updateFilesFolderPresentation(
                resolved: access.displayName,
                folderURL: access.folderURL
            )
            return true
        } catch {
            await invalidateFilesFolderAccess()
            requestFilesFolderPicker(from: source)
            return false
        }
    }

    func invalidateFilesFolderAccess() async {
        snapshot.filesFolderBookmark = nil
        if snapshot.filesFolderSelectionIdentity == nil {
            snapshot.filesFolderDisplayName = nil
            snapshot.filesFolderAlias = nil
            snapshot.filesFolderAliasOfferShown = false
        }
        filesFolderName = nil
        filesFolderAliasDraft = ""
        filesFolderAliasEditorMode = nil
        await coordinator.configure(
            settings: settings,
            folderBookmark: nil
        )
        scheduleSave()
    }

    func updateFilesFolderPresentation(
        resolved: String,
        folderURL: URL
    ) -> String {
        let selectionIdentity = FilesFolderDisplayIdentity.selectionIdentity(
            for: folderURL
        )
        if snapshot.filesFolderSelectionIdentity != selectionIdentity {
            snapshot.filesFolderSelectionIdentity = selectionIdentity
            scheduleSave()
        }
        if snapshot.filesFolderDisplayName != resolved {
            snapshot.filesFolderDisplayName = resolved
            scheduleSave()
        }
        return FilesFolderDisplayIdentity.presentedName(
            alias: snapshot.filesFolderAlias,
            resolved: resolved
        )
    }

    func beginFilesFolderAliasEditing() {
        beginFilesFolderAliasEditing(mode: .edit)
    }

    private func beginFilesFolderAliasEditing(
        mode: FilesFolderAliasEditorMode
    ) {
        guard snapshot.filesFolderBookmark != nil,
              let resolved = snapshot.filesFolderDisplayName else {
            return
        }
        let initialValue = mode == .offer
            ? ""
            : snapshot.filesFolderAlias ?? resolved
        filesFolderAliasDraft = FilesFolderDisplayIdentity.boundedAliasInput(
            initialValue
        )
        filesFolderAliasEditorMode = mode
    }

    func updateFilesFolderAliasDraft(_ value: String) {
        filesFolderAliasDraft = FilesFolderDisplayIdentity.boundedAliasInput(
            value
        )
    }

    func saveFilesFolderAlias() {
        guard snapshot.filesFolderBookmark != nil,
              let resolved = snapshot.filesFolderDisplayName else {
            cancelFilesFolderAliasEditing()
            return
        }
        snapshot.filesFolderAlias = FilesFolderDisplayIdentity.normalizedAlias(
            filesFolderAliasDraft
        )
        filesFolderName = FilesFolderDisplayIdentity.presentedName(
            alias: snapshot.filesFolderAlias,
            resolved: resolved
        )
        filesFolderAliasEditorMode = nil
        filesFolderAliasDraft = ""
        scheduleSave()
    }

    func cancelFilesFolderAliasEditing() {
        filesFolderAliasEditorMode = nil
        filesFolderAliasDraft = ""
    }

    func refreshAvailableStorage() {
        storage.availableBytes = storageManager.availableCapacity()
    }

    func refreshStorage() async {
        storageRefreshTask?.cancel()
        storageRefreshTask = nil
        storageRefreshGeneration += 1
        let generation = storageRefreshGeneration
        isRefreshingStorage = true
        await measureStorage(generation: generation)
    }

    func requestStorageRefresh() {
        storageRefreshTask?.cancel()
        storageRefreshGeneration += 1
        let generation = storageRefreshGeneration
        isRefreshingStorage = true
        storageRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            await self?.measureStorage(generation: generation)
        }
    }

    private func measureStorage(generation: Int) async {
        let updated = await storageSnapshotProvider()
        guard generation == storageRefreshGeneration else { return }
        guard !Task.isCancelled else { isRefreshingStorage = false; return }
        storage = updated
        storageRefreshedAt = .now
        isRefreshingStorage = false
    }

    var storageSummary: String {
        if storageRefreshedAt == nil { return "Calculating…" }
        if isRefreshingStorage { return "Updating…" }
        return storage.appDocumentsBytes.formatted(.byteCount(style: .file))
    }

    var canDeleteIllucetFiles: Bool {
        !isDeletingIllucetFiles && !isRemovingHistoryFiles
            && protectedTemporaryJobIDs.isEmpty && packagingBatchIDs.isEmpty
    }

    var protectedTemporaryPaths: Set<String> {
        guard let exportedDiagnosticURL else { return [] }
        return [exportedDiagnosticURL.deletingLastPathComponent().lastPathComponent]
    }

    private func cleanupDetail(_ result: TemporaryCleanupResult) -> String {
        let removed = result.removedBytes.formatted(.byteCount(style: .file))
        let protected = result.protectedBytes.formatted(.byteCount(style: .file))
        return "\(removed) removed from \(result.removedDirectories) unused item(s). \(protected) in \(result.protectedDirectories) in-use or recoverable folder(s) kept."
            + (result.failedPaths.isEmpty ? "" : " \(result.failedPaths.count) item(s) could not be removed.")
    }

    func deleteIllucetFiles() async {
        guard canDeleteIllucetFiles else { return }
        isDeletingIllucetFiles = true
        defer { isDeletingIllucetFiles = false }
        let started = Date.now
        do {
            let downloads = try await exporter.deleteAppDownloads()
            let documents = try await storageManager.deleteOtherDocuments()
            let temporary = try await storageManager.clearTemporaryFiles(
                olderThan: started, excludingJobIDs: protectedTemporaryJobIDs,
                excludingPaths: protectedTemporaryPaths, orphanedBefore: started.addingTimeInterval(-86_400))
            alert = AppAlert(title: temporary.failedPaths.isEmpty ? "Illucet files deleted" : "Cleanup incomplete", message:
                "Removed \(downloads + documents) document item(s). " + cleanupDetail(temporary))
        } catch { alert = .error(error) }
        await refreshStorage()
    }

    func clearTemporaryFiles() {
        let started = Date.now
        Task {
            do {
                let result = try await storageManager.clearTemporaryFiles(
                    olderThan: started, excludingJobIDs: protectedTemporaryJobIDs,
                    excludingPaths: protectedTemporaryPaths,
                    orphanedBefore: packagingBatchIDs.isEmpty ? started.addingTimeInterval(-86_400) : nil
                )
                alert = AppAlert(
                    title: result.failedPaths.isEmpty ? "Temporary files cleared" : "Cleanup incomplete",
                    message: cleanupDetail(result)
                )
            } catch {
                alert = .error(error)
            }
            await refreshStorage()
        }
    }

    func refreshNotificationAuthorization() async {
        guard !fixtureMode else { return }
        let status = await notifications.authorizationStatus()
        notificationsAuthorized = status == .authorized || status == .provisional || status == .ephemeral
    }

    func requestNotifications() {
        if !firstRunState.notificationPromptOffered {
            firstRunState.beginNotificationRequest()
            scheduleSave()
        }
        Task {
            let granted = await notifications.requestAuthorization()
            notificationsAuthorized = granted
            if granted {
                settings.enableRecommendedNotificationEventsIfNeeded()
                scheduleSave()
            }
            alert = AppAlert(
                title: granted
                    ? "Notifications enabled"
                    : "Notifications unavailable",
                message: granted
                    ? "Illucet can notify you when jobs finish or need attention."
                    : "You can change notification access in iOS Settings."
            )
        }
    }

    func skipOnboarding() {
        firstRunState.completeWithoutNotifications()
        presentsOnboarding = false
        scheduleSave()
    }

    func completeOnboardingWithoutNotifications() {
        firstRunState.completeWithoutNotifications()
        presentsOnboarding = false
        scheduleSave()
    }

    func requestOnboardingNotifications() {
        guard !isRequestingNotificationAuthorization else { return }
        if firstRunState.notificationPromptOffered {
            firstRunState.complete()
            presentsOnboarding = false
            scheduleSave()
            return
        }

        isRequestingNotificationAuthorization = true
        firstRunState.beginNotificationRequest()
        Task {
            await saveNow()
            let granted = await notifications.requestAuthorization()
            notificationsAuthorized = granted
            if granted { settings.enableRecommendedNotificationEventsIfNeeded() }
            firstRunState.complete()
            presentsOnboarding = false
            isRequestingNotificationAuthorization = false
            await saveNow()
        }
    }

    func exportDiagnostics() {
        Task {
            do {
                let versions = extractionVersions
                let URL = try await diagnostics.exportReport(
                    environment: [
                        "app": AppIdentity.displayName,
                        "os": ProcessInfo.processInfo.operatingSystemVersionString,
                        "target": Self.validationTarget,
                        "python": versions?.python ?? "not loaded",
                        "yt-dlp": versions?.ytDLP
                            ?? updateStatus.activeYTDLPVersion,
                        "EJS": versions?.ejs ?? updateStatus.activeEJSVersion,
                        "FFmpeg": String(cString: illucet_ffmpeg_version()),
                    ],
                    jobs: jobs
                )
                exportedDiagnosticURL = URL
            } catch {
                alert = .error(error)
            }
        }
    }

    func clearDiagnostics() {
        guard !isClearingDiagnostics else { return }
        isClearingDiagnostics = true
        didClearDiagnostics = false
        clearDiagnosticsFeedbackTask?.cancel()
        clearDiagnosticsFeedbackTask = Task {
            do {
                try await diagnostics.clearReportingFailure()
                diagnosticEntries = []
                didClearDiagnostics = true
                await refreshStorage()
            } catch { alert = .error(error) }
            isClearingDiagnostics = false
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            didClearDiagnostics = false
        }
    }

    func refreshDiagnostics() {
        Task {
            diagnosticEntries = await diagnostics.allEntries()
        }
    }

    func runStage0Proof() {
        guard !isRunningStage0 else { return }
        isRunningStage0 = true
        stage0Report = nil
        Task {
            stage0Report = await Stage0ProofRunner.run()
            isRunningStage0 = false
        }
    }
}
