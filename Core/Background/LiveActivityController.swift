import ActivityKit
import UIKit

/// One focused job avoids exhausting the system activity budget for playlists.
actor LiveActivityController {
    private var lastUpdate = Date.distantPast
    private var lastState: DownloadActivityAttributes.ContentState?
    private var lastJobID: UUID?
    private var terminalDismissals: [String: Task<Void, Never>] = [:]

    private var synchronizing = false
    private var pending: (jobs: [DownloadJob], enabled: Bool, intentStart: Bool)?

    func synchronize(jobs: [DownloadJob], enabled: Bool, intentStart: Bool = false) async {
        pending = (jobs, enabled, intentStart || pending?.intentStart == true)
        guard !synchronizing else { return }
        synchronizing = true
        defer { synchronizing = false }
        while let request = pending {
            pending = nil
            await apply(jobs: request.jobs, enabled: request.enabled, intentStart: request.intentStart)
        }
    }

    private func apply(jobs: [DownloadJob], enabled: Bool, intentStart: Bool) async {
        let job = enabled ? Self.focusedJob(in: jobs) : nil
        let activities = Activity<DownloadActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
        for activity in activities where activity.attributes.jobID != job?.id {
            let old = jobs.first { $0.id == activity.attributes.jobID }
            let state = old.map(Self.state) ?? .init(stage: "No active job", terminal: true)
            if enabled, job == nil, old?.state.isTerminal == true {
                // Keep the actual result in the Island briefly, then leave the
                // final result on the Lock Screen. Never leave a failed job at 0%.
                guard terminalDismissals[activity.id] == nil else { continue }
                await activity.update(ActivityContent(state: state, staleDate: nil))
                let activityID = activity.id
                terminalDismissals[activityID] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(state.phase == .failed ? 60 : 15)) }
                    catch { return }
                    await self?.dismissTerminal(activityID: activityID, state: state)
                }
            } else {
                terminalDismissals.removeValue(forKey: activity.id)?.cancel()
                await activity.end(ActivityContent(state: state, staleDate: nil),
                    dismissalPolicy: old?.state.isTerminal == true ? .after(.now.addingTimeInterval(120)) : .immediate)
            }
        }
        guard let job else { lastState = nil; return }
        let state = Self.state(job)
        let content = ActivityContent(state: state, staleDate: job.state == .running ? Date.now.addingTimeInterval(30) : nil)
        if let activity = activities.first(where: { $0.attributes.jobID == job.id }) {
            terminalDismissals.removeValue(forKey: activity.id)?.cancel()
            guard lastJobID != job.id || lastState?.stage != state.stage || lastState?.phase != state.phase
                    || Date.now.timeIntervalSince(lastUpdate) >= 1 else { return }
            await activity.update(content)
        } else {
            let foreground = await MainActor.run { UIApplication.shared.applicationState == .active }
            guard ActivityAuthorizationInfo().areActivitiesEnabled, intentStart || foreground else { return }
            do {
                _ = try Activity.request(attributes: DownloadActivityAttributes(jobID: job.id,
                    title: String(job.title.prefix(96))), content: content, pushType: nil)
            } catch { return } // iOS may deny a request; downloads keep their real state.
        }
        lastState = state
        lastJobID = job.id
        lastUpdate = .now
    }

    private func dismissTerminal(activityID: String, state: DownloadActivityAttributes.ContentState) async {
        guard terminalDismissals.removeValue(forKey: activityID) != nil,
              let activity = Activity<DownloadActivityAttributes>.activities.first(where: { $0.id == activityID }) else { return }
        await activity.end(ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .after(.now.addingTimeInterval(120)))
    }

    func hasActivity(jobID: UUID) -> Bool {
        Activity<DownloadActivityAttributes>.activities.contains {
            $0.attributes.jobID == jobID && ($0.activityState == .active || $0.activityState == .stale)
        }
    }

    static func focusedJob(in jobs: [DownloadJob]) -> DownloadJob? {
        jobs.filter { !$0.state.isTerminal }.sorted {
            let left = $0.state == .running ? 0 : $0.resumesOnForeground || $0.state == .needsAttention ? 1 : 2
            let right = $1.state == .running ? 0 : $1.resumesOnForeground || $1.state == .needsAttention ? 1 : 2
            return left == right ? $0.createdAt < $1.createdAt : left < right
        }.first
    }

    static func state(_ job: DownloadJob) -> DownloadActivityAttributes.ContentState {
        let value = JobStatusPresentation(job: job)
        let phase: DownloadActivityAttributes.Phase
        if job.resumesOnForeground { phase = .needsAttention }
        else {
            switch job.state {
            case .failed: phase = .failed
            case .completed: phase = .completed
            case .cancelled: phase = .cancelled
            case .needsAttention, .waitingForCellularApproval: phase = .needsAttention
            case .paused: phase = .paused
            case .running:
                phase = job.stage.presentsTransferMetrics ? .downloading
                    : job.stage.isProcessingWork ? .processing
                    : [.analyzing, .preparing].contains(job.stage) ? .preparing : .waiting
            default: phase = .waiting
            }
        }
        return .init(stage: value.stage, fraction: value.fraction, speed: value.speed,
                     remaining: value.remaining, terminal: job.state.isTerminal, updatedAt: .now, phase: phase)
    }
}
