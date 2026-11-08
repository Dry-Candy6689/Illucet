import AppIntents
import Foundation

/// Runs in the foreground app. The durable inbox also covers cold launch before
/// the SwiftUI model has completed restoring saved state.
struct OpenSharedLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Open shared link"
    static let description = IntentDescription("Open a YouTube link in Illucet using your sharing preferences.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Link") var link: URL

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let safe = SharedLinkParser.canonicalURL(link) else {
            throw SharedLinkIntentError.unsupported
        }
        try SharedLinkInbox.live().save(safe)
        NotificationCenter.default.post(name: .illucetSharedLinkReceived, object: nil)
        return .result()
    }
}

enum SharedLinkIntentError: Error, LocalizedError {
    case unsupported
    var errorDescription: String? { "Choose a supported YouTube video, playlist, or creator link." }
}

extension Notification.Name {
    static let illucetSharedLinkReceived = Notification.Name("IllucetSharedLinkReceived")
}
