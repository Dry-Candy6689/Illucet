import Foundation

enum PipFrequency: String, Codable, CaseIterable, Identifiable, Sendable {
    // Keep existing backup values while giving the choices useful UI names.
    case occasional = "medium", downloadUpdates = "often"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .occasional: "Occasional tips"
        case .downloadUpdates: "Tips & download updates"
        }
    }
}

struct PipPreferences: Codable, Equatable, Sendable {
    var enabled = true
    var frequency: PipFrequency = .occasional

    init(enabled: Bool = true, frequency: PipFrequency = .occasional) {
        self.enabled = enabled
        self.frequency = frequency
    }

    private enum CodingKeys: String, CodingKey { case enabled, frequency }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let stored = try values.decodeIfPresent(String.self, forKey: .frequency) ?? "medium"
        if stored == "never" {
            enabled = false
            frequency = .occasional
        } else if let selected = PipFrequency(rawValue: stored) {
            frequency = selected
        } else {
            throw DecodingError.dataCorruptedError(forKey: .frequency, in: values,
                debugDescription: "Unknown PiP activity preference.")
        }
    }
}

extension DownloadExperiencePreferences {
    var pipScreenSkippingSuggestion: String? {
        switch (skipVideoDetails, skipDownloadReview) {
        case (true, true): nil
        case (false, true): "Want fewer steps next time? Turn on Skip video details in Shortcuts settings to go straight past the video details. Tiny paws approve."
        case (true, false): "Want fewer steps next time? Turn on Skip download review in Shortcuts settings to go straight to downloading. Tiny paws approve."
        case (false, false): "Want fewer steps next time? In Shortcuts settings, Skip video details and Skip download review let you get straight to downloading. Tiny paws approve."
        }
    }
}

extension AppSettings {
    var pipPreferences: PipPreferences {
        get { pip ?? .init() }
        set { pip = newValue }
    }
}

struct PipLocalState: Codable, Equatable, Sendable {
    var disableAppealShown = false
    // Optional additions preserve state written by the first PiP release.
    var disableConfirmed: Bool? = nil
    var analyzedFirstVideo: Bool? = nil
    var startedFirstDownload: Bool? = nil
    var downloadScreensHintShown: Bool? = nil
    var queueSelectionHintShown: Bool? = nil
    var historySelectionHintShown: Bool? = nil
    var notificationHintShown: Bool? = nil
    var guideFinishedAt: Date?
    var lastSessionAt: Date?
    var sessionsSinceHint = 0
    var lastHintAt: Date?
    var recentHints: [String: Date] = [:]

    mutating func beginSession(at now: Date) {
        guard lastSessionAt.map({ now.timeIntervalSince($0) >= 1_800 }) ?? true else { return }
        lastSessionAt = now
        sessionsSinceHint += 1
    }

    func allowsHint(_ frequency: PipFrequency, at now: Date, sessionCount: Int) -> Bool {
        guard guideFinishedAt != nil else { return false }
        switch frequency {
        case .occasional:
            return sessionsSinceHint >= 3
                && now.timeIntervalSince(lastHintAt ?? guideFinishedAt ?? now) >= 3 * 86_400
        case .downloadUpdates:
            return sessionCount < 2
                && now.timeIntervalSince(lastHintAt ?? guideFinishedAt ?? now) >= 900
        }
    }

    mutating func recordHint(_ id: String, at now: Date) {
        recentHints = recentHints.filter { now.timeIntervalSince($0.value) < 30 * 86_400 }
        recentHints[id] = now
        lastHintAt = now
        sessionsSinceHint = 0
    }
}

enum PipAnchor: String, Hashable, Sendable {
    case link, presets, customPresets, notifications, appearanceRow, colors, settings
    case settingsTab, homeQuickStartRow, notificationsRow, pipRow

    var isSettingsRow: Bool {
        switch self {
        case .homeQuickStartRow, .notificationsRow, .appearanceRow, .pipRow: true
        default: false
        }
    }
}

enum PipGuideStep: Int, CaseIterable, Sendable {
    case welcome, link, presets, customPresets, notifications, appearanceRow, colors, settings, finish

    var anchor: PipAnchor? {
        switch self {
        case .welcome, .finish: nil
        case .link: .link
        case .presets: .presets
        case .customPresets: .customPresets
        case .notifications: .notifications
        case .appearanceRow: .appearanceRow
        case .colors: .colors
        case .settings: .settings
        }
    }

