import Foundation

enum BulkImportStep: Sendable { case input, links, items }

struct BulkMediaItem: Identifiable, Equatable, Sendable {
    let id: String
    let metadata: MediaMetadata
    var configuration: DownloadConfiguration
    var selected = true
    var site: MediaSite { metadata.sourceIdentity?.site ?? .youtube }
}

extension IllucetAppModel {
    func openSharedBatch(_ batch: SharedLinkBatch) {
        guard !isAnalyzing, !isStartingDownload, !bulkImportBusy else { return }
        try? SharedLinkInbox.live().markBulkPresented(batch.id)
        openBulkImport(text: batch.urls.map(\.absoluteString).joined(separator: "\n"))
        activeSharedBatchID = batch.id
    }
    func openBulkImport(text: String = "", individual: Bool = false) {
        guard !isAnalyzing, !isStartingDownload, !bulkImportBusy else { return }
        bulkIndividualSource = individual
        activeSharedBatchID = nil
        bulkSubmissionID = UUID()
        bulkImportText = text
        bulkLinks = []; bulkAssets = []; bulkImportMessage = nil; bulkImportStep = .input
        bulkFailedLinks = []; bulkSkipArchived = true
        bulkBaseConfiguration = settings.configuration()
        bulkBaseConfiguration.maximumPlaylistItems = 500
        bulkBaseConfiguration.continuePlaylistOnError = true
        bulkBaseConfiguration.duplicateHandlingOverride = settings.duplicateHandling
        presentsBulkImport = true
        if !text.isEmpty { scanBulkLinks() }
        if individual { analyzeBulkLinks() }
    }

    func scanBulkLinks() {
        do {
            bulkLinks = try BulkLinkImport.links(in: bulkImportText)
            bulkImportStep = .links
            bulkImportMessage = bulkLinks.isEmpty ? "No webpage links found. Paste text containing links or choose a text document." : nil
        } catch { bulkImportMessage = error.localizedDescription }
    }

    func analyzeBulkLinks() {
        guard !bulkImportBusy else { return }
        let links = bulkLinks.filter(\.selected)
        guard !links.isEmpty else { bulkImportMessage = "Select at least one supported link."; return }
        bulkImportBusy = true; bulkAssets = []; bulkFailedLinks = []; bulkImportMessage = nil
        bulkImportTask = Task { @MainActor in
            defer { bulkImportBusy = false; bulkImportTask = nil }
            var failures: [String] = []
            var seen: Set<String> = []
            for link in links {
                do {
                    try Task.checkCancellation()
                    guard let site = link.site else { continue }
                    let defaults = settings.siteDefaults?[site.rawValue]
                    let accountID = preferredAccountID(for: site)
                    let preferences = settings.extractionPreferences(for: site)
                    let assets: [MediaMetadata]
                    if fixtureMode {
                        assets = site == .youtube ? [DeveloperFixtures.media] : DeveloperFixtures.externalAssets.filter { $0.sourceIdentity?.site == site }
                    } else if site == .youtube {
                        let intent = try YouTubeURLIntentClassifier.classify(link.url)
                        switch intent {
                        case .video:
                            assets = [try await runtime.extractor(accountID: accountID, preferences: preferences).analyze(url: link.url)]
                        case .playlist:
                            let analysis = try await runtime.playlistAnalyzer(accountID: accountID, preferences: preferences).analyze(url: link.url, maximumEntries: 500)
                            let extractor = try await runtime.extractor(accountID: accountID, preferences: preferences)
                            var loaded: [MediaMetadata] = []
                            for entry in analysis.entries where entry.availability.isDownloadable {
                                try Task.checkCancellation()
                                if let url = entry.canonicalURL { loaded.append(try await extractor.analyze(url: url)) }
                            }
                            assets = loaded
                        }
                    } else {
                        assets = try await runtime.externalPost(url: link.url, accountID: accountID, preferences: preferences).assets
                    }
                    for metadata in assets {
                        let key = metadata.sourceIdentity?.archiveID ?? "youtube:\(metadata.videoID)"
                        guard seen.insert(key).inserted else { continue }
                        guard bulkAssets.count < 500 else { throw BulkImportError.tooManyLinks }
                        var configuration = configurationForImportedMedia(metadata, preferences: preferences)
                        configuration.accountID = accountID
                        if defaults?.preset == "compatible", metadata.sourceIdentity?.kind != .image {
                            var compatible = configuration
                            compatible.preset = .compatible
                            compatible.videoCodec = .h264
                            compatible.container = .mp4
                            compatible = OutputCapabilityMatrix.normalized(compatible)
                            FormatSelection.applyAutomaticSelection(to: &compatible, metadata: metadata)
                            if (try? OutputCapabilityMatrix.validate(compatible, metadata: metadata)) != nil {
                                configuration = compatible
                            }
                        }
                        try OutputCapabilityMatrix.validate(configuration, metadata: metadata)
                        bulkAssets.append(.init(id: key, metadata: metadata, configuration: configuration))
                    }
                } catch is CancellationError { return }
                catch { bulkFailedLinks.append(link.url); failures.append("\(link.site?.name ?? "Link"): \(error.localizedDescription)") }
            }
            guard !Task.isCancelled else { return }
            bulkImportStep = .items
            bulkImportMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
            if bulkIndividualSource, bulkAssets.count == 1, failures.isEmpty,
               bulkAssets[0].metadata.sourceIdentity?.kind != .image {
                let item = bulkAssets[0]
                analyzedMetadata = item.metadata
                configuration = item.configuration
                configurationReturnsToDetails = false
                addRecent(item.metadata)
                presentsBulkImport = false
                // Present after the import sheet's dismissal animation.
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                presentsConfiguration = true
            }
        }
    }

