#if DEBUG
import ActivityKit
import SwiftUI

/// Explicit simulator/device UI proof. No extraction, network or saved jobs.
struct LiveActivityProofView: View {
    @State private var controller = LiveActivityController()
    @State private var job = DeveloperFixtures.failedThumbnailOnlyJob
    @State private var status = "Not started"
    var body: some View {
        VStack(spacing: 24) {
            Text("Live Activity system proof")
            Text(status).accessibilityIdentifier("activityProof.status")
            Button("Start fixture") {
                job.title = "Illucet progress test"
                job.state = .running; job.stage = .downloadingVideo
                job.progress.totalBytes = 1000; job.progress.bytesDownloaded = 400
                job.progress.sampleCount = 4; job.progress.smoothedBytesPerSecond = 100
                job.progress.downloadETASeconds = 6
                Task {
                    await controller.synchronize(jobs: [job], enabled: true)
                    status = Activity<DownloadActivityAttributes>.activities.contains { $0.attributes.jobID == job.id }
                        ? "System activity started" : "System did not allow an activity"
                }
            }.accessibilityIdentifier("activityProof.start")
            Button("Show processing") {
                job.stage = .converting; job.progress.processingFraction = 0.3
                job.progress.processingETASeconds = nil
                Task {
                    await controller.synchronize(jobs: [job], enabled: true)
                    // ActivityKit publishes content asynchronously after accepting update().
                    for _ in 0..<50 {
                        if Activity<DownloadActivityAttributes>.activities.first(where: { $0.attributes.jobID == job.id })?.content.state.stage == "Converting" {
                            status = "System activity updated"
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    status = "System update unavailable"
                }
            }.accessibilityIdentifier("activityProof.processing")
            Button("Needs opening") {
                job.state = .needsAttention; job.foregroundResumeReason = .processingTime
                Task { await updateStatus("System activity needs opening", expected: .needsAttention) }
            }.accessibilityIdentifier("activityProof.handoff")
            Button("Fail fixture") {
                job.state = .failed; job.foregroundResumeReason = nil
                Task { await updateStatus("System activity failed", expected: .failed) }
            }.accessibilityIdentifier("activityProof.failed")
            Button("End fixture") {
                Task {
                    await controller.synchronize(jobs: [], enabled: false)
                    status = Activity<DownloadActivityAttributes>.activities.allSatisfy { $0.activityState == .ended || $0.activityState == .dismissed }
                        ? "System activity ended" : "System activity still present"
                }
            }.accessibilityIdentifier("activityProof.end")
        }.padding()
    }

    private func updateStatus(_ message: String, expected: DownloadActivityAttributes.Phase) async {
        await controller.synchronize(jobs: [job], enabled: true)
        for _ in 0..<50 {
            if Activity<DownloadActivityAttributes>.activities.first(where: { $0.attributes.jobID == job.id })?.content.state.phase == expected {
                status = message
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        status = "System update unavailable"
    }
}
#endif
