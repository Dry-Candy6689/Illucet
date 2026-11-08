import Foundation

/// Uses monotonic time only. Callers reset the observation whenever eligibility
/// is lost, so pause, connectivity loss and background time are never charged.
struct TransferLivenessPolicy: Sendable {
    let idleTimeout: Double = 90
    let acknowledgementTimeout: Double = 15
    let maximumRecoveries: Int = 2

    func isStalled(lastActivity: Double, now: Double, pacingDeadline: Double?,
                   availabilityDeadline: Double? = nil) -> Bool {
        guard now.isFinite, lastActivity.isFinite else { return false }
        let baseline = [lastActivity, pacingDeadline, availabilityDeadline]
            .compactMap { $0 }.filter(\.isFinite).max() ?? lastActivity
        return now - baseline >= idleTimeout
    }
}
