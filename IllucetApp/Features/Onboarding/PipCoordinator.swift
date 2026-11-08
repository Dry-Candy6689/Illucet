import SwiftUI
import UIKit

@MainActor
final class PipCoordinator: ObservableObject {
    let id = UUID()
    @Published private(set) var step: PipGuideStep?
    @Published private(set) var text = ""
    @Published private(set) var visibleCharacters = 0
    @Published private(set) var expression = 0
    @Published private(set) var isLeaving = false
    @Published private(set) var exitCoverOpacity: Double = 0
    @Published private(set) var bubbleVisible = false
    @Published private(set) var interrupted = false
    @Published private(set) var showsDownloadSettingsButton = false
    @Published private(set) var showsNotificationSettingsButton = false
    @Published private(set) var navigationCue: String?
    var reduceMotion = false
    private weak var model: IllucetAppModel?
    private var typingTask: Task<Void, Never>?
    private var interruptionTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    private var selectionHintTask: Task<Void, Never>?
    private var guideRouteTask: Task<Void, Never>?
    private var guideExitTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var activeSince: Date?
    private var seenCompletions = Set<UUID>()
    private var pendingCompletions = 0
    private var keyboardVisible = false
    private var active = false
    private var fastText = false
    private var lastPoke: Date?
    private var pokeCount = 0
    private var pokeCooldown = Date.distantPast
    private var lastEvent = Date.distantPast
    private var lastBubbleAt = Date.distantPast
    private var idleSince = Date.now
    private var previousJobs: [UUID: DownloadJobState]?
    private var sessionHints = 0
    private var selectionHintTab: AppTab?

    var isGuiding: Bool { step != nil }
    var finishedTyping: Bool { visibleCharacters >= text.count }
    var displayedText: String { String(text.prefix(visibleCharacters)) }

    func attach(_ model: IllucetAppModel, active: Bool, fastText: Bool, reduceMotion: Bool = false) {
        self.model = model
        self.fastText = fastText
        self.reduceMotion = reduceMotion
        setActive(active)
        observeJobs()
        if model.presentsOnboarding || model.replaysPipGuide { startGuide() }
    }

