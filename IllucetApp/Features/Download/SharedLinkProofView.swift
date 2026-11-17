#if DEBUG
import SwiftUI
import UIKit

/// Supplies a test link to the system share sheet and checks the saved-link inbox.
struct SharedLinkProofView: View {
    @State private var sharing = false
    @State private var status = ""
    @State private var priorIDs: Set<UUID> = []
    @State private var priorJobIDs: Set<UUID> = []
    private var mixed: Bool { ProcessInfo.processInfo.arguments.contains("--shared-mixed-proof") }
    private var expectedURLs: [URL] {
        mixed ? [DeveloperFixtures.RickURL,
            URL(string: "https://www.instagram.com/p/SamplePost/")!,
            URL(string: "https://www.tiktok.com/@sample/video/123456")!] : [DeveloperFixtures.RickURL]
    }
    var body: some View {
        VStack(spacing: 24) {
            Button("Share test link") {
                Task {
                    priorIDs = Set((try? SharedLinkInbox.live().pending())?.map(\.id) ?? [])
                    priorJobIDs = Set(await IllucetApplicationServices.model.coordinator.currentJobs().map(\.id))
                    sharing = true
                }
            }.accessibilityIdentifier("shareProof.present")
            Button("Read saved test link") {
                do {
                    let inbox = try SharedLinkInbox.live()
                    let links = try inbox.pending().filter { !priorIDs.contains($0.id) && $0.url.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ" }
                    status = links.isEmpty ? "No test link saved" : "Shared link delivered"
                    // Explicit proof screen only removes the exact fixture it just verified.
                    for link in links { try inbox.remove(link.id) }
                } catch { status = "Shared storage unavailable" }
            }.accessibilityIdentifier("shareProof.read")
            Button("Check test download") {
                Task {
                    let jobs = await IllucetApplicationServices.model.coordinator.currentJobs()
                    let added = jobs.filter { !priorJobIDs.contains($0.id) && expectedURLs.contains($0.sourceURL) }
                    if mixed, added.count == expectedURLs.count,
                       added.allSatisfy({ $0.state == .waitingForPower }),
                       (!ProcessInfo.processInfo.arguments.contains("--shared-aria2-proof")
                        || added.allSatisfy({ $0.configuration.enginePreferences?.download == .aria2 })),
                       Set(added.map(\.sourceURL)).count == expectedURLs.count,
                       added.contains(where: { $0.configuration.sourceIdentity?.kind == .image }),
                       added.contains(where: { $0.configuration.sourceIdentity?.kind == .video || $0.configuration.sourceIdentity == nil }) {
                        status = "Mixed shared downloads queued: \(added.count)"
                    } else if !mixed, jobs.contains(where: { !priorJobIDs.contains($0.id)
                        && $0.sourceURL == DeveloperFixtures.RickURL && $0.state == .waitingForPower }) {
                        status = "Shared download queued"
                    } else { status = "Waiting for shared download" }
                }
            }.accessibilityIdentifier("shareProof.checkDownload")
            Text(status).accessibilityIdentifier("shareProof.status")
        }
        .sheet(isPresented: $sharing) { SharedLinkProofSheet(text: expectedURLs.map(\.absoluteString).joined(separator: "\n")) }
    }
}
private struct SharedLinkProofSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
