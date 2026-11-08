import Foundation

/// UIKit records its result synchronously, before any dispatch to the main actor.
/// Dismissal can publish an unconfirmed result, but cannot consume a later UIKit result.
final class ShareOutcomeArbiter: @unchecked Sendable, Equatable {
    struct Outcome: Equatable, Sendable {
        let state: ShareCompletionState
        let error: String?
    }
    private let lock = NSLock()
    private var result: Outcome?
    private var resultTaken = false
    private var dismissalTaken = false

    static func == (lhs: ShareOutcomeArbiter, rhs: ShareOutcomeArbiter) -> Bool { lhs === rhs }

    func recordUIKit(_ state: ShareCompletionState, error: String?) {
        lock.withLock {
            guard result == nil, state != .pending, state != .unconfirmed else { return }
            result = Outcome(state: state, error: error.map { DiagnosticRedactor.redact(String($0.prefix(256))) })
        }
    }

    func take(dismissing: Bool = false) -> Outcome? {
        lock.withLock {
            if let result {
                guard !resultTaken else { return nil }
                resultTaken = true
                return result
            }
            guard dismissing, !dismissalTaken else { return nil }
            dismissalTaken = true
            return Outcome(state: .unconfirmed, error: nil)
        }
    }
}
