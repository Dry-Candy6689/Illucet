import Foundation

enum SponsorBlockCategory: String, Codable, CaseIterable, Hashable,
    Identifiable, Sendable
{
    case sponsor
    case selfPromotion = "selfpromo"
    case interaction
    case highlight = "poi_highlight"
    case intro
    case outro
    case preview
    case hook
    case filler

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sponsor: "Sponsor"
        case .selfPromotion: "Unpaid/Self Promotion"
        case .interaction: "Interaction Reminder"
        case .highlight: "Highlight"
        case .intro: "Intermission/Intro Animation"
        case .outro: "Endcards/Credits"
        case .preview: "Preview/Recap"
        case .hook: "Hook/Greetings"
        case .filler: "Tangents/Jokes"
        }
    }

    var isAggressive: Bool { self == .filler }
    var editableActions: [SponsorBlockAction] {
        self == .highlight ? [.keep, .markAsChapter] : SponsorBlockAction.editableActions
    }

    static var stableOrder: [Self] { allCases }
}

enum SponsorBlockAction: String, Codable, CaseIterable, Hashable,
    Identifiable, Sendable
{
    case keep = "Keep"
    case markAsChapter = "Mark as Chapter"
    case remove = "Remove"
    case ask = "Ask"

    var id: String { rawValue }

    /// Keep/Ask remain decodable for existing records; editable policies expose Off.
    var title: String { self == .keep || self == .ask ? "Off" : rawValue }
    static let editableActions: [Self] = [.keep, .remove, .markAsChapter]
    static func alternatives(to inherited: Self) -> [Self] {
        editableActions.filter { $0 != inherited }
    }

    fileprivate var stableOrder: Int {
        switch self {
        case .keep: 0
        case .markAsChapter: 1
        case .remove: 2
        case .ask: 3
        }
    }
}

enum SponsorBlockRemovalMode: String, Codable, CaseIterable, Hashable,
    Identifiable, Sendable
{
    case accurate = "Accurate"
    case fastKeyframe = "Fast (Keyframe-Aligned)"

    var id: String { rawValue }

    var usesApproximateBoundaries: Bool { self == .fastKeyframe }
}

enum SponsorBlockServerAction: String, Codable, Sendable {
    case skip
    case mute
    case full
    case chapter
    case pointOfInterest = "poi"
}

struct SponsorBlockSegment: Equatable, Sendable {
    let segmentID: String
    let category: SponsorBlockCategory
    let startSeconds: Double
    let endSeconds: Double
    let description: String?
    let submittedVideoDuration: Double
    let serverAction: SponsorBlockServerAction
    let votes: Int
    let isLocked: Bool
}

enum SponsorBlockTiming {
    // Physical evidence showed a 0.26-second whole-duration representation
    // difference. Keep the allowance below one second and clamp only the
    // executable plan; the returned server timing remains in the snapshot.
    static let maximumEndBoundaryDifferenceSeconds = 0.5
}

struct SponsorBlockCategoryRule: Codable, Equatable, Identifiable, Sendable {
    let category: SponsorBlockCategory
    var action: SponsorBlockAction

    var id: SponsorBlockCategory { category }
}

struct SponsorBlockSegmentSelection: Codable, Equatable, Identifiable,
    Sendable
{
    let segmentID: String
    let category: SponsorBlockCategory
    let startSeconds: Double
    let endSeconds: Double
    let description: String?
    let submittedVideoDuration: Double
    var isIncluded: Bool
    var actionOverride: SponsorBlockAction?

    var id: String { segmentID }
}

struct SponsorBlockSelectionSnapshot: Codable, Equatable, Sendable {
    let videoID: String
    let queriedCategories: Set<SponsorBlockCategory>
    var segments: [SponsorBlockSegmentSelection]
}

