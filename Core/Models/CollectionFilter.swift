import Foundation

struct CollectionFilter: Equatable, Sendable {
    enum Requirement: String, CaseIterable, Identifiable {
        case any = "Any", yes = "Yes", no = "No"
        var id: String { rawValue }
        func accepts(_ value: Bool?) -> Bool {
            self == .any || value == (self == .yes)
        }
    }
    var query = ""
    var minimumSeconds: Double?
    var maximumSeconds: Double?
    var uploadedAfter = ""
    var uploadedBefore = ""
    var minimumHeight: Int?
    var maximumBytes: Int64?
    var shorts: Requirement = .any
    var live: Requirement = .any

    var validationMessage: String? {
        func validDate(_ text: String) -> Bool {
            guard !text.isEmpty else { return true }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let date = formatter.date(from: text) else { return false }
            return formatter.string(from: date) == text
        }
        if !validDate(uploadedAfter) || !validDate(uploadedBefore) { return "Enter dates as YYYY-MM-DD." }
        if !uploadedAfter.isEmpty && !uploadedBefore.isEmpty && uploadedAfter > uploadedBefore { return "The start date must come before the end date." }
        if let minimumSeconds, !minimumSeconds.isFinite || minimumSeconds < 0 { return "Duration must be zero or greater." }
        if let maximumSeconds, !maximumSeconds.isFinite || maximumSeconds < 0 { return "Duration must be zero or greater." }
        if let minimumSeconds, let maximumSeconds, minimumSeconds > maximumSeconds { return "Minimum duration must not exceed maximum duration." }
        if let minimumHeight, minimumHeight < 1 { return "Height must be positive." }
        if let maximumBytes, maximumBytes < 1 { return "Size must be positive." }
        return nil
    }

    func matches(_ entry: PlaylistEntry) -> Bool {
        guard validationMessage == nil else { return false }
        let text = entry.title + " " + (entry.creator ?? "") + " " + (entry.videoID ?? "")
        guard query.isEmpty || text.localizedCaseInsensitiveContains(query),
              shorts.accepts(entry.isShort), live.accepts(entry.isLive) else { return false }
        if let minimumSeconds, entry.durationSeconds.map({ $0 >= minimumSeconds }) != true { return false }
        if let maximumSeconds, entry.durationSeconds.map({ $0 <= maximumSeconds }) != true { return false }
        if let minimumHeight, entry.height.map({ $0 >= minimumHeight }) != true { return false }
        if let maximumBytes, entry.estimatedBytes.map({ $0 <= maximumBytes }) != true { return false }
        if !uploadedAfter.isEmpty, entry.uploadDate.map({ $0 >= uploadedAfter }) != true { return false }
        if !uploadedBefore.isEmpty, entry.uploadDate.map({ $0 <= uploadedBefore }) != true { return false }
        return true
    }
}
