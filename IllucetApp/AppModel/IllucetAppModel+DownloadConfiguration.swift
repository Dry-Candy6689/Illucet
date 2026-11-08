import Foundation

extension IllucetAppModel {
    func claimDownloadSubmission() -> UUID? {
        guard !startupState.blocksInteraction, !isStartingDownload,
              completedDownloadReviewID != downloadReviewID else { return nil }
        isStartingDownload = true
        downloadSubmissionInFlight = downloadReviewID
        return downloadReviewID
    }

    func finishDownloadSubmission(_ claim: UUID, succeeded: Bool) {
        guard downloadSubmissionInFlight == claim else { return }
        if succeeded { completedDownloadReviewID = claim }
        downloadSubmissionInFlight = nil
        isStartingDownload = false
    }

    func resetDownloadReview() {
        guard !isStartingDownload else { return }
        downloadReviewID = UUID()
        completedDownloadReviewID = nil
    }

    func confirmQuickStartDownload() {
        guard activeQuickStartPreset != nil, let claim = claimDownloadSubmission() else { return }
        Task { await performQuickStartLaunch(claim: claim) }
    }

    func editQuickStartDownload() {
        configurationReturnsToDetails = false
        presentsQuickStartConfirmation = false
        presentsConfiguration = true
    }

    func cancelQuickStart() {
        cancelQuickStartInputRecovery()
        presentsQuickStartConfirmation = false
        activeQuickStartPreset = nil
    }

    @discardableResult
    func addQuickStartPreset() -> UUID {
        let preset = QuickStartPresetLibrary.newPreset(
            sponsorBlock: settings.sponsorBlock
        )
        quickStartPresets.append(preset)
        quickStartPresets = QuickStartPresetLibrary.normalized(
            quickStartPresets
        )
        scheduleSave()
        return preset.id
    }

    func saveQuickStartPreset(_ preset: QuickStartPreset) {
        guard let normalized = QuickStartPresetLibrary.normalized(
            [preset]
        ).first else {
            return
        }
        if let index = quickStartPresets.firstIndex(where: {
            $0.id == preset.id
        }) {
            quickStartPresets[index] = normalized
        } else {
            quickStartPresets.append(normalized)
        }
        quickStartPresets = QuickStartPresetLibrary.normalized(
            quickStartPresets
        )
        scheduleSave()
    }

    func duplicateQuickStartPreset(_ preset: QuickStartPreset) {
        quickStartPresets = QuickStartPresetLibrary.duplicate(
            preset,
            in: quickStartPresets
        )
        scheduleSave()
    }

    func deleteQuickStartPreset(_ preset: QuickStartPreset) {
        quickStartPresets.removeAll { $0.id == preset.id }
        scheduleSave()
    }

    func moveQuickStartPresets(
        fromOffsets offsets: IndexSet,
        toOffset destination: Int
    ) {
        quickStartPresets = QuickStartPresetLibrary.move(
            quickStartPresets,
            fromOffsets: offsets,
            toOffset: destination
        )
        scheduleSave()
    }

    func resetQuickStartPresets() {
        quickStartPresets = QuickStartPresetLibrary.defaults
        scheduleSave()
    }

    func openConfiguration() {
        resetDownloadReview()
        configurationReturnsToDetails = true
        presentsMetadata = false
        presentsConfiguration = true
    }

    func applyPreset(_ preset: DownloadPreset) {
        configuration = OutputCapabilityMatrix.selectingMode(
            configuration.mode,
            in: configuration
        )
        configuration.preset = preset
        if preset == .audio {
            configuration.mode = .audioOnly
            configuration.audioCodec = .mp3
            configuration.container = .mp3
        } else if preset == .compatible {
            configuration.videoCodec = .h264
            configuration.audioCodec = .automatic
            configuration.container = .mp4
        } else if preset == .small {
            configuration.maximumResolution = 720
            configuration.preserveSourceResolution = false
        }
        if let analyzedMetadata {
            FormatSelection.applyAutomaticSelection(
                to: &configuration,
                metadata: analyzedMetadata
            )
        }
        configuration = OutputCapabilityMatrix.normalized(configuration)
    }

