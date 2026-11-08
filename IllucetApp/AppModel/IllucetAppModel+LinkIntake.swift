import Foundation
import UIKit

/// Pattern detection does not read clipboard contents or trigger a paste banner.
/// Injected operations keep activation races and read counts testable.
@MainActor
struct ClipboardAccess {
    var changeCount: () -> Int
    var containsURL: () async throws -> Bool
    var readText: () -> String?
    var isActive: () -> Bool

    static var live: Self {
        Self(
            changeCount: { UIPasteboard.general.changeCount },
            containsURL: {
                try await UIPasteboard.general.detectedPatterns(for: [\.probableWebURL])
                    .contains(\.probableWebURL)
            },
            readText: { UIPasteboard.general.string ?? UIPasteboard.general.url?.absoluteString },
            isActive: { UIApplication.shared.applicationState == .active }
        )
    }
}

extension IllucetAppModel {
    var presentsPastePermissionTip: Bool {
        pendingPastePermissionTip && selectedTab == .download && canAcceptClipboardLink
            && !presentsOnboarding && alert == nil
    }

    func editURLField(_ value: String) {
        let previous = URLText
        URLText = value
        // Native edit-menu paste inserts multiple characters in one edit.
        // Typing and deletion do not consume the first-paste tip.
        guard firstRunState.pastePermissionTipShown != true,
              LinkIntakePolicy.supportedURL(value) != nil else { return }
        let prefix = zip(previous, value).prefix(while: { $0 == $1 }).count
        let oldTail = previous.dropFirst(prefix)
        let newTail = value.dropFirst(prefix)
        let suffix = zip(oldTail.reversed(), newTail.reversed()).prefix(while: { $0 == $1 }).count
        if newTail.count - suffix > 1 { recordPastedLink(value) }
    }

    func recordPastedLink(_ text: String) {
        guard firstRunState.pastePermissionTipShown != true,
              LinkIntakePolicy.supportedURL(text) != nil else { return }
        pendingPastePermissionTip = true
    }

    func pastePermissionTipDidAppear() {
        guard firstRunState.pastePermissionTipShown != true else { return }
        firstRunState.pastePermissionTipShown = true
        scheduleSave()
    }

    func dismissPastePermissionTip() {
        pastePermissionTipDidAppear()
        pendingPastePermissionTip = false
    }

    var canAcceptClipboardLink: Bool {
        !startupState.blocksInteraction && canPresentShortcutOptions
            && !replaysPipGuide && pipGuideStep == nil && pendingSharedLink == nil
            && shortcutHandoff == nil && !isStartingDownload && !isStartingQuickStart
            && !quickStartInputRecovery.offersClipboardContinuation
    }

    func checkClipboardOnActivation(changeCount: Int? = nil, access: ClipboardAccess? = nil) async {
        let preferences = settings.clipboard ?? ClipboardPreferences()
        guard preferences.checksAutomatically, canAcceptClipboardLink,
              preferences.permitsApplyingLink(to: URLText) else { return }
        let clipboard = access ?? (fixtureMode ? ClipboardAccess(
            changeCount: { changeCount ?? 0 },
            containsURL: { true },
            readText: { self.readClipboardText() },
            isActive: { true }
        ) : .live)
        guard clipboard.isActive() else { return }
        let change = changeCount ?? clipboard.changeCount()
        guard change != lastAutomaticClipboardChange else { return }
        let draftRevision = clipboardDraftRevision
        // Deduplicate before suspension, including reactivation by a paste prompt.
        lastAutomaticClipboardChange = change
        clipboardSuggestion = nil
        let containsURL = try? await clipboard.containsURL()
        func stillCurrent() -> Bool {
            !Task.isCancelled && clipboard.isActive() && clipboard.changeCount() == change
                && lastAutomaticClipboardChange == change && clipboardDraftRevision == draftRevision
                && settings.clipboard == preferences && canAcceptClipboardLink
        }
        guard stillCurrent() else {
            if lastAutomaticClipboardChange == change { lastAutomaticClipboardChange = nil }
            return
        }
        guard containsURL == true, let url = LinkIntakePolicy.supportedURL(clipboard.readText()),
              stillCurrent(), !LinkIntakePolicy.identifiesSameLink(URLText, url.absoluteString) else { return }
        switch preferences.behavior {
        case .suggest: clipboardSuggestion = url
        case .fill:
            URLText = url.absoluteString
            recordPastedLink(URLText)
        case .analyze:
            URLText = url.absoluteString
            recordPastedLink(URLText)
            analyze()
        }
    }

