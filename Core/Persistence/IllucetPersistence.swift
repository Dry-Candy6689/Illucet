import Foundation

struct IllucetSnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var writeRevision: UInt64? = nil
    var settings: AppSettings
    var jobs: [DownloadJob]
    var history: [HistoryRecord]
    var recentLinks: [RecentLink]
    var quickStartPresets: [QuickStartPreset]
    var firstRunState: FirstRunState
    var updateStatus: UpdateStatus
    var filesFolderBookmark: Data?
    var filesFolderSelectionIdentity: String?
    var filesFolderDisplayName: String?
    var filesFolderAlias: String?
    var filesFolderAliasOfferShown: Bool
    var batches: [DownloadBatch]
    var downloadArchive: [DownloadArchiveEntry]
    var lastPreferencesExportAt: Date? = nil

    static let currentSchemaVersion = 10

    static let empty = Self(
        schemaVersion: currentSchemaVersion,
        settings: .defaults,
        jobs: [],
        history: [],
        recentLinks: [],
        quickStartPresets: QuickStartPresetLibrary.defaults,
        firstRunState: .initial,
        updateStatus: .initial,
        filesFolderBookmark: nil,
        filesFolderSelectionIdentity: nil,
        filesFolderDisplayName: nil,
        filesFolderAlias: nil,
        filesFolderAliasOfferShown: false,
        batches: [],
        downloadArchive: []
    )

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case writeRevision
        case settings
        case jobs
        case history
        case recentLinks
        case quickStartPresets
        case firstRunState
        case updateStatus
        case filesFolderBookmark
        case filesFolderSelectionIdentity
        case filesFolderDisplayName
        case filesFolderAlias
        case filesFolderAliasOfferShown
        case batches
        case downloadArchive
        case lastPreferencesExportAt
    }

    init(
        schemaVersion: Int,
        settings: AppSettings,
        jobs: [DownloadJob],
        history: [HistoryRecord],
        recentLinks: [RecentLink],
        quickStartPresets: [QuickStartPreset],
        firstRunState: FirstRunState,
        updateStatus: UpdateStatus,
        filesFolderBookmark: Data?,
        filesFolderSelectionIdentity: String?,
        filesFolderDisplayName: String?,
        filesFolderAlias: String?,
        filesFolderAliasOfferShown: Bool,
        batches: [DownloadBatch],
        downloadArchive: [DownloadArchiveEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.settings = settings
        self.jobs = jobs
        self.history = history
        self.recentLinks = recentLinks
        self.quickStartPresets = quickStartPresets
        self.firstRunState = firstRunState
        self.updateStatus = updateStatus
        self.filesFolderBookmark = filesFolderBookmark
        self.filesFolderSelectionIdentity = filesFolderSelectionIdentity
        self.filesFolderDisplayName = filesFolderDisplayName
        self.filesFolderAlias = filesFolderAlias
        self.filesFolderAliasOfferShown = filesFolderAliasOfferShown
        self.batches = batches
        self.downloadArchive = downloadArchive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? 1
        // Check the envelope before decoding payload fields. A newer app may
        // change those fields, and treating that as corruption would lose data
        // when the user returns to the newer version.
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw PersistenceError.unsupportedSchemaVersion(schemaVersion)
        }
        writeRevision = try container.decodeIfPresent(UInt64.self, forKey: .writeRevision)
        settings = try container.decode(
            AppSettings.self,
            forKey: .settings
        )
        jobs = try container.decodeIfPresent(
            [DownloadJob].self,
            forKey: .jobs
        ) ?? []
        history = try container.decodeIfPresent(
            [HistoryRecord].self,
            forKey: .history
        ) ?? []
        recentLinks = try container.decodeIfPresent(
            [RecentLink].self,
            forKey: .recentLinks
        ) ?? []
        quickStartPresets = try container.decodeIfPresent(
            [QuickStartPreset].self,
            forKey: .quickStartPresets
        ) ?? QuickStartPresetLibrary.defaults
        firstRunState = try container.decodeIfPresent(
            FirstRunState.self,
            forKey: .firstRunState
        ) ?? .initial
        updateStatus = try container.decodeIfPresent(
            UpdateStatus.self,
            forKey: .updateStatus
        ) ?? .initial
        filesFolderBookmark = try container.decodeIfPresent(
            Data.self,
            forKey: .filesFolderBookmark
        )
        filesFolderSelectionIdentity = try container.decodeIfPresent(
            String.self,
            forKey: .filesFolderSelectionIdentity
        )
        filesFolderDisplayName = try container.decodeIfPresent(
            String.self,
            forKey: .filesFolderDisplayName
        )
        filesFolderAlias = try container.decodeIfPresent(
            String.self,
            forKey: .filesFolderAlias
        )
        filesFolderAliasOfferShown = try container.decodeIfPresent(
            Bool.self,
            forKey: .filesFolderAliasOfferShown
        ) ?? false
        batches = try container.decodeIfPresent(
            [DownloadBatch].self,
            forKey: .batches
        ) ?? []
        downloadArchive = try container.decodeIfPresent(
            [DownloadArchiveEntry].self,
            forKey: .downloadArchive
        ) ?? []
        lastPreferencesExportAt = try container.decodeIfPresent(Date.self, forKey: .lastPreferencesExportAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(writeRevision, forKey: .writeRevision)
        try container.encode(settings, forKey: .settings)
        try container.encode(jobs, forKey: .jobs)
        try container.encode(history, forKey: .history)
        try container.encode(recentLinks, forKey: .recentLinks)
        try container.encode(
            quickStartPresets,
            forKey: .quickStartPresets
        )
        try container.encode(firstRunState, forKey: .firstRunState)
        try container.encode(updateStatus, forKey: .updateStatus)
        try container.encodeIfPresent(
            filesFolderBookmark,
            forKey: .filesFolderBookmark
        )
        try container.encodeIfPresent(
            filesFolderSelectionIdentity,
            forKey: .filesFolderSelectionIdentity
        )
        try container.encodeIfPresent(
            filesFolderDisplayName,
            forKey: .filesFolderDisplayName
        )
        try container.encodeIfPresent(
            filesFolderAlias,
            forKey: .filesFolderAlias
        )
        try container.encode(
            filesFolderAliasOfferShown,
            forKey: .filesFolderAliasOfferShown
        )
        try container.encode(batches, forKey: .batches)
        try container.encode(downloadArchive, forKey: .downloadArchive)
        try container.encodeIfPresent(lastPreferencesExportAt, forKey: .lastPreferencesExportAt)
    }
}