    func selectMode(_ mode: DownloadMode) {
        let hadMediaTimeline = configuration.hasMediaTimeline
        configuration = OutputCapabilityMatrix.selectingMode(
            mode,
            in: configuration
        )
        if mode == .audioOnly {
            configuration.selectedVideoFormatID = nil
        } else if mode == .videoOnly {
            configuration.selectedAudioFormatID = nil
        }
        if let analyzedMetadata {
            FormatSelection.applyAutomaticSelection(
                to: &configuration,
                metadata: analyzedMetadata
            )
        }
        configuration = OutputCapabilityMatrix.normalized(configuration)
        if hadMediaTimeline != configuration.hasMediaTimeline { beginSponsorBlockPreview() }
    }

    func selectThumbnailBehavior(_ behavior: ThumbnailBehavior) {
        let hadMediaTimeline = configuration.hasMediaTimeline
        configuration = OutputCapabilityMatrix.selectingThumbnailBehavior(
            behavior,
            in: configuration
        )
        if hadMediaTimeline != configuration.hasMediaTimeline { beginSponsorBlockPreview() }
        if behavior != .thumbnailOnly, let analyzedMetadata {
            FormatSelection.applyAutomaticSelection(
                to: &configuration,
                metadata: analyzedMetadata
            )
            configuration = OutputCapabilityMatrix.normalized(configuration)
        }
    }

    func selectDefaultSubtitlesIfNeeded() {
        guard configuration.subtitleDelivery != .none,
              configuration.subtitleSelections == nil, let analyzedMetadata,
              let selection = SubtitleSelectionPlanner.defaultEnglishSelection(in: analyzedMetadata.subtitles)
        else { return }
        configuration.subtitleSelections = [selection]
        configuration = OutputCapabilityMatrix.normalized(configuration)
    }

    func selectSubtitleDelivery(_ delivery: SubtitleDelivery) {
        configuration.subtitleDelivery = delivery
        selectDefaultSubtitlesIfNeeded()
    }

    func selectSubtitlesOnly() {
        configuration = OutputCapabilityMatrix.selectingSubtitlesOnly(in: configuration)
        selectDefaultSubtitlesIfNeeded()
        beginSponsorBlockPreview()
        if ![.sidecarVTT, .sidecarSRT].contains(
            configuration.subtitleDelivery
        ) {
            configuration.subtitleDelivery = .sidecarVTT
        }
        configuration = OutputCapabilityMatrix.normalized(configuration)
    }

    func showConfirmation() {
        guard !isStartingDownload, completedDownloadReviewID != downloadReviewID else { return }
        configuration = OutputCapabilityMatrix.normalized(configuration)
        let thumbnailOnly = configuration.thumbnailBehavior == .thumbnailOnly
        let subtitlesOnly = configuration.isSubtitlesOnly
        if let reason = configuration.sourceModeAvailability(
            in: analyzedMetadata
        ).unavailableReason {
            alert = AppAlert(
                title: "Output mode unavailable",
                message: "\(reason) Choose an available output mode to continue."
            )
            return
        }
        guard thumbnailOnly || subtitlesOnly
            || !configuration.selectedFormatIDs.isEmpty else {
            alert = .error(IllucetError.noCompatibleFormat)
            return
        }
        if let analyzedMetadata {
            do {
                try OutputCapabilityMatrix.validate(
                    configuration,
                    metadata: analyzedMetadata
                )
                let sponsorPlan = try SponsorBlockPlanner.validateLaunch(
                    policy: configuration.effectiveSponsorBlock,
                    videoID: analyzedMetadata.videoID,
                    analyzedDuration: analyzedMetadata.durationSeconds
                )
                if sponsorPlan.entries.contains(where: {
                    $0.action == .remove
                }) {
                    try SponsorBlockExecutionSupport.validate(
                        plan: sponsorPlan,
                        policy: configuration.effectiveSponsorBlock,
                        configuration: configuration,
                        outputPlan: try OutputCapabilityMatrix.makePlan(
                            configuration: configuration,
                            metadata: analyzedMetadata
                        )
                    )
                }
            } catch {
                alert = .error(error)
                return
            }
        }
        if configuration.destination == .askEveryTime {
            alert = AppAlert(
                title: "Choose a destination",
                message: subtitlesOnly
                    ? "Select Illucet, Files, or Share before starting."
                    : "Select Illucet, Files, Photos, or Share before starting."
            )
            return
        }
        if [
            ExportDestination.filesFolder,
            .filesAndPhotos,
        ].contains(configuration.destination) {
            isStartingDownload = true
            Task {
                let allowed = await ensureFilesFolderAccess(presentingFrom: .configuration)
                isStartingDownload = false
                guard allowed else { return }
                presentConfirmation()
            }
            return
        }
        presentConfirmation()
    }