struct SponsorBlockPolicy: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var selectedCategories: Set<SponsorBlockCategory>
    var categoryRules: [SponsorBlockCategoryRule]
    var selectionSnapshot: SponsorBlockSelectionSnapshot?
    var removalMode: SponsorBlockRemovalMode
    var lookupUnavailable: Bool
    var categoryOverrides: [SponsorBlockCategoryRule]? = nil

    static let disabled = Self(
        isEnabled: false,
        selectedCategories: [],
        categoryRules: [],
        selectionSnapshot: nil,
        removalMode: .accurate,
        lookupUnavailable: false
    )

    static let discoveryCategories = Set(SponsorBlockCategory.allCases)
    static let safeDefaultIncludedCategories = Set(
        SponsorBlockCategory.allCases.filter { !$0.isAggressive && $0 != .highlight }
    )

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case selectedCategories
        case categoryRules
        case selectionSnapshot
        case removalMode
        case lookupUnavailable
        case automaticDiscovery
        case categoryOverrides, actionInheritance
    }

    init(
        isEnabled: Bool,
        selectedCategories: Set<SponsorBlockCategory>,
        categoryRules: [SponsorBlockCategoryRule] = [],
        selectionSnapshot: SponsorBlockSelectionSnapshot? = nil,
        removalMode: SponsorBlockRemovalMode = .accurate,
        lookupUnavailable: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.selectedCategories = selectedCategories
        self.categoryRules = categoryRules
        self.selectionSnapshot = selectionSnapshot
        self.removalMode = removalMode
        self.lookupUnavailable = lookupUnavailable
        self = normalized()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .isEnabled
        ) ?? false
        selectedCategories = try container.decodeIfPresent(
            Set<SponsorBlockCategory>.self,
            forKey: .selectedCategories
        ) ?? []
        categoryRules = try container.decodeIfPresent(
            [SponsorBlockCategoryRule].self,
            forKey: .categoryRules
        ) ?? []
        selectionSnapshot = try container.decodeIfPresent(
            SponsorBlockSelectionSnapshot.self,
            forKey: .selectionSnapshot
        )
        removalMode = try container.decodeIfPresent(
            SponsorBlockRemovalMode.self,
            forKey: .removalMode
        ) ?? .accurate
        lookupUnavailable = try container.decodeIfPresent(
            Bool.self,
            forKey: .lookupUnavailable
        ) ?? false
        let automaticDiscovery = try container.decodeIfPresent(
            Bool.self,
            forKey: .automaticDiscovery
        ) ?? false
        if !automaticDiscovery,
           isEnabled,
           selectedCategories.isEmpty,
           selectionSnapshot == nil {
            // Before automatic discovery, an enabled policy with no selected
            // categories was a durable no-op. Preserve that legacy meaning
            // instead of unexpectedly requiring a preview after migration.
            isEnabled = false
        }
        categoryOverrides = try container.decodeIfPresent([SponsorBlockCategoryRule].self, forKey: .categoryOverrides)
        // Old Ask policies never silently become removal. Old explicit exclusions
        // and inclusions become overrides when they differ from category defaults.
        let legacyAskCategories = Set(categoryRules.filter { $0.action == .ask }.map(\.category))
        for index in categoryRules.indices where categoryRules[index].action == .ask {
            categoryRules[index].action = .keep
        }
        if var snapshot = selectionSnapshot {
            let legacy = try container.decodeIfPresent(Bool.self, forKey: .actionInheritance) != true
            for index in snapshot.segments.indices {
                let segment = snapshot.segments[index]
                if segment.actionOverride == .ask || (segment.actionOverride == nil && legacyAskCategories.contains(segment.category)) {
                    snapshot.segments[index].actionOverride = .keep
                    snapshot.segments[index].isIncluded = false
                } else if legacy && !segment.isIncluded {
                    snapshot.segments[index].actionOverride = categoryDefaultAction(for: segment.category) == .keep ? nil : .keep
                } else if legacy && segment.actionOverride == nil && categoryDefaultAction(for: segment.category) == .keep {
                    snapshot.segments[index].actionOverride = action(for: segment.category)
                }
            }
            selectionSnapshot = snapshot
        }
        self = normalized()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(selectedCategories, forKey: .selectedCategories)
        try container.encode(categoryRules, forKey: .categoryRules)
        try container.encodeIfPresent(
            selectionSnapshot,
            forKey: .selectionSnapshot
        )
        try container.encode(removalMode, forKey: .removalMode)
        try container.encode(lookupUnavailable, forKey: .lookupUnavailable)
        try container.encode(true, forKey: .automaticDiscovery)
        try container.encode(true, forKey: .actionInheritance)
        try container.encodeIfPresent(categoryOverrides, forKey: .categoryOverrides)
    }

    var needsSegmentReview: Bool {
        isEnabled
    }

    var requestedDiscoveryCategories: Set<SponsorBlockCategory> {
        isEnabled ? Self.discoveryCategories : []
    }

    var isPristineDisabled: Bool {
        !isEnabled
            && selectedCategories.isEmpty
            && categoryRules.isEmpty
            && (categoryOverrides?.isEmpty ?? true)
            && selectionSnapshot == nil
            && removalMode == .accurate
            && !lookupUnavailable
    }

    func action(for category: SponsorBlockCategory) -> SponsorBlockAction {
        categoryRules.first(where: { $0.category == category })?.action
            ?? (category.isAggressive || category == .highlight ? .keep : .remove)
    }

    func resolvedAction(
        for segment: SponsorBlockSegmentSelection
    ) -> SponsorBlockAction {
        segment.actionOverride ?? categoryOverride(for: segment.category) ?? action(for: segment.category)
    }

    func categoryDefaultAction(for category: SponsorBlockCategory) -> SponsorBlockAction {
        guard selectedCategories.contains(category) else { return .keep }
        let action = action(for: category)
        return action == .ask ? .keep : action
    }

    func categoryOverride(for category: SponsorBlockCategory) -> SponsorBlockAction? {
        categoryOverrides?.first { $0.category == category }?.action
    }

    func categoryDownloadAction(for category: SponsorBlockCategory) -> SponsorBlockAction {
        categoryOverride(for: category) ?? categoryDefaultAction(for: category)
    }

    mutating func setDefaultAction(_ action: SponsorBlockAction, for category: SponsorBlockCategory) {
        categoryOverrides?.removeAll { $0.category == category }
        if categoryOverrides?.isEmpty == true { categoryOverrides = nil }
        setSelected(action != .keep, for: category)
        setAction(action, for: category)
    }

    mutating func promoteCategoryOverridesToDefaults() {
        let overrides = categoryOverrides ?? []
        for rule in overrides { setDefaultAction(rule.action, for: rule.category) }
    }

    mutating func setCategoryOverride(_ action: SponsorBlockAction?, for category: SponsorBlockCategory) {
        var overrides = categoryOverrides ?? []
        overrides.removeAll { $0.category == category }
        if let action, action != categoryDefaultAction(for: category) {
            overrides.append(.init(category: category, action: action))
        }
        categoryOverrides = overrides.isEmpty ? nil : overrides
        guard var snapshot = selectionSnapshot else { return }
        for index in snapshot.segments.indices where snapshot.segments[index].category == category {
            let chosen = snapshot.segments[index].actionOverride ?? categoryDownloadAction(for: category)
            snapshot.segments[index].isIncluded = chosen != .keep
        }
        selectionSnapshot = snapshot
    }

    mutating func setSegmentOverride(_ action: SponsorBlockAction?, segmentID: String) {
        guard var snapshot = selectionSnapshot,
              let index = snapshot.segments.firstIndex(where: { $0.segmentID == segmentID }) else { return }
        let inherited = categoryDownloadAction(for: snapshot.segments[index].category)
        snapshot.segments[index].actionOverride = action == inherited ? nil : action
        snapshot.segments[index].isIncluded = (action ?? inherited) != .keep
        selectionSnapshot = snapshot
    }

    var requiresRemoval: Bool {
        selectionSnapshot?.segments.contains { segment in
            segment.isIncluded && resolvedAction(for: segment) == .remove
        } ?? false
    }

    var hasSelectedOutputMutation: Bool {
        selectionSnapshot?.segments.contains { segment in
            guard segment.isIncluded else { return false }
            let action = resolvedAction(for: segment)
            return action == .remove || action == .markAsChapter
        } ?? false
    }

    var hasSelectedChapterIntent: Bool {
        selectionSnapshot?.segments.contains { segment in
            segment.isIncluded
                && resolvedAction(for: segment) == .markAsChapter
        } ?? false
    }

    mutating func setSelected(
        _ selected: Bool,
        for category: SponsorBlockCategory
    ) {
        if selected {
            selectedCategories.insert(category)
        } else {
            selectedCategories.remove(category)
        }
        selectionSnapshot = nil
        self = normalized()
    }

    mutating func setEnabled(_ enabled: Bool) {
        let wasEnabled = isEnabled
        isEnabled = enabled
        if enabled, !wasEnabled, selectedCategories.isEmpty, categoryRules.isEmpty {
            selectedCategories = Self.safeDefaultIncludedCategories
        }
        if !enabled {
            clearSelection()
        }
        self = normalized()
    }

    mutating func setAction(
        _ action: SponsorBlockAction,
        for category: SponsorBlockCategory
    ) {
        categoryRules.removeAll { $0.category == category }
        categoryRules.append(
            SponsorBlockCategoryRule(category: category, action: action)
        )
        self = normalized()
    }

    mutating func clearSelection() {
        selectionSnapshot = nil
        lookupUnavailable = false
    }

    mutating func markLookupUnavailable() {
        lookupUnavailable = isEnabled
    }

    mutating func replaceSelection(
        videoID: String,
        queriedCategories: Set<SponsorBlockCategory>,
        segments: [SponsorBlockSegment]
    ) {
        let previous = (selectionSnapshot?.segments ?? []).reduce(
            into: [String: SponsorBlockSegmentSelection]()
        ) { result, segment in
            result[segment.segmentID] = segment
        }
        let selections = segments.map { segment in
            let old = previous[segment.segmentID]
            return SponsorBlockSegmentSelection(
                segmentID: segment.segmentID,
                category: segment.category,
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                description: segment.description,
                submittedVideoDuration: segment.submittedVideoDuration,
                isIncluded: old?.isIncluded
                    ?? (categoryOverride(for: segment.category).map { $0 != .keep }
                        ?? selectedCategories.contains(segment.category)),
                actionOverride: old?.actionOverride
            )
        }.sorted(by: Self.segmentSelectionOrder)
        selectionSnapshot = SponsorBlockSelectionSnapshot(
            videoID: videoID,
            queriedCategories: queriedCategories,
            segments: selections
        )
        lookupUnavailable = false
        self = normalized()
    }

    func normalized() -> Self {
        var result = self
        let supported = Set(SponsorBlockCategory.allCases)
        result.selectedCategories.formIntersection(supported)
        if !result.isEnabled {
            result.lookupUnavailable = false
        }

        var seen = Set<SponsorBlockCategory>()
        result.categoryRules = result.categoryRules
            .filter { supported.contains($0.category) }
            .reversed()
            .filter { seen.insert($0.category).inserted }
            .reversed()
            .sorted {
                Self.categoryIndex($0.category)
                    < Self.categoryIndex($1.category)
            }
        if let overrides = result.categoryOverrides {
            var seenOverrides = Set<SponsorBlockCategory>()
            let normalized = overrides.reversed()
                .filter { supported.contains($0.category) && seenOverrides.insert($0.category).inserted }
                .map { SponsorBlockCategoryRule(category: $0.category, action: $0.action == .ask ? .keep : $0.action) }
                .sorted { Self.categoryIndex($0.category) < Self.categoryIndex($1.category) }
            result.categoryOverrides = normalized.isEmpty ? nil : normalized
        }

        guard result.isEnabled, let snapshot = result.selectionSnapshot else {
            result.selectionSnapshot = nil
            return result
        }
        var normalizedSnapshot = snapshot
        normalizedSnapshot.segments.sort(by: Self.segmentSelectionOrder)
        result.selectionSnapshot = normalizedSnapshot
        return result
    }

    func acceptsSnapshotQueryScope(
        _ snapshot: SponsorBlockSelectionSnapshot
    ) -> Bool {
        if snapshot.queriedCategories == requestedDiscoveryCategories {
            return true
        }
        if categoryDownloadAction(for: .highlight) == .keep,
           snapshot.queriedCategories == requestedDiscoveryCategories.subtracting([.highlight]),
           snapshot.segments.allSatisfy({ snapshot.queriedCategories.contains($0.category) }) {
            return true
        }
        return snapshot.queriedCategories == selectedCategories
            && snapshot.segments.allSatisfy {
                snapshot.queriedCategories.contains($0.category)
            }
    }

    private static func categoryIndex(
        _ category: SponsorBlockCategory
    ) -> Int {
        SponsorBlockCategory.stableOrder.firstIndex(of: category) ?? .max
    }

    private static func segmentSelectionOrder(
        _ lhs: SponsorBlockSegmentSelection,
        _ rhs: SponsorBlockSegmentSelection
    ) -> Bool {
        if lhs.startSeconds != rhs.startSeconds {
            return lhs.startSeconds < rhs.startSeconds
        }
        if lhs.endSeconds != rhs.endSeconds {
            return lhs.endSeconds < rhs.endSeconds
        }
        let lhsCategory = categoryIndex(lhs.category)
        let rhsCategory = categoryIndex(rhs.category)
        if lhsCategory != rhsCategory { return lhsCategory < rhsCategory }
        return lhs.segmentID < rhs.segmentID
    }
}