    func configurationForImportedMedia(_ metadata: MediaMetadata, preferences: EnginePreferences) -> DownloadConfiguration {
        var configuration = settings.configuration()
        configuration.sourceIdentity = metadata.sourceIdentity
        configuration.assetFingerprint = metadata.assetFingerprint
        configuration.enginePreferences = preferences
        configuration.accountID = nil
        configuration.sponsorBlock = .disabled
        configuration.thumbnailBehavior = .none
        configuration.subtitleDelivery = .none
        configuration.subtitleSelections = nil
        configuration.splitChapters = false
        configuration.bundleStyle = .mediaOnly
        configuration.metadataSidecars = nil
        configuration.maximumPlaylistItems = 500
        configuration.continuePlaylistOnError = true
        configuration.videoCodec = .automatic; configuration.audioCodec = .automatic
        configuration.preset = .best
        configuration.container = .automatic; configuration.maximumResolution = nil
        configuration.preserveSourceResolution = true
        configuration.trimStartSeconds = nil; configuration.trimEndSeconds = nil
        let availability = SourceModeAvailability(analyzedMetadata: metadata)
        configuration.mode = [DownloadMode.videoAndAudio, .videoOnly, .audioOnly]
            .first { availability.status(for: $0).permitsSelection } ?? .videoAndAudio
        configuration = OutputCapabilityMatrix.normalized(configuration)
        FormatSelection.applyAutomaticSelection(to: &configuration, metadata: metadata)
        return configuration
    }

    func cancelBulkImport() {
        bulkImportTask?.cancel()
        dismissFilesFolderPicker(from: .bulkImport)
        presentsBulkImport = false
        bulkImportText = ""
    }

    func startImportedBatch() {
        guard !bulkImportBusy else { return }
        let selected = bulkAssets.filter(\.selected)
        guard !selected.isEmpty else { bulkImportMessage = "Select at least one media item."; return }
        bulkImportBusy = true
        bulkImportTask = Task { @MainActor in
            defer { bulkImportBusy = false; bulkImportTask = nil }
            do {
                if [.filesFolder, .filesAndPhotos].contains(bulkBaseConfiguration.destination),
                   !(await ensureFilesFolderAccess(presentingFrom: .bulkImport)) { return }
                _ = try await enqueueImportedBatch(selected, baseConfiguration: bulkBaseConfiguration,
                    title: "Imported media", admissionID: activeSharedBatchID ?? bulkSubmissionID,
                    skipArchived: bulkSkipArchived)
                if let id = activeSharedBatchID { try? SharedLinkInbox.live().removeBulk(id); savedLinkBatches.removeAll { $0.id == id }; activeSharedBatchID = nil }
                presentsBulkImport = false
                bulkImportText = ""
                selectedTab = .queue
            } catch is CancellationError { return }
            catch { bulkImportMessage = error.localizedDescription }
        }
    }
    func enqueueImportedBatch(_ selected: [BulkMediaItem], baseConfiguration: DownloadConfiguration,
                              title: String, admissionID: UUID, skipArchived: Bool) async throws -> DownloadBatch {
        guard !selected.isEmpty && selected.count <= 500 else { throw BulkImportError.tooManyLinks }
        try Task.checkCancellation()
        let entries = selected.enumerated().map { index, item in
            PlaylistEntry(id: item.id, index: index+1, videoID: item.metadata.videoID,
                canonicalURL: item.metadata.canonicalURL, title: item.metadata.title,
                creator: item.metadata.uploader, durationSeconds: item.metadata.durationSeconds,
                thumbnailURL: nil, estimatedBytes: nil, availability: .available)
        }
        let analysis = PlaylistAnalysis(canonicalURL: selected[0].metadata.canonicalURL,
            playlistID: admissionID.uuidString, kind: .importedLinks, referencedVideoID: nil,
            title: title, creator: nil, thumbnailURL: nil, reportedItemCount: entries.count,
            estimatedTotalBytes: nil, entries: entries, isTruncated: false)
        var base = baseConfiguration
        base.maximumPlaylistItems = 500
        let overrides = try Dictionary(uniqueKeysWithValues: selected.map { item in
            var value = item.configuration
            value.destination = base.destination
            value.filenameTemplate = base.filenameTemplate
            value.duplicateHandlingOverride = base.duplicateHandlingOverride
            try OutputCapabilityMatrix.validate(value, metadata: item.metadata)
            return (item.id, value)
        })
        let batch = try await batchController.createBatch(analysis: analysis, selection: .entirePlaylist,
            configuration: base, itemOverrides: overrides, destinationStructure: .selectedFolder,
            skipArchivedItems: skipArchived, admissionID: admissionID, holdForPersistence: true)
        if let index = batches.firstIndex(where: { $0.id == batch.id }) { batches[index] = batch }
        else { batches.append(batch) }
        saveTask?.cancel()
        try await saveSnapshot()
        if batch.admissionPaused == true { await batchController.resume(batch.id) }
        return batch
    }

}