    private func presentConfirmation() {
        if settings.experience.skipDownloadReview {
            confirmDownload()
            return
        }
        presentsConfiguration = false
        presentsConfirmation = true
        refreshAvailableStorage()
    }

    func confirmDownload() {
        guard !startupState.blocksInteraction, !isStartingDownload,
              let analyzedMetadata else { return }
        do {
            try OutputCapabilityMatrix.validate(
                configuration,
                metadata: analyzedMetadata
            )
            let sponsorPlan = try SponsorBlockPlanner.validateLaunch(
                policy: configuration.effectiveSponsorBlock,
                videoID: analyzedMetadata.videoID,
                analyzedDuration: analyzedMetadata.durationSeconds
            )
            if sponsorPlan.entries.contains(where: { $0.action == .remove }) {
                try SponsorBlockExecutionSupport.validate(
                    plan: sponsorPlan,
                    policy: configuration.effectiveSponsorBlock,
                    configuration: configuration,
                    outputPlan: try OutputCapabilityMatrix.makePlan(
                        configuration: configuration,
                        metadata: analyzedMetadata
                    )
                )
            }
        } catch {
            alert = .error(error)
            return
        }
        let selectedConfiguration = configuration
        let version = extractionVersions?.ytDLP
        let source: FilesFolderPickerSource = presentsConfiguration ? .configuration : .confirmation
        guard let claim = claimDownloadSubmission() else { return }
        Task {
            var submitted = false
            defer { finishDownloadSubmission(claim, succeeded: submitted) }
            if [.filesFolder, .filesAndPhotos].contains(selectedConfiguration.destination),
               !(await ensureFilesFolderAccess(presentingFrom: source)) { return }
            guard configuration == selectedConfiguration else { return }
            refreshAvailableStorage()
            do {
                if let required = FormatSelection.estimatedTemporaryBytes(
                    configuration: selectedConfiguration, metadata: analyzedMetadata) {
                    try StorageByteArithmetic.validateBudget(requiredBytes: required,
                        reserveBytes: settings.minimumFreeSpaceReserveBytes,
                        availableBytes: storage.availableBytes)
                }
                let overLimit = try await approveTransferAdmission()
                if let request = activeShortcutRequest, request.url == analyzedMetadata.canonicalURL {
                    _ = try await enqueueShortcut(metadata: analyzedMetadata,
                        configuration: selectedConfiguration, version: version, request: request, transferLimitOverride: overLimit)
                    activeShortcutRequest = nil
                } else {
                    _ = try await coordinator.enqueue(metadata: analyzedMetadata,
                        configuration: selectedConfiguration, extractorVersion: version, transferLimitOverride: overLimit)
                }
                submitted = true
                presentsConfirmation = false
                presentsConfiguration = false
                activeQuickStartPreset = nil
                selectedTab = .queue
            } catch is CancellationError {
                // Keep the review available when the user cancels admission.
            } catch {
                alert = .error(error)
            }
        }
    }

    var sponsorBlockReviewState: SponsorBlockReviewState {
        SponsorBlockReviewState.resolve(
            policy: configuration.effectiveSponsorBlock,
            previewState: sponsorBlockPreviewState,
            metadata: analyzedMetadata,
            configuration: configuration
        )
    }

    var sponsorBlockFastModeAvailable: Bool {
        SponsorBlockExecutionSupport.fastModeAvailable(
            configuration: configuration,
            metadata: analyzedMetadata
        )
    }

    func updateSponsorBlockPolicy(_ requestedPolicy: SponsorBlockPolicy) {
        let oldPolicy = configuration.sponsorBlock
        var policy = requestedPolicy.normalized()
        let requestChanged = oldPolicy.requestedDiscoveryCategories
            != policy.requestedDiscoveryCategories
        if requestChanged { policy.clearSelection() }
        configuration.sponsorBlock = policy
        if requestChanged { beginSponsorBlockPreview() }
    }