struct SponsorBlockPlanEntry: Codable, Equatable, Sendable {
    let sourceSegmentIDs: [String]
    let categories: [SponsorBlockCategory]
    let startSeconds: Double
    let endSeconds: Double
    let action: SponsorBlockAction
}

struct SponsorBlockPlan: Codable, Equatable, Sendable {
    let videoID: String
    let entries: [SponsorBlockPlanEntry]

    var hasOutputMutation: Bool {
        entries.contains {
            $0.action == .remove || $0.action == .markAsChapter
        }
    }

    static func empty(videoID: String) -> Self {
        Self(videoID: videoID, entries: [])
    }
}

enum SponsorBlockApplicationStatus: String, Codable, Equatable, Sendable {
    case requested
    case applied
    case notApplied
    case fallback
    case failed
    case cancelled
}

enum SponsorBlockFallbackReason: String, Codable, Equatable, Sendable {
    case lookupUnavailable
}

struct SponsorBlockAppliedSegment: Codable, Equatable, Sendable {
    let sourceSegmentIDs: [String]
    let categories: [SponsorBlockCategory]
    let action: SponsorBlockAction
    let requestedRange: MediaTimeRange
}

struct SponsorBlockApplicationRecord: Codable, Equatable, Sendable {
    var status: SponsorBlockApplicationStatus
    let requestedRemovalMode: SponsorBlockRemovalMode
    var actualRemovalMode: SponsorBlockRemovalMode?
    let segments: [SponsorBlockAppliedSegment]
    let requestedRemovalRanges: [MediaTimeRange]
    var actualRemovalRanges: [MediaTimeRange]
    var removedSegmentCount: Int
    var removedDurationSeconds: Double
    var sponsorBlockChapterCount: Int
    var fallbackReason: SponsorBlockFallbackReason?

