import Foundation

struct FirstRunState: Codable, Equatable, Sendable {
    var pip: PipLocalState? = nil
    var migratedNightlyUpdateDefault: Bool? = nil
    var pastePermissionTipShown: Bool? = nil
    private(set) var onboardingCompleted: Bool
    private(set) var notificationPromptOffered: Bool
    private(set) var completedAt: Date?

    static let initial = Self(
        onboardingCompleted: false,
        notificationPromptOffered: false,
        completedAt: nil
    )

    var shouldPresentOnboarding: Bool {
        !onboardingCompleted
    }

    mutating func beginNotificationRequest() {
        notificationPromptOffered = true
    }

    mutating func complete(at date: Date = .now) {
        onboardingCompleted = true
        completedAt = date
    }

    mutating func completeWithoutNotifications(at date: Date = .now) {
        notificationPromptOffered = true
        complete(at: date)
    }
}
