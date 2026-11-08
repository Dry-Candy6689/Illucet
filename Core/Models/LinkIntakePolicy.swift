import Foundation

enum ClipboardBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case suggest = "Suggest URL only"
    case fill = "Fill URL automatically"
    case analyze = "Fill and analyze automatically"
    var id: String { rawValue }
}

struct ClipboardPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var checkAtStartup = false
    var explained = false
    var behavior: ClipboardBehavior = .suggest
    var replaceExistingURL: Bool? = nil

    var checksAutomatically: Bool { enabled && explained && checkAtStartup }
    var replacesExistingURL: Bool {
        get { replaceExistingURL ?? true }
        set { replaceExistingURL = newValue }
    }

    func permitsApplyingLink(to draft: String) -> Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (replacesExistingURL && LinkIntakePolicy.supportedURL(draft) != nil)
    }
}

enum LinkIntakePolicy {
    static func identifiesSameLink(_ first: String, _ second: String) -> Bool {
        guard let firstURL = URL(string: first.trimmingCharacters(in: .whitespacesAndNewlines)),
              let secondURL = URL(string: second.trimmingCharacters(in: .whitespacesAndNewlines)),
              let firstIntent = try? YouTubeURLIntentClassifier.classify(firstURL),
              let secondIntent = try? YouTubeURLIntentClassifier.classify(secondURL) else { return false }
        return firstIntent == secondIntent
    }

    static func clipboardURL(_ text: String?, currentInput: String) -> URL? {
        guard currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return supportedURL(text)
    }

    static func supportedURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              (try? YouTubeURLIntentClassifier.classify(url)) != nil else { return nil }
        return url
    }
}

enum SharedLinkBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask = "Ask every time"
    case fill = "Open Home with URL filled"
    case analyze = "Analyze immediately"
    case options = "Open full download options"
    case presetConfirmation = "Preferred preset with confirmation"
    case presetImmediate = "Start preferred preset immediately"
    var id: String { rawValue }
}
struct SharedLinkPreferences: Codable, Equatable, Sendable {
    var behavior: SharedLinkBehavior = .ask
    var preferredPresetID: UUID?
}

enum ShortcutBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case download = "Download immediately"
    case options = "Show download options"
    case ask = "Ask every time"
    var id: String { rawValue }
}

struct ShortcutPreferences: Codable, Equatable, Sendable {
    var behavior: ShortcutBehavior = .download
    var preferredPresetID: UUID?
    var backgroundFirst = true

    static func migrating(_ old: SharedLinkPreferences?) -> Self {
        guard let old else { return Self() }
        let behavior: ShortcutBehavior = switch old.behavior {
        case .ask: .ask
        case .presetImmediate: .download
        case .fill, .analyze, .options, .presetConfirmation: .options
        }
        return Self(behavior: behavior, preferredPresetID: old.preferredPresetID)
    }
}

extension AppSettings {
    var shortcutPreferences: ShortcutPreferences {
        get { shortcuts ?? .migrating(sharedLinks) }
        set { shortcuts = newValue }
    }
}
