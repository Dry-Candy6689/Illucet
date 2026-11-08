import Foundation
import UserNotifications

struct JobNotificationMessage: Sendable {
    let id: String
    let title: String
    let body: String
    let jobID: UUID?
    var requestID: UUID? = nil
}

actor UserNotificationService {
    private let deliver: @Sendable (JobNotificationMessage) async -> Void
    private let foregroundCompletionTime: @MainActor @Sendable () -> Date?
    init(
        foregroundCompletionTime: @escaping @MainActor @Sendable () -> Date? = { nil },
        deliver: @escaping @Sendable (JobNotificationMessage) async -> Void = UserNotificationService.systemSend
    ) {
        self.foregroundCompletionTime = foregroundCompletionTime
        self.deliver = deliver
    }
    private var previousJobs: [UUID: DownloadJob] = [:]
    private var finishedBatches = Set<UUID>()
    private var knownBatches = Set<UUID>()

    func observe(job: DownloadJob, settings: AppSettings) async {
        if let previous = previousJobs[job.id], previous.updatedAt > job.updatedAt { return }
        let events = JobNotificationPolicy.events(previous: previousJobs[job.id], job: job, settings: settings)
        previousJobs[job.id] = job
        for event in events {
            let body = event == .needsAttention && job.resumesOnForeground
                ? "Open Illucet to continue. Your downloaded media has been kept: " + String(job.title.prefix(160))
                : String(job.title.prefix(160))
            await send(id: "\(event.rawValue)-\(job.id)", title: event.title,
                       body: body, jobID: job.id)
        }
    }

    func forget(_ id: UUID) { previousJobs.removeValue(forKey: id) }

    func observe(batch: DownloadBatch, settings: AppSettings) async {
        let first = knownBatches.insert(batch.id).inserted
        guard batch.state == .completed || batch.state == .completedWithFailures else { return }
        if first { finishedBatches.insert(batch.id); return }
        guard batch.destinationStructure != .zipArchive || batch.packageURL != nil || batch.packageErrorMessage != nil else { return }
        guard finishedBatches.insert(batch.id).inserted, settings.notifyPlaylistComplete ?? true else { return }
        await send(id: "playlist-\(batch.id)", title: batch.state == .completed && batch.packageErrorMessage == nil
                   ? "Playlist complete" : "Playlist finished with issues", body: String(batch.title.prefix(160)))
    }

    func notifyUpdate(version: String) async {
        await send(id: "extractor-update-\(version)", title: "Extractor update available",
                   body: "Open Illucet Settings to review the available update.")
    }

    func send(id: String, title: String, body: String, jobID: UUID? = nil, requestID: UUID? = nil) async {
        await deliver(.init(id: id, title: title, body: body, jobID: jobID, requestID: requestID))
    }

    private static func systemSend(_ message: JobNotificationMessage) async {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = .default
        if let jobID = message.jobID { content.userInfo = ["job_id": jobID.uuidString] }
        if let requestID = message.requestID { content.userInfo["request_id"] = requestID.uuidString }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: message.id, content: content, trigger: nil))
    }
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    /// Return the presentation time only for a completion routed to the app.
    func routeCompletion(job: DownloadJob, notifyWhenBackgrounded: Bool) async -> Date? {
        if let time = await foregroundCompletionTime() { return time }
        if notifyWhenBackgrounded {
            await send(id: "complete-\(job.id)", title: "Download complete",
                       body: String(job.title.prefix(160)), jobID: job.id)
        }
        return nil
    }

    func notifyFailure(job: DownloadJob) async {
        await send(id: "failed-\(job.id)", title: "Download failed",
                   body: "Open Illucet to review this download: " + String(job.title.prefix(160)), jobID: job.id)
    }
}
