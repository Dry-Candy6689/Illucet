import Foundation

@MainActor
final class BackgroundSessionEventBroker {
    static let shared = BackgroundSessionEventBroker()

    private var completions: [String: [UUID: () -> Void]] = [:]
    private var earlyFinishes: [String: [Date]] = [:]
    private let earlyFinishLifetime: TimeInterval = 60

    private init() {}

    func register(
        sessionIdentifier: String,
        completion: @escaping () -> Void
    ) {
        pruneEarlyFinishes()
        if var finishes = earlyFinishes[sessionIdentifier],
           !finishes.isEmpty {
            finishes.removeFirst()
            earlyFinishes[sessionIdentifier] = finishes.isEmpty
                ? nil
                : finishes
            completion()
            return
        }
        completions[sessionIdentifier, default: [:]][UUID()] = completion
    }

    @discardableResult
    func finishEvents(
        sessionIdentifier: String
    ) -> Int {
        let pending = completions.removeValue(
            forKey: sessionIdentifier
        ) ?? [:]
        guard !pending.isEmpty else {
            pruneEarlyFinishes()
            earlyFinishes[sessionIdentifier, default: []].append(.now)
            return 0
        }
        for completion in pending.values {
            completion()
        }
        return pending.count
    }

    func pendingCompletionCount(
        sessionIdentifier: String
    ) -> Int {
        completions[sessionIdentifier]?.count ?? 0
    }

    func pendingEarlyFinishCount(
        sessionIdentifier: String
    ) -> Int {
        pruneEarlyFinishes()
        return earlyFinishes[sessionIdentifier]?.count ?? 0
    }

    private func pruneEarlyFinishes() {
        let cutoff = Date.now.addingTimeInterval(-earlyFinishLifetime)
        earlyFinishes = earlyFinishes.compactMapValues { dates in
            let retained = dates.filter { $0 >= cutoff }
            return retained.isEmpty ? nil : retained
        }
    }
}
