import Foundation

/// yt-dlp's absolute, per-format not-before time. It is independent of URL
/// expiry and never changes the selected source, quality or retry budget.
enum MediaAvailability {
    static let maximumWait: TimeInterval = 600

    static func date(timestamp: Double?, now: Date = .now) throws -> Date? {
        guard let timestamp else { return nil }
        guard timestamp.isFinite, timestamp >= 0,
              timestamp <= now.timeIntervalSince1970 + maximumWait else {
            throw InvalidDeadline()
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    static func validated(_ deadline: Date?, now: Date = .now) throws -> Date? {
        _ = try date(timestamp: deadline?.timeIntervalSince1970, now: now)
        return deadline
    }

    /// Foreground requests and manifest validation need a cancellable native
    /// wait. Background download tasks use URLSessionTask.earliestBeginDate.
    static func waitUntilReady(_ deadline: Date?) async throws {
        let deadline = try validated(deadline)
        try Task.checkCancellation()
        let remaining = deadline?.timeIntervalSinceNow ?? 0
        if remaining > 0 {
            try await Task.sleep(for: .seconds(remaining))
        }
        try Task.checkCancellation()
    }

    static func monotonicDeadline(_ deadline: Date?, wallNow: Date, now: Double) -> Double? {
        guard let deadline = try? validated(deadline, now: wallNow), now.isFinite else { return nil }
        return now + deadline.timeIntervalSince(wallNow)
    }

    struct InvalidDeadline: Error {}
}