    var text: String {
        switch self {
        case .welcome: "Hi! Welcome to Illucet. I’m PiP. Tiny paws, quick tour."
        case .link: "Paste a video link here. This is where your next download begins."
        case .presets: "Quick Start remembers your favorite download settings. Pick a preset and you’re on your way."
        case .customPresets: "Make your own presets here. Each preset can download immediately or show a quick confirmation. Required approvals still come first."
        case .notifications: "Want a heads-up when downloads finish or need attention? You can enable notifications here."
        case .appearanceRow: "Now, a little style. Interface is right here in Settings."
        case .colors: "Make Illucet feel like yours: choose an accent, a theme, or a deep-black background. Excellent taste, by the way."
        case .settings: "Here’s my little corner. Choose how often I visit, turn me off, or replay this guide whenever you like."
        case .finish: "All set! Back to downloads. I’ll stay out of your whiskers."
        }
    }
}

struct PipHint: Identifiable, Sendable {
    let id: String
    let text: String
    // Authored locally; no network requests or download details are needed.
    static let library: [Self] = [
        "Quick Start presets can remember your favorite quality and destination.",
        "Make a preset for music and another for video. Tiny shortcuts, big convenience.",
        "You can reorder your presets in Home Quick Start.",
        "Duplicate a preset when you only want to change one thing.",
        "Each preset can skip its quick confirmation. Required approvals still apply.",
        "Download defaults are your starting point; presets can have their own settings.",
        "Choose a Files folder if you want downloads somewhere specific.",
        "Photos is an option for compatible videos. Choose it as your destination.",
        "History keeps completed downloads easy to find.",
        "A history entry can show the files created by a download.",
        "You can share a saved file from its details page.",
        "A preset name like ‘Music for walks’ is easier to remember than a list of codecs.",
        "Wi-Fi only can hold new downloads until the right connection is available.",
        "Cellular approval is separate from one-tap presets. Your data plan gets a say.",
        "The queue shows downloads waiting for a connection or another requirement.",
        "Processing can continue after the media transfer finishes. Watch the stage label.",
        "Unknown download size means there may be no trustworthy percentage yet.",
        "A paused download is different from one waiting for a connection.",
        "Prioritize changes which waiting work gets the next available slot.",
        "Cancel is there when a download is no longer the one you want.",
        "Notification settings let you choose which events deserve a heads-up.",
        "Live Activities can keep useful progress close while you use another app.",
        "iOS decides background execution time. A download may need the app open again.",
        "Force-quitting can interrupt background work. Leave Illucet in the app switcher.",
        "A ‘needs attention’ message means there’s a choice to make in the app.",
        "Shortcuts has its own download preferences in Settings.",
        "Shared links that need a choice can wait safely for your next visit.",
        "The Share Sheet shortcut is called Download with Illucet.",
        "Automatic clipboard checks are optional in App opening & clipboard.",
        "You can paste a link yourself whenever you prefer.",
        "Save a preferences backup before experimenting with lots of settings.",
        "Preferences backups include presets, but not accounts or media files.",
        "An accent color is waiting in Interface. I’m partial to anything snack-colored.",
        "The black background option lives in Interface.",
        "Download cards have a compact layout option in Interface.",
        "System appearance follows your iPhone’s light and dark setting.",
        "Occasional tips keeps my visits rare. Tiny paws, small interruptions.",
        "Turn Show PiP off to keep me quiet. You can still replay the guide yourself.",
        "Replay Guide is always in Settings → PiP.",
        "Storage settings can clean inactive temporary download files.",
        "Deleting activity logs clears logs; saved media has its own cleanup action.",
        "Files saved outside the app stay in their chosen destination.",
        "Extractor updates are managed in yt-dlp & EJS settings.",
        "An extractor update and an app update are different things.",
        "Stream copy can avoid re-encoding when the selected output allows it.",
        "Apple-compatible output is a useful starting point for playback on your devices.",
        "Small output presets trade some detail for a smaller file.",
        "The quality strategy and output format both affect what can be saved.",
        "Whisker inspection complete. Everything appears delightfully rectangular.",
        "I have reviewed the buttons. They are, without exception, buttons.",
        "Tiny paws. Extremely serious download supervision.",
        "I brought no snacks. This was a planning error.",
        "My ears are optimized for silent conversations.",
        "If you need me, I’ll be over here looking professionally fluffy.",
        "A good preset is like a well-packed snack bag: ready when you need it.",
        "I considered a dramatic entrance. This small box seemed more practical.",
        "No audio commentary. Just premium chinchilla subtitles.",
        "Today’s ambitious agenda: blink, help a little, blink again.",
        "That accent color? A distinguished choice for a distinguished rectangle.",
        "I’m not judging your download names. I can barely reach the keyboard.",
        "Current status: compact, fluffy, available for light supervision.",
        "One tap at a time. That is also how I type with these paws.",
        "I have excellent taste in corners. This is a very good corner.",
        "You handle the downloads. I’ll handle the occasional encouraging expression."
    ].enumerated().map { .init(id: "hint-\($0.offset)", text: $0.element) }
}