    func setSponsorBlockSegmentIncluded(
        _ included: Bool,
        segmentID: String
    ) {
        var policy = configuration.sponsorBlock
        guard var snapshot = policy.selectionSnapshot,
              let index = snapshot.segments.firstIndex(where: {
                  $0.segmentID == segmentID
              })
        else {
            return
        }
        snapshot.segments[index].isIncluded = included
        policy.selectionSnapshot = snapshot
        configuration.sponsorBlock = policy
    }

    func setSponsorBlockSegmentAction(
        _ action: SponsorBlockAction?,
        segmentID: String
    ) {
        var policy = configuration.sponsorBlock
        guard var snapshot = policy.selectionSnapshot,
              let index = snapshot.segments.firstIndex(where: {
                  $0.segmentID == segmentID
              })
        else {
            return
        }
        snapshot.segments[index].actionOverride = action
        policy.selectionSnapshot = snapshot
        configuration.sponsorBlock = policy
    }

    func retrySponsorBlockPreview() {
        var policy = configuration.sponsorBlock
        policy.lookupUnavailable = false
        configuration.sponsorBlock = policy
        beginSponsorBlockPreview()
    }

    func beginSponsorBlockPreview() {
        sponsorBlockPreviewTask?.cancel()
        sponsorBlockPreviewTask = nil
        var policy = configuration.sponsorBlock
        guard configuration.hasMediaTimeline, let metadata = analyzedMetadata,
              policy.needsSegmentReview
        else {
            sponsorBlockPreviewState = .idle
            return
        }
        let videoID = metadata.videoID
        let categories = policy.requestedDiscoveryCategories
        policy.lookupUnavailable = false
        configuration.sponsorBlock = policy
        sponsorBlockPreviewState = .loading
        sponsorBlockPreviewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let segments = try await sponsorBlockService.segments(
                    videoID: videoID,
                    categories: categories
                )
                try Task.checkCancellation()
                let currentPolicy = configuration.sponsorBlock
                guard configuration.hasMediaTimeline, analyzedMetadata?.videoID == videoID,
                      currentPolicy.isEnabled,
                      currentPolicy.requestedDiscoveryCategories == categories
                else {
                    return
                }
                var updatedPolicy = currentPolicy
                updatedPolicy.replaceSelection(
                    videoID: videoID,
                    queriedCategories: categories,
                    segments: segments
                )
                configuration.sponsorBlock = updatedPolicy
                await sponsorBlockDiagnostics.record(
                    event: "segment_selection_completed",
                    detail: "category_count=\(categories.count), segment_count=\(segments.count)"
                )
                sponsorBlockPreviewState = segments.isEmpty
                    ? .empty
                    : .loaded(count: segments.count)
            } catch is CancellationError {
                return
            } catch let error as SponsorBlockServiceError {
                guard !Task.isCancelled, configuration.hasMediaTimeline,
                      analyzedMetadata?.videoID == videoID,
                      configuration.sponsorBlock.isEnabled,
                      configuration.sponsorBlock.requestedDiscoveryCategories
                        == categories
                else {
                    return
                }
                var unavailable = configuration.sponsorBlock
                unavailable.markLookupUnavailable()
                configuration.sponsorBlock = unavailable
                await sponsorBlockDiagnostics.record(
                    .warning,
                    event: "segment_selection_failed",
                    detail: "classification=service_error"
                )
                sponsorBlockPreviewState = .failed(error)
            } catch {
                guard !Task.isCancelled, configuration.hasMediaTimeline,
                      analyzedMetadata?.videoID == videoID,
                      configuration.sponsorBlock.isEnabled,
                      configuration.sponsorBlock.requestedDiscoveryCategories
                        == categories
                else {
                    return
                }
                var unavailable = configuration.sponsorBlock
                unavailable.markLookupUnavailable()
                configuration.sponsorBlock = unavailable
                await sponsorBlockDiagnostics.record(
                    .warning,
                    event: "segment_selection_failed",
                    detail: "classification=unexpected"
                )
                sponsorBlockPreviewState = .failed(.transportFailure)
            }
            sponsorBlockPreviewTask = nil
        }
    }
}
