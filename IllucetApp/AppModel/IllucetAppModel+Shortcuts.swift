import Foundation
import UIKit
import Photos

/// Both an App Intent cold launch and SwiftUI resolve this same owner. Never
/// create a second Python runtime, persistence writer or background URLSession.
@MainActor
enum IllucetApplicationServices {
    static let model = IllucetAppModel()
}

struct PreparedShortcutDownload: Sendable {
    let metadata: MediaMetadata
    var configuration: DownloadConfiguration
    let version: String?
}

struct ShortcutHandoff: Identifiable, Sendable {
    let request: SharedLink
    let reason: String
    var prepared: PreparedShortcutDownload?
    var id: UUID { request.id }
}

enum ShortcutSubmissionResult: Sendable {
    case admitted(DownloadJob)
    case foreground(ShortcutHandoff)
}

@MainActor
final class ShortcutDownloadOperation {
    private(set) var result: Result<ShortcutSubmissionResult, Error>?
    private var task: Task<Void, Never>?

    init(model: IllucetAppModel, request: SharedLink) {
        task = Task { [weak self] in
            do { self?.result = .success(try await model.submitShortcut(request)) }
            catch { self?.result = .failure(error) }
        }
    }

    func cancel() { task?.cancel() }
}

extension IllucetAppModel {
    func deferShortcut(_ request: SharedLink, message: String, automatic: Bool) async throws {
        try SharedLinkInbox.live().deferUntilForeground(request.id, automatic: automatic, message: message)
        refreshSharedLinks()
        if settings.notifyNeedsAttention {
            let jobID = await coordinator.currentJob(request.id)?.id
            Task { [notifications] in
                await notifications.send(id: "shortcut-wait-\(request.id)", title: "Open Illucet to continue",
                    body: message, jobID: jobID, requestID: request.id)
            }
        }
    }