actor IllucetPersistence {
    private let fileManager: FileManager
    private let stateURL: URL
    private var cachedSnapshot: IllucetSnapshot?
    private var loadFailure: PersistenceError?

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let root = rootURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(
            path: AppIdentity.storageDirectoryName,
            directoryHint: .isDirectory
        )
        stateURL = root.appending(path: "IllucetState.json")
    }

    func load() throws -> IllucetSnapshot {
        if let cachedSnapshot {
            return cachedSnapshot
        }
        guard let data = try readStateData() else {
            cachedSnapshot = .empty
            loadFailure = nil
            return .empty
        }
        do {
            let snapshot = try JSONDecoder.illucetDecoder.decode(
                IllucetSnapshot.self,
                from: data
            )
            cachedSnapshot = snapshot
            loadFailure = nil
            return snapshot
        } catch let error as PersistenceError {
            loadFailure = error
            throw error
        } catch is DecodingError {
            let quarantine = stateURL.deletingLastPathComponent().appending(
                path: "IllucetState-corrupt-\(UUID().uuidString).json"
            )
            do {
                try fileManager.moveItem(at: stateURL, to: quarantine)
            } catch {
                let failure = PersistenceError.quarantineFailed
                loadFailure = failure
                throw failure
            }
            cachedSnapshot = .empty
            loadFailure = nil
            throw PersistenceError.corruptState(quarantine)
        } catch {
            loadFailure = .stateUnavailable
            throw PersistenceError.stateUnavailable
        }
    }

    func save(_ requested: IllucetSnapshot) throws {
        var snapshot = requested
        if let loadFailure { throw loadFailure }
        guard (1...IllucetSnapshot.currentSchemaVersion).contains(snapshot.schemaVersion) else {
            throw PersistenceError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }
        if let incomingRevision = requested.writeRevision,
           let durableRevision = cachedSnapshot?.writeRevision,
           incomingRevision < durableRevision { return }
        // A previously queued debounced save cannot erase a newer acknowledged export.
        // Missing rows still mean explicit user removal; do not resurrect them.
        if let cachedSnapshot {
            let durableJobs = Dictionary(uniqueKeysWithValues: cachedSnapshot.jobs.map { ($0.id, $0) })
            snapshot.jobs = snapshot.jobs.map { incoming in
                guard let durable = durableJobs[incoming.id],
                      ((durable.pipelineCheckpoint?.publicationRevision ?? 0) > (incoming.pipelineCheckpoint?.publicationRevision ?? 0)
                        || ((durable.pipelineCheckpoint?.publicationRevision ?? 0) > 0
                            && durable.pipelineCheckpoint?.publicationRevision == incoming.pipelineCheckpoint?.publicationRevision
                            && durable.updatedAt > incoming.updatedAt))
                else { return incoming }
                return durable
            }
            let durableHistory = Dictionary(cachedSnapshot.history.map { ($0.jobID, $0) }, uniquingKeysWith: { first, _ in first })
            snapshot.history = snapshot.history.map { incoming in
                guard let durable = durableHistory[incoming.jobID],
                      ((durable.publicationRevision ?? 0) > (incoming.publicationRevision ?? 0)
                        || ((durable.publicationRevision ?? 0) == (incoming.publicationRevision ?? 0)
                            && (durable.shareUpdatedAt ?? .distantPast) > (incoming.shareUpdatedAt ?? .distantPast)))
                else { return incoming }
                return durable
            }
        }
        if let loadFailure { throw loadFailure }
        // A save triggered during startup must not replace state the app has
        // never restored. Saving a new installation remains supported.
        if cachedSnapshot == nil, try readStateData() != nil {
            throw PersistenceError.stateNotLoaded
        }
        guard (1...IllucetSnapshot.currentSchemaVersion).contains(
            snapshot.schemaVersion
        ) else {
            throw PersistenceError.unsupportedSchemaVersion(
                snapshot.schemaVersion
            )
        }
        try fileManager.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.illucetEncoder.encode(snapshot)
        try data.write(
            to: stateURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        cachedSnapshot = snapshot
    }

    func reset() throws {
        do {
            try fileManager.removeItem(at: stateURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // A missing file is already reset; all other failures preserve the
            // cache and any write block so callers cannot mistake it for success.
        }
        cachedSnapshot = .empty
        loadFailure = nil
    }

    var persistedStateURL: URL { stateURL }

    private func readStateData() throws -> Data? {
        do {
            return try Data(contentsOf: stateURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            loadFailure = .stateUnavailable
            throw PersistenceError.stateUnavailable
        }
    }
}
enum PersistenceError: LocalizedError, Equatable, Sendable {
    case corruptState(URL)
    case stateUnavailable
    case quarantineFailed
    case unsupportedSchemaVersion(Int)
    case stateNotLoaded

    var recoveredWithEmptyState: Bool {
        if case .corruptState = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .corruptState:
            "Illucet recovered from an unreadable state file. A quarantined copy was kept for diagnostics."
        case .stateUnavailable:
            "Illucet could not read your saved data. It has been kept unchanged, and saving is paused. Try reopening the app after unlocking your device."
        case .quarantineFailed:
            "Illucet could not preserve a recovery copy of your saved data. The original has been kept unchanged, and saving is paused."
        case .unsupportedSchemaVersion:
            "This saved data uses an unsupported Illucet version. It has been kept unchanged. Open it with a compatible app version."
        case .stateNotLoaded:
            "Illucet has not finished restoring your saved data. Saving is paused to protect it."
        }
    }
}

extension JSONEncoder {
    static var illucetEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static var illucetDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