    static func requested(
        plan: SponsorBlockPlan,
        mode: SponsorBlockRemovalMode
    ) -> Self {
        let segments = plan.entries.prefix(512).map {
            SponsorBlockAppliedSegment(
                sourceSegmentIDs: Array($0.sourceSegmentIDs.prefix(64)),
                categories: Array($0.categories.prefix(16)),
                action: $0.action,
                requestedRange: MediaTimeRange(
                    startSeconds: $0.startSeconds,
                    endSeconds: $0.endSeconds
                )
            )
        }
        let removals = segments.filter { $0.action == .remove }
            .map(\.requestedRange)
        let hasMutation = segments.contains {
            $0.action == .remove || $0.action == .markAsChapter
        }
        return Self(
            status: hasMutation ? .requested : .notApplied,
            requestedRemovalMode: mode,
            actualRemovalMode: nil,
            segments: segments,
            requestedRemovalRanges: removals,
            actualRemovalRanges: [],
            removedSegmentCount: 0,
            removedDurationSeconds: 0,
            sponsorBlockChapterCount: 0,
            fallbackReason: nil
        )
    }

    static func fallback(
        mode: SponsorBlockRemovalMode,
        reason: SponsorBlockFallbackReason
    ) -> Self {
        Self(
            status: .fallback,
            requestedRemovalMode: mode,
            actualRemovalMode: nil,
            segments: [],
            requestedRemovalRanges: [],
            actualRemovalRanges: [],
            removedSegmentCount: 0,
            removedDurationSeconds: 0,
            sponsorBlockChapterCount: 0,
            fallbackReason: reason
        )
    }
}