    func resumeDeferredShortcuts() async {
        guard UIApplication.shared.applicationState == .active, !presentsOnboarding else { return }
        guard let inbox = try? SharedLinkInbox.live(), let pending = try? inbox.pending() else { return }
        for request in pending where request.foregroundMessage != nil && request.presentedAt == nil {
            guard shortcutOperations[request.id] == nil else { continue }
            // Claim once before awaiting; app activation and notification routing
            // can arrive together. A failed attempt remains in Saved shared links.
            do { try inbox.markPresented(request.id) } catch { continue }
            if request.resumeOnForeground == true {
                let operation = shortcutOperation(for: request)
                while operation.result == nil {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
                shortcutOperations.removeValue(forKey: request.id)
                do {
                    switch try operation.result!.get() {
                    case let .foreground(handoff): presentShortcutHandoff(handoff)
                    case .admitted: break
                    }
                } catch { alert = .error(error) }
            } else {
                presentShortcutHandoff(.init(request: request, reason: request.foregroundMessage ?? "Continue this link."))
            }
        }
    }

    func openDownloadNotification(jobID: UUID?, requestID: UUID?) async {
        do { try await waitForShortcutStartup() } catch { return }
        await refreshQueueOnActivation()
        if let jobID, let job = await coordinator.currentJob(jobID) {
            selectedTab = .queue
            selectedJob = job
        } else if let requestID, let request = sharedLinkInbox.first(where: { $0.id == requestID }),
                  request.foregroundMessage == nil {
            await continueShortcutInApp(request)
        }
    }

    func waitForShortcutStartup() async throws {
        while startupState == .loading {
            try await Task.sleep(for: .milliseconds(50))
        }
        if case let .blocked(error) = startupState { throw error }
        try Task.checkCancellation()
    }

    func shortcutOperation(for request: SharedLink) -> ShortcutDownloadOperation {
        if let existing = shortcutOperations[request.id] { return existing }
        let operation = ShortcutDownloadOperation(model: self, request: request)
        shortcutOperations[request.id] = operation
        return operation
    }

    func submitShortcut(_ request: SharedLink, behaviorOverride: ShortcutBehavior? = nil) async throws -> ShortcutSubmissionResult {
        try await waitForShortcutStartup()
        if let job = await coordinator.currentJob(request.id) {
            guard job.sourceURL == request.url else {
                throw IllucetError.internalFailure("This shared-link request belongs to a different video.")
            }
            try? SharedLinkInbox.live().remove(request.id)
            return .admitted(job)
        }
        if let record = history.first(where: { $0.jobID == request.id }) {
            throw IllucetError.internalFailure("This request is already in History: \(record.title)")
        }
        var preferences = settings.shortcutPreferences
        if let behaviorOverride { preferences.behavior = behaviorOverride }
        func handoff(_ message: String, _ prepared: PreparedShortcutDownload? = nil) -> ShortcutSubmissionResult {
            .foreground(ShortcutHandoff(request: request, reason: message, prepared: prepared))
        }
        guard !presentsOnboarding else { return handoff("Finish setting up Illucet to start this download.") }
        guard preferences.behavior == .download else {
            return handoff(preferences.behavior == .ask ? "Choose how to download this link." : "Review the download options.")
        }
        guard case .video = try YouTubeURLIntentClassifier.classify(request.url) else {
            return handoff("Choose the videos to download from this collection.")
        }
        let preset: QuickStartPreset
        if let id = preferences.preferredPresetID {
            guard let saved = quickStartPresets.first(where: { $0.id == id }) else {
                return handoff("Your selected preset is no longer available. Choose download options.")
            }
            preset = saved
        } else {
            preset = QuickStartPreset(name: "Download defaults", systemImage: "arrow.down", configuration: settings.configuration())
        }
        let accountID = preset.configuration.accountID ?? selectedAccountID
        let metadata: MediaMetadata
        let version: String?
        if fixtureMode {
            metadata = DeveloperFixtures.media
            version = nil
        } else {
            let extractor = try await runtime.extractor(accountID: accountID)
            metadata = try await extractor.analyze(url: request.url)
            version = try? await extractor.versions().ytDLP
        }
        try Task.checkCancellation()
        var config: DownloadConfiguration
        do { config = try preset.resolvedConfiguration(metadata: metadata) }
        catch { return handoff(error.localizedDescription, PreparedShortcutDownload(metadata: metadata, configuration: settings.configuration(), version: version)) }
        config.accountID = accountID
        // The same discovery and launch policy used by the picker. Automatic
        // rules need no UI; only unresolved Ask rules require foreground review.
        if config.effectiveSponsorBlock.isEnabled {
            var policy = config.sponsorBlock
            do {
                let segments = try await sponsorBlockService.segments(videoID: metadata.videoID, categories: policy.requestedDiscoveryCategories)
                try Task.checkCancellation()
                policy.replaceSelection(videoID: metadata.videoID, queriedCategories: policy.requestedDiscoveryCategories, segments: segments)
            } catch is CancellationError { throw CancellationError() }
            catch { policy.markLookupUnavailable() }
            config.sponsorBlock = policy
        }
        let prepared = PreparedShortcutDownload(metadata: metadata, configuration: config, version: version)
        if [.photos, .filesAndPhotos].contains(config.destination),
           PHPhotoLibrary.authorizationStatus(for: .addOnly) != .authorized {
            return handoff("Allow Photos access in Illucet before starting this download.", prepared)
        }
        var hasFolder = false
        if [.filesFolder, .filesAndPhotos].contains(config.destination), let bookmark = snapshot.filesFolderBookmark {
            hasFolder = (try? await exporter.testFolderAccessDetail(bookmark: bookmark)) != nil
        }
        do {
            try QuickStartLaunchPolicy.validate(configuration: config, metadata: metadata, hasFilesFolder: hasFolder,
                availableBytes: storageManager.availableCapacity(), reserveBytes: settings.minimumFreeSpaceReserveBytes)
        } catch { return handoff(error.localizedDescription, prepared) }
        try Task.checkCancellation()
        await coordinator.configure(settings: settings, folderBookmark: snapshot.filesFolderBookmark)
        try Task.checkCancellation()
        let job = try await enqueueShortcut(metadata: metadata, configuration: config, version: version, request: request)
        return .admitted(try await waitForShortcutAdmission(job))
    }

    /// Options and automatic submissions use the same durable request identity.
    func enqueueShortcut(metadata: MediaMetadata, configuration: DownloadConfiguration,
                         version: String?, request: SharedLink, transferLimitOverride: Bool = false) async throws -> DownloadJob {
        guard metadata.canonicalURL == request.url else {
            throw IllucetError.internalFailure("The analyzed video does not match this shared link.")
        }
        let job = try await coordinator.enqueue(metadata: metadata, configuration: configuration, extractorVersion: version, admissionID: request.id, transferLimitOverride: transferLimitOverride)
        do {
            jobs = await coordinator.currentJobs()
            saveTask?.cancel()
            try await saveSnapshot()
        } catch {
            await coordinator.discardAdmission(request.id)
            jobs = await coordinator.currentJobs()
            throw error
        }
        // Once committed, cancellation of the Shortcuts overlay must not cancel
        // an independently owned queue job. Queue controls own it from here.
        await coordinator.commitAdmission(job.id)
        var pipLocal = firstRunState.pip ?? .init()
        pipLocal.analyzedFirstVideo = true
        pipLocal.startedFirstDownload = true
        firstRunState.pip = pipLocal
        scheduleSave()
        try? SharedLinkInbox.live().remove(request.id)
        sharedLinkInbox.removeAll { $0.id == request.id }
        return job
    }

    /// Keep the intent's execution window alive until a native transfer owns the
    /// work, or the queue has a genuine reason to wait. Enqueue alone is not a
    /// background transfer handoff.
    private func waitForShortcutAdmission(_ admitted: DownloadJob) async throws -> DownloadJob {
        while true {
            try Task.checkCancellation()
            guard let current = await coordinator.currentJob(admitted.id) else { throw CancellationError() }
            if current.state == .failed {
                throw IllucetError.internalFailure(current.errorMessage ?? "The download could not start.")
            }
            let waiting = [.waitingForNetwork, .waitingForWiFi, .waitingForPower,
                           .waitingForCellularApproval, .waitingForRetry, .needsAttention,
                           .paused, .completed, .cancelled].contains(current.state)
            let hasTransfer = current.activeTransferDescriptors?.isEmpty == false
            let otherJobs = await coordinator.currentJobs().filter { $0.id != admitted.id && $0.state == .running }
            let waitingForSlot = (current.state == .queued || current.stage == .waitingForTransfer) && !otherJobs.isEmpty
            if waiting || hasTransfer || waitingForSlot {
                jobs = await coordinator.currentJobs()
                saveTask?.cancel()
                try await saveSnapshot()
                return current
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func continueShortcutInApp(_ request: SharedLink) async {
        do {
            try await waitForShortcutStartup()
            if let job = await coordinator.currentJob(request.id) {
                selectedTab = .queue
                selectedJob = job
                return
            }
            presentShortcutHandoff(ShortcutHandoff(request: request, reason: "Continue this saved Shortcut request."))
        } catch { alert = .error(error) }
    }

    var canPresentShortcutOptions: Bool {
        !isAnalyzing && !presentsOnboarding && !presentsMetadata && !presentsConfiguration
            && !presentsConfirmation && !presentsQuickStartConfirmation && !presentsPlaylistBatch
            && !presentsDownloadArchive && !presentsSharedLinkChoice
            && selectedJob == nil && selectedHistoryRecord == nil
            && pendingShareRequest == nil && pendingDuplicateConflict == nil
            && pendingNetworkAccessRequest == nil && alert == nil
    }

    func presentShortcutHandoff(_ handoff: ShortcutHandoff) {
        guard canPresentShortcutOptions, shortcutHandoff == nil else {
            if !deferredShortcutHandoffs.contains(where: { $0.id == handoff.id }) {
                deferredShortcutHandoffs.append(handoff)
            }
            return
        }
        if settings.shortcutPreferences.behavior == .options,
           URLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            openShortcutOptions(handoff)
        } else {
            shortcutHandoff = handoff
        }
    }

    func requestShortcutOptions(_ handoff: ShortcutHandoff) {
        guard canPresentShortcutOptions else { return }
        pendingShortcutOptions = handoff
        shortcutHandoff = nil
    }

    func shortcutHandoffDidDismiss() {
        if let handoff = pendingShortcutOptions {
            pendingShortcutOptions = nil
            openShortcutOptions(handoff)
        } else {
            presentDeferredShortcutHandoff()
        }
    }

    func presentDeferredShortcutHandoff() {
        guard canPresentShortcutOptions, shortcutHandoff == nil, !deferredShortcutHandoffs.isEmpty else { return }
        presentShortcutHandoff(deferredShortcutHandoffs.removeFirst())
    }

    func openShortcutOptions(_ handoff: ShortcutHandoff) {
        guard canPresentShortcutOptions else { return }
        shortcutHandoff = nil
        selectedTab = .download
        activeShortcutRequest = handoff.request
        // Reuse the draft protection and explicit replacement choice. Never
        // silently overwrite another video's open editor or a typed link.
        if !URLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingSharedLink = handoff.request.url
            presentsSharedLinkChoice = true
            return
        }
        if let prepared = handoff.prepared {
            URLText = handoff.request.url.absoluteString
            analyzedMetadata = prepared.metadata
            configuration = OutputCapabilityMatrix.normalized(prepared.configuration)
            if configuration.selectedFormatIDs.isEmpty {
                FormatSelection.applyAutomaticSelection(to: &configuration, metadata: prepared.metadata)
            }
            extractionVersions = nil
            selectDefaultSubtitlesIfNeeded()
            beginSponsorBlockPreview()
            presentsConfiguration = true
        } else {
            pendingSharedLink = handoff.request.url
            applySharedLinkBehavior(.options)
        }
        try? SharedLinkInbox.live().markPresented(handoff.request.id)
    }
}
