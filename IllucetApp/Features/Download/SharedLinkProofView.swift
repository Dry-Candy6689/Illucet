#if DEBUG
import SwiftUI
import UIKit

/// Exercises the installed extension in the system share sheet without a network request.
struct SharedLinkProofView: View {
    @State private var sharing = false
    @State private var status = ""
    @State private var priorIDs: Set<UUID> = []
    var body: some View {
        VStack(spacing: 24) {
            Button("Share test link") {
                priorIDs = Set((try? SharedLinkInbox.live().pending())?.map(\.id) ?? [])
                sharing = true
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
            Text(status).accessibilityIdentifier("shareProof.status")
        }
        .sheet(isPresented: $sharing) { SharedLinkProofSheet() }
    }
}
private struct SharedLinkProofSheet: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: ["A shared video https://youtu.be/dQw4w9WgXcQ?si=fixture"], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
