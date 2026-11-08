import Foundation

/// Portable preferences only. Device credentials, bookmarks and media state
/// deliberately have no fields in this document.
struct PreferencesBackup: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumBytes = 1_048_576
    let format: String
    let version: Int
    var settings: AppSettings
    var presets: [QuickStartPreset]

    init(settings: AppSettings, presets: [QuickStartPreset]) {
        format = "Illucet.preferences"
        version = Self.currentVersion
        self.settings = settings
        self.settings.clipboard?.explained = false
        self.presets = presets.map(Self.portablePreset)
    }

    func encoded() throws -> Data {
        let data = try JSONEncoder.illucetEncoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw BackupError.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == "Illucet.preferences",
              let version = object["version"] as? Int else { throw BackupError.invalidFile }
        guard version == currentVersion else { throw BackupError.unsupportedVersion }
        guard let stored = object["settings"] as? [String: Any] else { throw BackupError.invalidFile }
        // New settings receive their defaults when an older backup omits them.
        let defaultsData = try JSONEncoder.illucetEncoder.encode(AppSettings.defaults)
        guard var defaults = try JSONSerialization.jsonObject(with: defaultsData) as? [String: Any]
        else { throw BackupError.invalidFile }
        defaults.merge(stored) { _, saved in saved }
        object["settings"] = defaults
        var backup = try JSONDecoder.illucetDecoder.decode(Self.self, from: JSONSerialization.data(withJSONObject: object))
        try backup.validate()
        backup.settings = OutputCapabilityMatrix.normalized(backup.settings)
        backup.presets = QuickStartPresetLibrary.normalized(backup.presets.map(portablePreset))
        QuickStartPresetLibrary.migrateLaunchBehavior(settings: &backup.settings, presets: &backup.presets)
        if let preferred = backup.settings.shortcuts?.preferredPresetID,
           !backup.presets.contains(where: { $0.id == preferred }) {
            backup.settings.shortcuts?.preferredPresetID = nil
        }
        if let preferred = backup.settings.sharedLinks?.preferredPresetID,
           !backup.presets.contains(where: { $0.id == preferred }) {
            backup.settings.sharedLinks?.preferredPresetID = nil
        }
        return backup
    }

    private static func portablePreset(_ preset: QuickStartPreset) -> QuickStartPreset {
        var result = preset
        result.configuration.accountID = nil
        return result
    }

    private func validate() throws {
        guard settings.accentColor?.isValid ?? true,
              (1...4).contains(settings.maximumSimultaneousDownloads),
              (1...2).contains(settings.maximumSimultaneousProcessingJobs),
              (0...8).contains(settings.automaticRetryCount),
              (1...90).contains(settings.autoCleanupDays),
              settings.minimumFreeSpaceReserveBytes >= 0,
              settings.largeDownloadWarningBytes >= 0,
              settings.downloadSpeedLimitBytesPerSecond.map({ $0 > 0 }) ?? true,
              settings.maximumResolution.map({ $0 > 0 }) ?? true,
              settings.filenameTemplate.utf8.count <= 4_096,
              presets.count <= 24,
              Set(presets.map(\.id)).count == presets.count else { throw BackupError.invalidValues }
        for preset in presets {
            let config = preset.configuration
            guard !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  preset.name.count <= 48,
                  config.filenameTemplate.utf8.count <= 4_096,
                  config.maximumPlaylistItems > 0,
                  config.maximumResolution.map({ $0 > 0 }) ?? true,
                  config.speedLimitBytesPerSecond.map({ $0 > 0 }) ?? true,
                  config.trimStartSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  config.trimEndSeconds.map({ $0.isFinite && $0 > (config.trimStartSeconds ?? 0) }) ?? true
            else { throw BackupError.invalidValues }
        }
    }

    enum BackupError: LocalizedError {
        case invalidFile, unsupportedVersion, tooLarge, invalidValues
        var errorDescription: String? {
            switch self {
            case .invalidFile: "Choose a Illucet preferences backup."
            case .unsupportedVersion: "This backup needs a newer version of Illucet."
            case .tooLarge: "The preferences file exceeds the 1 MB limit."
            case .invalidValues: "The backup contains invalid preferences. Nothing was imported."
            }
        }
    }
}