enum SponsorBlockPlanningError: LocalizedError, Equatable, Sendable {
    case previewRequired
    case videoIdentityMismatch
    case categoryScopeMismatch
    case invalidDuration
    case duplicateSegmentIdentity
    case invalidSegmentRange
    case segmentOutsideDuration
    case unresolvedAsk
    case executionUnavailable
    case requiredLookupUnavailable
    case unsupportedExecutionPath

    var errorDescription: String? {
        switch self {
        case .previewRequired:
            "Review the SponsorBlock segments before continuing."
        case .videoIdentityMismatch:
            "The SponsorBlock preview belongs to a different analyzed video. Refresh it before continuing."
        case .categoryScopeMismatch:
            "SponsorBlock categories changed. Refresh the segment preview before continuing."
        case .invalidDuration:
            "The analyzed media duration is invalid for SponsorBlock planning."
        case .duplicateSegmentIdentity:
            "SponsorBlock returned duplicate segment identities. Refresh the preview before continuing."
        case .invalidSegmentRange:
            "A selected SponsorBlock segment has an invalid time range."
        case .segmentOutsideDuration:
            "A selected SponsorBlock segment falls outside the analyzed media duration."
        case .unresolvedAsk:
            "Choose an action for every SponsorBlock segment currently set to Ask."
        case .executionUnavailable:
            "SponsorBlock removal and chapter writing are planned but not applied in this version. Choose Keep or turn SponsorBlock off to start this download."
        case .requiredLookupUnavailable:
            "SponsorBlock removal is required, but the segment lookup is unavailable. Retry the preview before starting."
        case .unsupportedExecutionPath:
            "The selected SponsorBlock removal mode is unavailable for this output. Choose Accurate or a supported MP4/MOV video output."
        }
    }
}