    func acceptClipboardSuggestion() {
        let suggestion = clipboardSuggestion
        clipboardSuggestion = nil
        guard canAcceptClipboardLink, let suggestion, let preferences = settings.clipboard,
              preferences.checksAutomatically, preferences.behavior == .suggest,
              preferences.permitsApplyingLink(to: URLText) else { return }
        URLText = suggestion.absoluteString
        recordPastedLink(URLText)
    }
}


extension IllucetAppModel {
    func refreshSharedLinks(inbox: SharedLinkInbox? = nil) {
        guard !fixtureMode || inbox != nil else { return }
        let store: SharedLinkInbox
        do {
            store = try inbox ?? SharedLinkInbox.live()
            sharedLinkInbox = try store.pending()
        }
        catch { return }
        guard !startupState.blocksInteraction, !presentsOnboarding, !isAnalyzing,
              pendingSharedLink == nil, !presentsMetadata, !presentsConfiguration,
              !presentsPlaylistBatch, !presentsConfirmation, !presentsQuickStartConfirmation,
              let first = sharedLinkInbox.first(where: { $0.presentedAt == nil && $0.isShortcutRequest != true }),
              URLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        openSavedSharedLink(first, inbox: store)
    }

    func openSavedSharedLink(_ link: SharedLink, inbox: SharedLinkInbox? = nil) {
        if link.isShortcutRequest == true {
            Task { await continueShortcutInApp(link) }
            return
        }
        do {
            let store = try inbox ?? SharedLinkInbox.live()
            try store.markPresented(link.id)
            sharedLinkInbox = try store.pending()
        } catch {
            alert = AppAlert(title: "Couldn’t open saved link", message: "The link remains saved. Try again.")
            return
        }
        receiveSharedLink(link.url)
        // Retain the durable inbox item until the user explicitly removes it;
        // a crash or cancelled analysis must not lose a shared URL.
    }
    func removeSavedSharedLink(_ link: SharedLink) {
        do {
            try SharedLinkInbox.live().remove(link.id)
            sharedLinkInbox.removeAll { $0.id == link.id }
        } catch { alert = AppAlert(title: "Couldn’t remove link", message: "The saved link remains available. Try again.") }
    }
    func receiveSharedLink(_ url: URL) {
        guard let safe = SharedLinkParser.canonicalURL(url),
              (try? YouTubeURLIntentClassifier.classify(safe)) != nil else { return }
        if pendingSharedLink != nil || presentsMetadata || presentsConfiguration || presentsPlaylistBatch || presentsConfirmation || presentsQuickStartConfirmation {
            do {
                try SharedLinkInbox.live().save(safe)
                sharedLinkInbox = try SharedLinkInbox.live().pending()
            } catch { alert = AppAlert(title: "Finish the current link first", message: "The new link could not be saved. Share it again after finishing the current decision.") }
            return
        }
        pendingSharedLink = safe
        selectedTab = .download
        clipboardSuggestion = nil
        let preferences = settings.sharedLinks ?? SharedLinkPreferences()
        // Preserve an existing draft and stop automatic replacement or analysis.
        if isAnalyzing || (!URLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && URLText != safe.absoluteString) {
            presentsSharedLinkChoice = true
            return
        }
        applySharedLinkBehavior(preferences.behavior)
    }
    func applySharedLinkBehavior(_ behavior: SharedLinkBehavior, rememberChoice: Bool = false) {
        guard let url = pendingSharedLink, !startupState.blocksInteraction, !isAnalyzing else { return }
        if behavior == .ask { presentsSharedLinkChoice = true; return }
        if rememberChoice {
            var preferences = settings.sharedLinks ?? SharedLinkPreferences()
            preferences.behavior = behavior
            settings.sharedLinks = preferences
            scheduleSave()
        }
        presentsSharedLinkChoice = false
        pendingSharedLink = nil
        cancelQuickStartInputRecovery()
        URLText = url.absoluteString
        opensFullOptionsAfterAnalysis = behavior == .options || behavior == .presetConfirmation || behavior == .presetImmediate
        if behavior == .fill { return }
        analysisUsesSharedRouting = true
        if behavior == .options, activeShortcutRequest?.url == url,
           let preset = quickStartPresets.first(where: { $0.id == settings.shortcutPreferences.preferredPresetID }) {
            startQuickStart(preset)
            return
        }
        if behavior == .presetConfirmation || behavior == .presetImmediate,
           var preset = quickStartPresets.first(where: { $0.id == settings.sharedLinks?.preferredPresetID }) {
            preset.launchBehavior = behavior == .presetImmediate ? .immediate : .confirmation
            startQuickStart(preset)
        } else { analyze() }
    }
}
