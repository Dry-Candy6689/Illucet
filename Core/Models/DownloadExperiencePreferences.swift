import Foundation

struct DownloadExperiencePreferences: Codable, Equatable, Sendable {
    var skipVideoDetails = false
    var skipDownloadReview = false
    var instantQuickStart = false
}

extension AppSettings {
    var experience: DownloadExperiencePreferences {
        get { downloadExperience ?? .init() }
        set { downloadExperience = newValue }
    }
}
