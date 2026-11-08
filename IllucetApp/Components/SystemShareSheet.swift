import SwiftUI
import UIKit

struct SystemShareSheet: UIViewControllerRepresentable {
    let request: SharePresentationRequest
    let completion: @MainActor (ShareCompletionState, String?) -> Void
    var fileAccess: SavedOutputAccessSession? = nil

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: request.fileURLs,
            applicationActivities: nil
        )
        let fileAccess = fileAccess
        controller.completionWithItemsHandler = {
            _, completed, _, error in
            let state: ShareCompletionState = error != nil ? .failed : completed ? .completed : .cancelled
            let detail = error?.localizedDescription
            withExtendedLifetime(fileAccess) { request.outcome.recordUIKit(state, error: detail) }
            Task { @MainActor in completion(state, detail) }
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
