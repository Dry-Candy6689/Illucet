import Foundation
import Testing
import UIKit
@testable import Illucet

struct FirstLaunchTests {
    @Test
    func newInstallPresentsOnboarding() {
        let state = FirstRunState.initial

        #expect(state.shouldPresentOnboarding)
        #expect(!state.onboardingCompleted)
        #expect(!state.notificationPromptOffered)
        #expect(state.completedAt == nil)
    }

    @Test
    func beginningNotificationRequestIsOneWayAndIdempotent() {
        var state = FirstRunState.initial

        state.beginNotificationRequest()
        state.beginNotificationRequest()

        #expect(state.notificationPromptOffered)
        #expect(state.shouldPresentOnboarding)
        #expect(!state.onboardingCompleted)
    }

    @Test
    func finishingAfterNotificationDecisionDoesNotRequestAgain() {
        var state = FirstRunState.initial
        let completionDate = Date(timeIntervalSince1970: 1_234_567)

        state.beginNotificationRequest()
        state.complete(at: completionDate)

        #expect(state.notificationPromptOffered)
        #expect(state.onboardingCompleted)
        #expect(!state.shouldPresentOnboarding)
        #expect(state.completedAt == completionDate)
    }

    @Test
    func skipRecordsBothOnboardingAndNotificationDecision() {
        var state = FirstRunState.initial
        let completionDate = Date(timeIntervalSince1970: 2_345_678)

        state.completeWithoutNotifications(at: completionDate)

        #expect(state.notificationPromptOffered)
        #expect(state.onboardingCompleted)
        #expect(!state.shouldPresentOnboarding)
        #expect(state.completedAt == completionDate)
    }

    @Test
    func schemaTwoSnapshotDefaultsToUnfinishedFirstRun() throws {
        let encoded = try JSONEncoder.illucetEncoder.encode(IllucetSnapshot.empty)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object.removeValue(forKey: "firstRunState")
        object["schemaVersion"] = 2
        let legacy = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        let decoded = try JSONDecoder.illucetDecoder.decode(
            IllucetSnapshot.self,
            from: legacy
        )

        #expect(decoded.firstRunState == .initial)
        #expect(decoded.firstRunState.shouldPresentOnboarding)
    }

    @Test
    func completedFirstRunRoundTripsThroughPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part5-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IllucetPersistence(rootURL: root)
        var snapshot = IllucetSnapshot.empty
        let completionDate = Date(timeIntervalSince1970: 3_456_789)
        snapshot.firstRunState.completeWithoutNotifications(
            at: completionDate
        )

        try await persistence.save(snapshot)
        let reloaded = try await IllucetPersistence(rootURL: root).load()

        #expect(reloaded.schemaVersion == IllucetSnapshot.currentSchemaVersion)
        #expect(reloaded.firstRunState.onboardingCompleted)
        #expect(reloaded.firstRunState.notificationPromptOffered)
        #expect(reloaded.firstRunState.completedAt == completionDate)
    }

    @Test @MainActor
    func compiledLaunchIdentityIsAvailable() throws {
        let launchScreen = try #require(
            Bundle.main.object(
                forInfoDictionaryKey: "UILaunchScreen"
            ) as? [String: Any]
        )

        #expect(
            launchScreen["UIImageName"] as? String
                == "IllucetLaunchBrand"
        )
        #expect(
            launchScreen["UIColorName"] as? String
                == "LaunchBackground"
        )
        #expect(UIImage(named: "IllucetLaunchBrand") != nil)
    }
}
