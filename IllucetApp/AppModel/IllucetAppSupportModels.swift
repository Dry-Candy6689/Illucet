import Foundation

enum IllucetStartupState: Equatable {
    case loading
    case blocked(PersistenceError)
    case ready

    var blocksInteraction: Bool { self != .ready }

    var recoveryError: PersistenceError? {
        if case .blocked(let error) = self { return error }
        return nil
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case download = "Download"
    case queue = "Queue"
    case history = "History"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .download: "arrow.down.circle"
        case .queue: "list.bullet.rectangle"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

enum DownloadFocusTarget: String, Hashable, Sendable {
    case top
    case mediaLink
    case quickStart
}

enum FilesFolderPickerSource: Hashable, Sendable {
    case settings
    case configuration
    case confirmation
    case quickStart
    case playlist
}

enum FilesFolderAliasEditorMode: Hashable, Sendable {
    case offer
    case edit
}

struct QuickStartInputRecoveryState: Equatable, Sendable {
    private(set) var pendingPreset: QuickStartPreset?
    private(set) var showsGuidance = false
    private(set) var offersClipboardContinuation = false

    var isActive: Bool {
        pendingPreset != nil
    }

    static func requiresRecovery(for URLText: String) -> Bool {
        URLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func probableSupportedURLText(
        from clipboardText: String?
    ) -> String? {
        guard let clipboardText else { return nil }
        let value = clipboardText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty,
              let URL = Foundation.URL(string: value),
              (try? YouTubeURLIntentClassifier.classify(URL)) != nil
        else {
            return nil
        }
        return value
    }

    mutating func begin(
        preset: QuickStartPreset,
        readClipboardText: () -> String?
    ) {
        pendingPreset = preset
        showsGuidance = true
        offersClipboardContinuation = Self.probableSupportedURLText(
            from: readClipboardText()
        ) != nil
    }

    mutating func URLTextDidChange(
        from previousValue: String,
        to currentValue: String
    ) {
        guard isActive, previousValue != currentValue else { return }
        let wasEmpty = Self.requiresRecovery(for: previousValue)
        let isEmpty = Self.requiresRecovery(for: currentValue)
        if !wasEmpty, isEmpty {
            cancel()
        } else if !isEmpty {
            showsGuidance = false
            offersClipboardContinuation = false
        }
    }

    mutating func hideGuidance() {
        showsGuidance = false
    }

    mutating func declineClipboardContinuation() {
        offersClipboardContinuation = false
    }

    mutating func acceptClipboardContinuation(
        readClipboardText: () -> String?
    ) -> (URLText: String, preset: QuickStartPreset)? {
        guard offersClipboardContinuation,
              let pendingPreset
        else {
            return nil
        }
        guard let URLText = Self.probableSupportedURLText(
            from: readClipboardText()
        ) else {
            offersClipboardContinuation = false
            return nil
        }
        cancel()
        return (URLText, pendingPreset)
    }

    mutating func analysisDidBegin() -> QuickStartPreset? {
        let preset = pendingPreset
        cancel()
        return preset
    }

    mutating func cancel() {
        pendingPreset = nil
        showsGuidance = false
        offersClipboardContinuation = false
    }
}

enum SponsorBlockPreviewState: Equatable, Sendable {
    case idle
    case loading
    case empty
    case loaded(count: Int)
    case failed(SponsorBlockServiceError)
}

enum SponsorBlockReviewWaitingReason: Equatable, Sendable {
    case analyzedMedia
    case preview

    var message: String {
        switch self {
        case .analyzedMedia:
            "Analyze the media before reviewing SponsorBlock segments."
        case .preview:
            "Wait for SponsorBlock segment discovery to finish."
        }
    }
}

enum SponsorBlockReviewBlocker: Equatable, Sendable {
    case preview(SponsorBlockServiceError)
    case planning(SponsorBlockPlanningError)

    var message: String {
        switch self {
        case let .preview(error):
            error.localizedDescription
        case let .planning(error):
            error.localizedDescription
        }
    }
}

enum SponsorBlockReviewState: Equatable, Sendable {
    case ready
    case waiting(SponsorBlockReviewWaitingReason)
    case blocked(SponsorBlockReviewBlocker)

    var unavailableReason: String? {
        switch self {
        case .ready:
            nil
        case let .waiting(reason):
            reason.message
        case let .blocked(blocker):
            blocker.message
        }
    }

    static func resolve(
        policy: SponsorBlockPolicy,
        previewState: SponsorBlockPreviewState,
        metadata: MediaMetadata?,
        configuration: DownloadConfiguration
    ) -> Self {
        guard configuration.hasMediaTimeline, policy.needsSegmentReview else { return .ready }
        switch previewState {
        case .empty, .loaded:
            guard let metadata else {
                return .waiting(.analyzedMedia)
            }
            do {
                let plan = try SponsorBlockPlanner.makePlan(
                    policy: policy,
                    videoID: metadata.videoID,
                    analyzedDuration: metadata.durationSeconds
                )
                if plan.entries.contains(where: { $0.action == .remove }) {
                    guard let outputPlan = try? OutputCapabilityMatrix.makePlan(
                        configuration: configuration,
                        metadata: metadata
                    ) else {
                        return .blocked(
                            .planning(.unsupportedExecutionPath)
                        )
                    }
                    try SponsorBlockExecutionSupport.validate(
                        plan: plan,
                        policy: policy,
                        configuration: configuration,
                        outputPlan: outputPlan
                    )
                }
                return .ready
            } catch let error as SponsorBlockPlanningError {
                return .blocked(.planning(error))
            } catch {
                return .blocked(.planning(.previewRequired))
            }
        case let .failed(error):
            if policy.lookupUnavailable, !policy.requiresRemoval {
                return .ready
            }
            if policy.lookupUnavailable {
                return .blocked(.planning(.requiredLookupUnavailable))
            }
            return .blocked(.preview(error))
        case .idle:
            return .waiting(.analyzedMedia)
        case .loading:
            return .waiting(.preview)
        }
    }
}

struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

    static func error(_ error: any Error) -> Self {
        Self(
            title: "Couldn’t complete that",
            message: error.localizedDescription
        )
    }
}