enum SponsorBlockPlanner {
    static func makePlan(
        policy sourcePolicy: SponsorBlockPolicy,
        videoID: String,
        analyzedDuration: Double?
    ) throws -> SponsorBlockPlan {
        let policy = sourcePolicy.normalized()
        guard policy.needsSegmentReview else {
            return .empty(videoID: videoID)
        }
        if policy.lookupUnavailable {
            guard !policy.requiresRemoval else {
                throw SponsorBlockPlanningError.requiredLookupUnavailable
            }
            return .empty(videoID: videoID)
        }
        guard let snapshot = policy.selectionSnapshot else {
            throw SponsorBlockPlanningError.previewRequired
        }
        guard snapshot.videoID == videoID else {
            throw SponsorBlockPlanningError.videoIdentityMismatch
        }
        guard policy.acceptsSnapshotQueryScope(snapshot) else {
            throw SponsorBlockPlanningError.categoryScopeMismatch
        }
        if let analyzedDuration,
           !analyzedDuration.isFinite || analyzedDuration <= 0 {
            throw SponsorBlockPlanningError.invalidDuration
        }

        var seen = Set<String>()
        var entries: [SponsorBlockPlanEntry] = []
        for segment in snapshot.segments where segment.isIncluded {
            guard seen.insert(segment.segmentID).inserted else {
                throw SponsorBlockPlanningError.duplicateSegmentIdentity
            }
            guard !segment.segmentID.isEmpty,
                  segment.startSeconds.isFinite,
                  segment.endSeconds.isFinite,
                  segment.submittedVideoDuration.isFinite,
                  segment.startSeconds >= 0,
                  (segment.category == .highlight
                    ? segment.endSeconds == segment.startSeconds
                    : segment.endSeconds > segment.startSeconds),
                  segment.submittedVideoDuration >= 0
            else {
                throw SponsorBlockPlanningError.invalidSegmentRange
            }
            var plannedEndSeconds = segment.endSeconds
            if let analyzedDuration {
                guard segment.startSeconds < analyzedDuration,
                      segment.endSeconds <= analyzedDuration
                        + SponsorBlockTiming
                            .maximumEndBoundaryDifferenceSeconds
                else {
                    throw SponsorBlockPlanningError.segmentOutsideDuration
                }
                plannedEndSeconds = min(segment.endSeconds, analyzedDuration)
            } else if segment.submittedVideoDuration > 0 {
                guard segment.startSeconds < segment.submittedVideoDuration,
                      segment.endSeconds <= segment.submittedVideoDuration
                        + SponsorBlockTiming
                            .maximumEndBoundaryDifferenceSeconds
                else {
                    throw SponsorBlockPlanningError.invalidSegmentRange
                }
                plannedEndSeconds = min(
                    segment.endSeconds,
                    segment.submittedVideoDuration
                )
            }
            let action = policy.resolvedAction(for: segment)
            guard segment.category != .highlight || action == .keep || action == .markAsChapter else {
                throw SponsorBlockPlanningError.invalidSegmentRange
            }
            guard action != .ask else {
                throw SponsorBlockPlanningError.unresolvedAsk
            }
            entries.append(
                SponsorBlockPlanEntry(
                    sourceSegmentIDs: [segment.segmentID],
                    categories: [segment.category],
                    startSeconds: segment.startSeconds,
                    endSeconds: plannedEndSeconds,
                    action: action
                )
            )
        }

        let normalized = normalizeRemoveOverlaps(entries)
            .sorted(by: stableEntryOrder)
        return SponsorBlockPlan(videoID: videoID, entries: normalized)
    }

