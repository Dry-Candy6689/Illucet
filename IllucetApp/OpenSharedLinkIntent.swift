import AppIntents
import Foundation

/// Runs in the foreground app. The durable inbox also covers cold launch before
/// the SwiftUI model has completed restoring saved state.
struct OpenSharedLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Open shared link"
    static let description = IntentDescription("Open a media link in Illucet using your sharing preferences.")
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
    case unsupported, missingInput
    var errorDescription: String? {
        switch self {
        case .unsupported: "Choose a supported media link."
        case .missingInput: "The shortcut did not provide any links. Get the current Illucet shortcut in Settings → Sharing & Shortcuts."
        }
    }
}

extension Notification.Name {
    static let illucetSharedLinkReceived = Notification.Name("IllucetSharedLinkReceived")
}