    func setActive(_ value: Bool) {
        if value && !active { activeSince = .now }
        active = value
        hintTask?.cancel()
        if !value {
            activeSince = nil
            cancelSelectionHint()
            guideRouteTask?.cancel()
            completionTask?.cancel()
            completionTask = nil
            pendingCompletions = 0
            finishExitIfInterrupted()
            typingTask?.cancel()
            interruptionTask?.cancel()
            if interrupted { interrupted = false; setPassage(step?.text ?? "") }
            dismissBubble()
            return
        }
        guard let model else { return }
        var local = model.firstRunState.pip ?? .init()
        let oldSession = local.lastSessionAt
        local.beginSession(at: .now)
        if oldSession != local.lastSessionAt { sessionHints = 0 }
        model.firstRunState.pip = local
        model.scheduleSave()
        if navigationCue != nil, let step { move(to: step) }
        else { resumeTyping() }
        receiveDownloadCompletions()
        scheduleSelectionHint()
        hintTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                self.offerHint()
            }
        }
    }

    func startGuide() {
        guard let model, !isGuiding, !isLeaving, model.pipGuideOwner == nil || model.pipGuideOwner == id else { return }
        guard !model.isAnalyzing, !model.presentsConfiguration, !model.presentsConfirmation,
              !model.presentsMetadata, !model.presentsQuickStartConfirmation,
              !model.presentsPlaylistBatch, model.shortcutHandoff == nil else {
            model.replaysPipGuide = false
            return
        }
        model.pipGuideOwner = id
        cancelSelectionHint()
        dismissBubble()
        isLeaving = false
        exitCoverOpacity = 0
        move(to: .welcome)
    }

    func advance() {
        guard !isLeaving, !interrupted, navigationCue == nil, let step else { return }
        if step == .finish {
            visibleCharacters = text.count
            leaveGuide(skipped: false)
        } else if !finishedTyping {
            typingTask?.cancel()
            visibleCharacters = text.count
        } else if let next = PipGuideStep(rawValue: step.rawValue + 1) {
            move(to: next)
        } else { leaveGuide(skipped: false) }
    }

    private func move(to step: PipGuideStep) {
        guard let model else { return }
        self.step = step
        model.pipGuideStep = step
        expression = step == .finish ? 6 : 0
        switch step {
        case .welcome, .link, .presets:
            model.settingsNavigationPath = []
            model.selectedTab = .download
        case .customPresets:
            navigate(for: step, through: .homeQuickStartRow, title: "Home Quick Start", to: .homeQuickStart)
            return
        case .notifications:
            navigate(for: step, through: .notificationsRow, title: "Notifications & Live Activities", to: .notifications)
            return
        case .appearanceRow:
            navigate(for: step, through: .appearanceRow, title: "Interface", to: nil)
            return
        case .colors:
            navigate(for: step, through: .appearanceRow, title: "Interface", to: .appearance, rowAlreadyShown: true)
            return
        case .settings:
            navigate(for: step, through: .pipRow, title: "PiP", to: .pip)
            return
        case .finish:
            break // The final tap performs the fade and page change together.
        }
        setPassage(step.text)
    }

    private func navigate(
        for step: PipGuideStep, through row: PipAnchor, title: String,
        to destination: SettingsDestination?, rowAlreadyShown: Bool = false
    ) {
        guard let model else { return }
        typingTask?.cancel()
        guideRouteTask?.cancel()
        navigationCue = "Settings → \(title)"
        model.pipNavigationAnchor = model.selectedTab == .settings ? nil : .settingsTab
        guard active else { return }
        guideRouteTask = Task { [weak self, weak model] in
            guard let self, let model else { return }
            let animation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.25)
            do {
                if model.selectedTab != .settings {
                    try await Task.sleep(for: .milliseconds(650))
                    withAnimation(animation) {
                        model.settingsNavigationPath = []
                        model.selectedTab = .settings
                    }
                    try await Task.sleep(for: .milliseconds(300))
                } else if !model.settingsNavigationPath.isEmpty {
                    withAnimation(animation) { model.settingsNavigationPath = [] }
                    try await Task.sleep(for: .milliseconds(350))
                }
                model.pipNavigationAnchor = row
                if !rowAlreadyShown { try await Task.sleep(for: .milliseconds(800)) }
                if let destination {
                    withAnimation(animation) { model.settingsNavigationPath = [destination] }
                    model.pipNavigationAnchor = nil
                    try await Task.sleep(for: .milliseconds(350))
                }
                try Task.checkCancellation()
                model.pipNavigationAnchor = nil
                navigationCue = nil
                setPassage(step.text)
                guideRouteTask = nil
            } catch { return }
        }
    }

    func leaveGuide(skipped: Bool) {
        guard !isLeaving, isGuiding, model != nil else { return }
        guideRouteTask?.cancel()
        guideRouteTask = nil
        navigationCue = nil
        typingTask?.cancel()
        interruptionTask?.cancel()
        interrupted = false
        expression = skipped ? 8 : 6
        // Fade the old page out first; route changes are made while it is invisible.
        withAnimation(.easeOut(duration: 0.18)) {
            isLeaving = true
            exitCoverOpacity = 1
        }
        guideExitTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.returnToDownloads()
            // Let Download lay out and consume the scroll-to-top request before
            // revealing it. The cover has a stable lifetime outside preferences.
            await Task.yield()
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.22)) { self.exitCoverOpacity = 0 }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled else { return }
            self.isLeaving = false
            self.completeGuide()
            self.guideExitTask = nil
            self.model?.presentDeferredShortcutHandoff()
        }
    }

    private func returnToDownloads() {
        guard let model else { return }
        model.selectedTab = .download
        model.settingsNavigationPath = []
        model.pipGuideStep = nil
        model.pipNavigationAnchor = nil
        model.tabScrollStates[.download]?.scrollToTop(animated: false)
        step = nil
    }

    private func completeGuide() {
        guard let model else { return }
        if model.presentsOnboarding { model.firstRunState.completeWithoutNotifications() }
        var local = model.firstRunState.pip ?? .init()
        local.guideFinishedAt = .now
        model.firstRunState.pip = local
        model.replaysPipGuide = false
        model.presentsOnboarding = false
        model.pipGuideOwner = nil
        model.scheduleSave()
    }

    private func finishExitIfInterrupted() {
        guard isLeaving else { return }
        guideExitTask?.cancel()
        guideExitTask = nil
        returnToDownloads()
        completeGuide()
        exitCoverOpacity = 0
        isLeaving = false
    }

    func poke() {
        guard isGuiding, !isLeaving, navigationCue == nil, Date.now >= pokeCooldown else { return }
        let now = Date.now
        pokeCount = lastPoke.map { now.timeIntervalSince($0) <= 3 ? pokeCount + 1 : 1 } ?? 1
        lastPoke = now
        typingTask?.cancel()
        interruptionTask?.cancel()
        interrupted = true
        expression = pokeCount == 1 ? 9 : 10
        let savedText = step?.text ?? text
        let savedPosition = min(visibleCharacters, savedText.count)
        if pokeCount >= 3 {
            text = "Hey! Stop that. Important chinchilla business."
            visibleCharacters = text.count
            pokeCooldown = now.addingTimeInterval(10)
            pokeCount = 0
        }
        interruptionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_000))
            guard !Task.isCancelled, let self else { return }
            self.interrupted = false
            self.expression = 0
            self.text = savedText
            self.visibleCharacters = savedPosition
            self.resumeTyping()
        }
    }

    func activityChanged() { idleSince = .now }

    func keyboardChanged(_ visible: Bool) {
        keyboardVisible = visible
        activityChanged()
        if visible { dismissBubble() }
    }

    func detach() {
        setActive(false)
        finishExitIfInterrupted()
        if model?.pipGuideOwner == id {
            model?.pipGuideOwner = nil
            model?.pipGuideStep = nil
            model?.pipNavigationAnchor = nil
        }
    }

    private var canOfferBubble: Bool {
        guard active, let model else { return false }
        return model.settings.pipPreferences.enabled && !isGuiding && !isLeaving && !keyboardVisible
            && !model.replaysPipGuide && model.canPresentShortcutOptions
            && !model.presentsPastePermissionTip
            && model.shortcutHandoff == nil
            && UIApplication.shared.applicationState == .active
    }

    private func offerHint() {
        if offerDownloadScreensHint() { return }
        if scheduleSelectionHint() { return }
        if Date.now.timeIntervalSince(idleSince) >= 8,
           Date.now.timeIntervalSince(lastBubbleAt) >= 45,
           Date.now.timeIntervalSince(model?.firstRunState.pip?.guideFinishedAt ?? .distantPast) >= 60,
           offerNotificationHint() { return }
        guard canOfferBubble, !bubbleVisible, Date.now.timeIntervalSince(idleSince) >= 8,
              let model, let local = model.firstRunState.pip,
              local.allowsHint(model.settings.pipPreferences.frequency, at: .now, sessionCount: sessionHints),
              let hint = PipHint.library.first(where: { local.recentHints[$0.id].map { Date.now.timeIntervalSince($0) >= 30 * 86_400 } ?? true }) else { return }
        var updated = local
        updated.recordHint(hint.id, at: .now)
        model.firstRunState.pip = updated
        model.scheduleSave()
        sessionHints += 1
        showBubble(hint.text, expression: 0)
    }

    func observeJobs() {
        guard let model else { return }
        let current = Dictionary(uniqueKeysWithValues: model.jobs.map { ($0.id, $0.state) })
        defer { previousJobs = current }
        if previousJobs != nil, model.jobs.contains(where: { previousJobs?[$0.id] == nil }) {
            var local = model.firstRunState.pip ?? .init()
            local.startedFirstDownload = true
            model.firstRunState.pip = local
            model.scheduleSave()
            if offerDownloadScreensHint() { return }
        }
        guard let previousJobs, canOfferBubble, !bubbleVisible,
              model.settings.pipPreferences.frequency == .downloadUpdates,
              Date.now.timeIntervalSince(lastEvent) >= 30 else { return }
        let changed = model.jobs.filter { previousJobs[$0.id] != $0.state }
        if changed.contains(where: { $0.state == .failed || $0.state == .needsAttention }) {
            showBubble("A download needs attention. The queue can show you what happened.", expression: 9)
        } else if changed.contains(where: { $0.state == .running }) {
            showBubble("Your download is underway. I’ll supervise from this excellent corner.", expression: 0)
        } else { return }
        lastEvent = .now
    }

    func receiveDownloadCompletions() {
        guard let model, let activeSince, !model.foregroundDownloadCompletions.isEmpty else { return }
        let events = model.foregroundDownloadCompletions
        model.foregroundDownloadCompletions.removeAll()
        guard canOfferBubble, model.settings.pipPreferences.frequency == .downloadUpdates else { return }
        for (jobID, time) in events where time >= activeSince {
            if seenCompletions.insert(jobID).inserted { pendingCompletions += 1 }
        }
        guard pendingCompletions > 0, completionTask == nil else { return }
        completionTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            completionTask = nil
            let count = pendingCompletions
            pendingCompletions = 0
            guard canOfferBubble, self.model?.settings.pipPreferences.frequency == .downloadUpdates else { return }
            showBubble(count == 1 ? "Download finished! Nicely done." : "\(count) downloads finished! Nicely done.", expression: 6)
        }
    }

    private func showBubble(_ text: String, expression: Int) {
        selectionHintTab = nil
        showsDownloadSettingsButton = false
        showsNotificationSettingsButton = false
        lastBubbleAt = .now
        self.expression = expression
        bubbleVisible = true
        setPassage(text)
    }

    func pageChanged() {
        activityChanged()
        cancelSelectionHint()
        if let selectionHintTab, selectionHintTab != model?.selectedTab { dismissBubble() }
        scheduleSelectionHint()
    }

    @discardableResult
    private func scheduleSelectionHint() -> Bool {
        guard canOfferBubble, !bubbleVisible, let model else { return false }
        let tab = model.selectedTab
        let local = model.firstRunState.pip
        switch tab {
        case .queue where local?.queueSelectionHintShown != true && !model.queueSelection.isActive: break
        case .history where local?.historySelectionHintShown != true && !model.historySelection.isActive: break
        default: return false
        }
        if selectionHintTask == nil {
            selectionHintTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                selectionHintTask = nil
                guard self.model?.selectedTab == tab else { return }
                showSelectionHint()
            }
        }
        return true
    }

    private func cancelSelectionHint() {
        selectionHintTask?.cancel()
        selectionHintTask = nil
    }

    private func showSelectionHint() {
        guard canOfferBubble, !bubbleVisible, let model else { return }
        var local = model.firstRunState.pip ?? .init()
        let message: String
        switch model.selectedTab {
        case .queue where local.queueSelectionHintShown != true:
            guard !model.queueSelection.isActive else { return }
            message = model.jobs.isEmpty && model.batches.isEmpty
                ? "When downloads appear here, hold a finished, failed or cancelled item to select it. Then choose more, or Select all."
                : "Hold a finished, failed or cancelled download to select items. Active downloads stay safe. Tiny paws, tidy queue."
            local.queueSelectionHintShown = true
        case .history where local.historySelectionHintShown != true:
            guard !model.historySelection.isActive else { return }
            message = model.history.isEmpty
                ? "When your history fills up, hold an entry to select it. Then choose more, or Select all."
                : "Hold a history entry to select it. Then choose more, or Select all. A little cleanup, chinchilla style."
            local.historySelectionHintShown = true
        default: return
        }
        model.firstRunState.pip = local
        model.scheduleSave()
        showBubble(message, expression: 0)
        selectionHintTab = model.selectedTab
    }

    @discardableResult
    func offerDownloadScreensHint() -> Bool {
        guard canOfferBubble, !bubbleVisible, let model,
              var local = model.firstRunState.pip,
              local.analyzedFirstVideo == true, local.startedFirstDownload == true,
              local.downloadScreensHintShown != true else { return false }
        local.downloadScreensHintShown = true
        model.firstRunState.pip = local
        model.scheduleSave()
        guard let suggestion = model.settings.experience.pipScreenSkippingSuggestion else { return false }
        showBubble(suggestion, expression: 0)
        showsDownloadSettingsButton = true
        return true
    }

    func showDownloadScreenSettings() {
        guard let model else { return }
        dismissBubble()
        model.selectedTab = .settings
        model.settingsNavigationPath = [.links]
        model.highlightsDownloadScreens = true
    }

    @discardableResult
    func offerNotificationHint() -> Bool {
        guard canOfferBubble, !bubbleVisible, let model,
              var local = model.firstRunState.pip,
              local.startedFirstDownload == true, local.notificationHintShown != true,
              !model.settings.hasNotificationEventsEnabled || model.notificationsAuthorized == false else { return false }
        local.notificationHintShown = true
        model.firstRunState.pip = local
        model.scheduleSave()
        showBubble("Want a heads-up when a download finishes while you’re away? You can turn on notifications in Settings. I’ll keep watch in here.", expression: 0)
        showsNotificationSettingsButton = true
        return true
    }

    func showNotificationSettings() {
        guard let model else { return }
        dismissBubble()
        model.selectedTab = .settings
        model.settingsNavigationPath = [.notifications]
    }

    func dismissBubble() {
        guard !isGuiding else { return }
        bubbleVisible = false
        selectionHintTab = nil
        showsDownloadSettingsButton = false
        showsNotificationSettingsButton = false
        typingTask?.cancel()
    }

    func preferencesChanged() {
        guard let prefs = model?.settings.pipPreferences else { return }
        if !prefs.enabled { cancelSelectionHint() }
        if !prefs.enabled || (showsDownloadSettingsButton && model?.settings.experience.pipScreenSkippingSuggestion == nil)
            || (showsNotificationSettingsButton && model?.settings.hasNotificationEventsEnabled == true
                && model?.notificationsAuthorized != false) {
            dismissBubble()
        }
    }

    private func setPassage(_ text: String) {
        typingTask?.cancel()
        self.text = text
        visibleCharacters = 0
        resumeTyping()
        if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .announcement, argument: text) }
    }

    private func resumeTyping() {
        guard active else { return }
        typingTask?.cancel()
        if fastText || UIAccessibility.isVoiceOverRunning { visibleCharacters = text.count }
        typingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.visibleCharacters < self.text.count {
                try? await Task.sleep(for: .milliseconds(22))
                guard !Task.isCancelled else { return }
                self.visibleCharacters += 1
            }
            guard !Task.isCancelled, self.bubbleVisible, !UIAccessibility.isVoiceOverRunning else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self.bubbleVisible = false
            self.showsDownloadSettingsButton = false
            self.selectionHintTab = nil
            self.scheduleSelectionHint()
        }
    }
}