    static func validateLaunch(
        policy: SponsorBlockPolicy,
        videoID: String,
        analyzedDuration: Double?
    ) throws -> SponsorBlockPlan {
        let plan = try makePlan(
            policy: policy,
            videoID: videoID,
            analyzedDuration: analyzedDuration
        )
        return plan
    }

    private static func normalizeRemoveOverlaps(
        _ entries: [SponsorBlockPlanEntry]
    ) -> [SponsorBlockPlanEntry] {
        let other = entries.filter { $0.action != .remove }
        let removes = entries.filter { $0.action == .remove }
            .sorted(by: stableEntryOrder)
        var merged: [SponsorBlockPlanEntry] = []
        for entry in removes {
            guard let previous = merged.last,
                  entry.startSeconds < previous.endSeconds
            else {
                merged.append(entry)
                continue
            }
            let identities = Array(
                Set(previous.sourceSegmentIDs + entry.sourceSegmentIDs)
            ).sorted()
            let categories = SponsorBlockCategory.stableOrder.filter {
                previous.categories.contains($0)
                    || entry.categories.contains($0)
            }
            merged[merged.count - 1] = SponsorBlockPlanEntry(
                sourceSegmentIDs: identities,
                categories: categories,
                startSeconds: previous.startSeconds,
                endSeconds: max(previous.endSeconds, entry.endSeconds),
                action: .remove
            )
        }
        return other + merged
    }

    private static func stableEntryOrder(
        _ lhs: SponsorBlockPlanEntry,
        _ rhs: SponsorBlockPlanEntry
    ) -> Bool {
        if lhs.startSeconds != rhs.startSeconds {
            return lhs.startSeconds < rhs.startSeconds
        }
        if lhs.endSeconds != rhs.endSeconds {
            return lhs.endSeconds < rhs.endSeconds
        }
        if lhs.action.stableOrder != rhs.action.stableOrder {
            return lhs.action.stableOrder < rhs.action.stableOrder
        }
        return lhs.sourceSegmentIDs.lexicographicallyPrecedes(
            rhs.sourceSegmentIDs
        )
    }
}
