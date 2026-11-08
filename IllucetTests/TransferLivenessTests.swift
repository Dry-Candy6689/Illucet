import Foundation
import Testing
@testable import Illucet

struct TransferLivenessTests {
    @Test
    func availabilityWaitDoesNotConsumeTheStallBudget() {
        let wall = Date(timeIntervalSince1970: 1_800_000_000)
        let deadline = wall.addingTimeInterval(40)
        let first = MediaAvailability.monotonicDeadline(deadline, wallNow: wall, now: 100)
        #expect(first == 140)
        let later = MediaAvailability.monotonicDeadline(deadline,
            wallNow: wall.addingTimeInterval(50), now: 150)
        #expect(later == 140) // The deadline is absolute, not a fresh delay each poll.
        let policy = TransferLivenessPolicy()
        #expect(!policy.isStalled(lastActivity: 100, now: 229,
                                 pacingDeadline: nil, availabilityDeadline: later))
        #expect(policy.isStalled(lastActivity: 100, now: 230,
                                pacingDeadline: nil, availabilityDeadline: later))
        #expect(MediaAvailability.monotonicDeadline(wall.addingTimeInterval(601), wallNow: wall, now: 100) == nil)
    }
    @Test
    func deadlineCountsOnlyEligibleTimePastIntentionalPacing() {
        let policy = TransferLivenessPolicy()
        #expect(!policy.isStalled(lastActivity: 10, now: 99, pacingDeadline: nil))
        #expect(policy.isStalled(lastActivity: 10, now: 100, pacingDeadline: nil))
        #expect(!policy.isStalled(lastActivity: 10, now: 1000, pacingDeadline: 1001))
        #expect(!policy.isStalled(lastActivity: 10, now: 1089, pacingDeadline: 1000))
        #expect(policy.isStalled(lastActivity: 10, now: 1090, pacingDeadline: 1000))
        #expect(!policy.isStalled(lastActivity: 1090, now: 1100, pacingDeadline: nil))
        #expect(!policy.isStalled(lastActivity: .nan, now: 100, pacingDeadline: nil))
    }
}
