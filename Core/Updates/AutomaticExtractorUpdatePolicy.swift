import Foundation

enum AutomaticExtractorUpdatePolicy {
    static func isDue(enabled: Bool, status: UpdateStatus, channel: UpdateChannel, now: Date) -> Bool {
        guard enabled, ![.checking, .installing, .testing, .staged].contains(status.state) else { return false }
        guard status.lastCheckedChannel == channel, let last = status.lastCheckedAt else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed < 0 || elapsed >= 86_400
    }
}
