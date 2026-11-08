import UIKit

extension IllucetAppModel {
    /// Returns an exception for this job only; background intents use normal
    /// queue admission. Present from the visible controller, including reviews.
    func approveTransferAdmission(excluding id: UUID? = nil) async throws -> Bool {
        var status = await coordinator.transferAdmissionStatus(excluding: id)
        if fixtureMode && ProcessInfo.processInfo.arguments.contains("--ui-screen=transfer-limit") {
            status = (jobs.filter { $0.id != id && TransferAdmissionPolicy.requestsTransfer($0) }.count, settings.maximumSimultaneousDownloads)
        }
        guard status.count >= status.limit, UIApplication.shared.applicationState == .active else { return false }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        guard var presenter = window?.rootViewController else { return false }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !presenter.isBeingDismissed else { return false }
        return try await withCheckedThrowingContinuation { continuation in
            let alert = UIAlertController(title: "Download limit reached",
                message: "\(status.count) downloads are active or waiting to transfer. Your limit is \(status.limit). Start this download anyway?",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Queue", style: .default) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "Start anyway", style: .default) { _ in continuation.resume(returning: true) })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(throwing: CancellationError()) })
            presenter.present(alert, animated: true)
        }
    }
}
