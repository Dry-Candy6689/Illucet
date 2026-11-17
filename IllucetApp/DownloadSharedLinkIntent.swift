import AppIntents
import Foundation
import UIKit

struct DownloadSharedLinkIntent: LiveActivityIntent, ProgressReportingIntent {
    static let title: LocalizedStringResource = "Download with Illucet"
    static let description = IntentDescription("Download shared media using your preferences in Illucet Settings → Sharing & Shortcuts.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Links") var links: [URL]
    static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$links) with Illucet")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard !links.isEmpty else { throw SharedLinkIntentError.missingInput }
        let candidates = Self.canonicalLinks(links)
        guard !candidates.isEmpty else { throw SharedLinkIntentError.unsupported }
        if candidates.count > 1 {
            let batch = try SharedLinkInbox.live().saveBulk(candidates, presented: true)
            let began = ContinuousClock.now
            let message: String
            if #available(iOS 27, *) {
                message = try await performBackgroundTask { @Sendable in
                    try await prepareBatch(batch, began: began, extended: true)
                }
            } else { message = try await prepareBatch(batch, began: began, extended: false) }
            return .result(value: message, dialog: "\(message)")
        }
        let link = candidates[0]
        let request = try SharedLinkInbox.live().save(link, shortcut: true)
        let began = ContinuousClock.now
        JobStatusPresentation.updateSystemProgress(progress, stage: "Preparing download", fraction: nil)
        let status: String
        do {
            if #available(iOS 27, *) {
                // Cold startup and extraction need the same grant as transfer
                // and processing; asking only after startup can time out first.
                status = try await performBackgroundTask { @Sendable in
                    try await prepareAndRun(request, began: began, extended: true)
                }
            } else {
                status = try await prepareAndRun(request, began: began, extended: false)
            }
        } catch {
            let model = IllucetApplicationServices.model
            await model.liveActivityController.synchronize(jobs: await model.coordinator.currentJobs(),
                enabled: model.settings.liveActivities)
            JobStatusPresentation.updateSystemProgress(progress, stage: "Download failed", fraction: nil)
            if error is CancellationError {
                let message = "Your link is saved. Open Illucet to continue."
                try await model.deferShortcut(request, message: message, automatic: true)
                return .result(value: message, dialog: "\(message)")
            }
            throw error
        }
        return .result(value: status, dialog: "\(status)")
    }

    @MainActor
    private func prepareBatch(_ request: SharedLinkBatch, began: ContinuousClock.Instant, extended: Bool) async throws -> String {
        let model = IllucetApplicationServices.model
        while model.startupState == .loading {
            try Task.checkCancellation()
            if !extended && began.duration(to: .now) >= .seconds(18) { return "Shared links saved. Open Illucet to continue." }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await model.waitForShortcutStartup()
        let preferences = model.settings.shortcutPreferences
        func review(_ reason: String) async -> String {
            if preferences.allowsForeground, (try? await foreground()) != nil,
               model.canPresentShortcutOptions, model.URLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.openSharedBatch(request)
            } else { model.refreshSharedLinks() }
            return reason
        }
        switch preferences.behavior {
        case .save:
            model.refreshSharedLinks()
            return "Saved \(request.urls.count) links for later."
        case .ask, .options:
            return await review("Shared links saved. Review them in Illucet.")
        case .download:
            var result: Result<DownloadBatch, Error>?
            let task = Task { @MainActor in
                do { result = .success(try await model.submitShortcutBatch(request.urls, id: request.id, preferences: preferences)) }
                catch { result = .failure(error) }
            }
            defer { task.cancel() }
            do {
                while result == nil {
                    try Task.checkCancellation()
                    if !extended && began.duration(to: .now) >= .seconds(18) {
                        task.cancel()
                        return await review("Shared links saved. Open Illucet to finish preparing them.")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let batch = try result!.get()
                try? SharedLinkInbox.live().removeBulk(request.id)
                model.refreshSharedLinks()
                return "Queued \(batch.items.count) shared media items."
            } catch is CancellationError {
                return "Shared links saved. Open Illucet to continue."
            } catch {
                return await review("Shared links saved. \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func prepareAndRun(_ request: SharedLink, began: ContinuousClock.Instant, extended: Bool) async throws -> String {
        let model = IllucetApplicationServices.model
        while model.startupState == .loading {
            try Task.checkCancellation()
            if !extended && began.duration(to: .now) >= .seconds(18) {
                let message = "Your link is saved. Open Illucet to start the download."
                try await model.deferShortcut(request, message: message, automatic: true)
                return message
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await model.waitForShortcutStartup()
        let preferences = model.settings.shortcutPreferences
        if preferences.behavior == .save {
            try SharedLinkInbox.live().markPresented(request.id)
            model.refreshSharedLinks()
            return "Link saved for later."
        }
        if preferences.behavior != .download {
            let reason = "Choose how to download this link."
            if preferences.allowsForeground, (try? await foreground()) != nil {
                model.presentShortcutHandoff(.init(request: request, reason: reason))
                return "Continue in Illucet."
            }
            try await model.deferShortcut(request, message: reason, automatic: false)
            return "Link saved. Open Illucet to review it."
        }
        if model.presentsOnboarding {
            let message = "Open Illucet to finish setup. Your link is saved."
            try await model.deferShortcut(request, message: message, automatic: false)
            return message
        }
        return try await runDownload(request, began: began, extended: extended)
    }

    @MainActor
    private func runDownload(_ request: SharedLink, began: ContinuousClock.Instant, extended: Bool) async throws -> String {
        let model = IllucetApplicationServices.model
        await model.coordinator.beginIntentExecution(jobID: request.id)
        let operation = model.shortcutOperation(for: request)
        defer { model.shortcutOperations.removeValue(forKey: request.id) }
        do {
            let result = try await withTaskCancellationHandler {
                while operation.result == nil {
                    try Task.checkCancellation()
                    if !extended && began.duration(to: .now) >= .seconds(18) { throw PreparationBudgetExpired() }
                    try await Task.sleep(for: .milliseconds(100))
                }
                return try operation.result!.get()
            } onCancel: { Task { @MainActor in operation.cancel() } }
            let message: String
            switch result {
            case let .foreground(handoff):
                try await model.deferShortcut(request, message: handoff.reason, automatic: false)
                if model.settings.shortcutPreferences.allowsForeground, (try? await foreground()) != nil {
                    try? SharedLinkInbox.live().markPresented(request.id)
                    model.presentShortcutHandoff(handoff)
                    message = "Continue in Illucet."
                } else { message = "Open Illucet to continue. Your link is saved." }
            case let .admittedBatch(batch):
                message = "Queued \(batch.items.count) shared media items."
            case let .admitted(admitted):
                await model.liveActivityController.synchronize(jobs: await model.coordinator.currentJobs(),
                    enabled: model.settings.liveActivities, intentStart: true)
                if !(await model.liveActivityController.hasActivity(jobID: admitted.id)), model.settings.notifyNeedsAttention {
                    Task { [notifications = model.notifications] in
                        await notifications.send(id: "shortcut-start-\(admitted.id)", title: Self.admissionMessage(admitted),
                            body: String(admitted.title.prefix(160)), jobID: admitted.id)
                    }
                }
                var current = admitted
                while extended && current.state == .running {
                    try Task.checkCancellation()
                    let presentation = JobStatusPresentation(job: current)
                    JobStatusPresentation.updateSystemProgress(progress, stage: presentation.stage, fraction: presentation.fraction)
                    await model.liveActivityController.synchronize(jobs: await model.coordinator.currentJobs(),
                        enabled: model.settings.liveActivities)
                    try await Task.sleep(for: .seconds(1))
                    guard let latest = await model.coordinator.currentJob(current.id) else { break }
                    current = latest
                }
                message = Self.admissionMessage(current)
                let presentation = JobStatusPresentation(job: current)
                JobStatusPresentation.updateSystemProgress(progress, stage: message, fraction: presentation.fraction)
            }
            await model.coordinator.endIntentExecution(jobID: request.id)
            await model.liveActivityController.synchronize(jobs: await model.coordinator.currentJobs(),
                enabled: model.settings.liveActivities)
            await model.persistImmediately()
            return message
        } catch {
            operation.cancel()
            await model.coordinator.endIntentExecution(jobID: request.id)
            await model.liveActivityController.synchronize(jobs: await model.coordinator.currentJobs(),
                enabled: model.settings.liveActivities)
            await model.persistImmediately()
            let foregroundMessage: String? = switch error {
            case YouTubeTokenError.needsForeground: YouTubeTokenError.needsForeground.localizedDescription
            case RedditPageError.needsForeground: RedditPageError.needsForeground.localizedDescription
            default: nil
            }
            if let message = foregroundMessage {
                try await model.deferShortcut(request, message: message, automatic: true)
                if model.settings.shortcutPreferences.allowsForeground, (try? await foreground()) != nil {
                    await model.resumeDeferredShortcuts()
                }
                return "Link saved. \(message)"
            }
            if error is PreparationBudgetExpired || error is CancellationError {
                let message = "Your progress is saved. Open Illucet to continue."
                JobStatusPresentation.updateSystemProgress(progress, stage: message, fraction: nil)
                try await model.deferShortcut(request, message: message, automatic: true)
                return message
            }
            throw error
        }
    }

    private struct PreparationBudgetExpired: Error {}

    @MainActor
    private func foreground() async throws {
        guard UIApplication.shared.applicationState != .active else { return }
        guard systemContext.currentMode.canContinueInForeground else {
            throw IllucetError.internalFailure("Open Illucet and continue this link from Saved shared links.")
        }
        try await continueInForeground("Continue this download in Illucet.", alwaysConfirm: false)
    }

    static func canonicalLinks(_ links: [URL]) -> [URL] {
        var seen = Set<URL>()
        guard links.count <= 500 else { return [] }
        var result: [URL] = []
        var byteBudget = BulkLinkImport.maximumBytes
        for url in links {
            let raw = url.absoluteString
            guard raw.utf8.count <= byteBudget else { return [] }
            byteBudget -= raw.utf8.count
            // Some Shortcuts versions flatten a URL-list magic variable into
            // one percent-encoded text URL. Recover only validated media links.
            let decoded = raw.removingPercentEncoding ?? raw
            let candidates: [URL]
            if decoded.contains(where: \.isWhitespace) {
                candidates = (try? BulkLinkImport.links(in: decoded))?.filter(\.selected).map(\.url) ?? []
            } else {
                candidates = SharedLinkParser.canonicalURL(url).map { [$0] } ?? []
            }
            for candidate in candidates where seen.insert(candidate).inserted {
                result.append(candidate)
                guard result.count <= 500 else { return [] }
            }
        }
        return result
    }

    static func admissionMessage(_ job: DownloadJob) -> String {
        switch job.state {
        case .waitingForWiFi: "Queued — waiting for Wi-Fi"
        case .waitingForPower: "Queued — waiting for charging"
        case .waitingForNetwork: "Queued — waiting for a connection"
        case .waitingForCellularApproval: "Queued — open Illucet to approve cellular data"
        case .needsAttention: "Open Illucet to continue"
        case .completed: "Download completed"
        case .failed: "Download failed — open Illucet for details"
        case .cancelled: "Download cancelled"
        case .paused: "Download paused"
        case .waitingForRetry: "Queued — waiting to retry"
        case .running where job.activeTransferDescriptors?.isEmpty == false: "Download started"
        default: "Added to the download queue"
        }
    }
}

@available(iOS 27, *)
extension DownloadSharedLinkIntent: LongRunningIntent {}
