import Foundation

enum SelectedSourceTransport: String, Equatable, Sendable {
    case directHTTP = "direct_http"
    case DASHFragments = "dash_fragments"
    case HLSResources = "hls_resources"
}

struct SelectedSourceFact: Equatable, Sendable {
    let formatID: String
    let fileExtension: String?
    let protocolName: String
    let sourceType: String
    let hasVideo: Bool
    let hasAudio: Bool
    let transport: SelectedSourceTransport

    init(format: MediaFormat, transport: SelectedSourceTransport) {
        formatID = format.formatID
        fileExtension = format.extension?.lowercased()
        protocolName = format.protocolName?.lowercased() ?? ""
        sourceType = format.sourceType
        hasVideo = format.hasVideo
        hasAudio = format.hasAudio
        self.transport = transport
    }

    func matches(_ stream: ResolvedStream) -> Bool {
        transport == .directHTTP
            && formatID == stream.formatID
            && hasVideo == stream.hasVideo
            && hasAudio == stream.hasAudio
            && sourceType == stream.sourceType
            && protocolName == stream.protocolName.lowercased()
            && (fileExtension == nil
                || fileExtension == stream.fileExtension?.lowercased())
    }

    func matches(_ plan: ResolvedDASHFragmentPlan) -> Bool {
        transport == .DASHFragments
            && formatID == plan.formatID
            && hasVideo == plan.hasVideo
            && hasAudio == plan.hasAudio
            && sourceType == plan.sourceType
            && protocolName == plan.protocolName.lowercased()
            && fileExtension == plan.fileExtension.lowercased()
    }

    func matches(_ selection: ResolvedHLSPlaylistSelection) -> Bool {
        transport == .HLSResources
            && formatID == selection.formatID
            && hasVideo == selection.hasVideo
            && hasAudio == selection.hasAudio
            && sourceType == selection.sourceType
            && protocolName == selection.protocolName.lowercased()
            && fileExtension == selection.fileExtension.lowercased()
    }
}

enum FormatSelection {
    static func supportedTransport(
        _ format: MediaFormat
    ) -> SelectedSourceTransport? {
        let protocolName = format.protocolName?.lowercased() ?? ""
        if format.sourceType == "direct_http",
           ["http", "https"].contains(protocolName) {
            return .directHTTP
        }
        if format.sourceType == "dash",
           protocolName == "http_dash_segments",
           let fileExtension = format.extension?.lowercased(),
           ["m4a", "mp4", "webm"].contains(fileExtension),
           format.hasVideo || format.hasAudio {
            return .DASHFragments
        }
        if format.sourceType == "hls",
           ["m3u8", "m3u8_native"].contains(protocolName),
           let fileExtension = format.extension?.lowercased(),
           ["m4a", "mp4", "webm"].contains(fileExtension),
           format.hasVideo || format.hasAudio {
            return .HLSResources
        }
        return nil
    }

    static func selectedSourceFacts(
        configuration: DownloadConfiguration,
        metadata: MediaMetadata
    ) throws -> [SelectedSourceFact] {
        var seen: Set<String> = []
        let selectedIDs = configuration.selectedFormatIDs.filter {
            seen.insert($0).inserted
        }
        guard !selectedIDs.isEmpty else {
            throw OutputCompatibilityError.invalidFormatSelection
        }
        var formatsByID: [String: MediaFormat] = [:]
        for format in metadata.formats {
            guard formatsByID[format.formatID] == nil else {
                throw OutputCompatibilityError.invalidFormatSelection
            }
            formatsByID[format.formatID] = format
        }
        return try selectedIDs.map { formatID in
            guard
                let format = formatsByID[formatID],
                let transport = supportedTransport(format)
            else {
                throw OutputCompatibilityError.invalidFormatSelection
            }
            return SelectedSourceFact(format: format, transport: transport)
        }
    }

    static func formats(
        for mode: DownloadMode,
        in metadata: MediaMetadata
    ) -> [MediaFormat] {
        metadata.formats.filter { format in
            guard supportedTransport(format) != nil else { return false }
            return switch mode {
            case .videoAndAudio:
                format.hasVideo || format.hasAudio
            case .audioOnly:
                format.hasAudio
            case .videoOnly:
                format.hasVideo
            }
        }
    }

    static func availableResolutions(in metadata: MediaMetadata) -> [Int] {
        Array(
            Set(
                metadata.formats.compactMap {
                    $0.hasVideo && supportedTransport($0) != nil
                        ? $0.pResolution
                        : nil
                }
            )
        ).sorted(by: >)
    }

    static func bestVideo(
        in metadata: MediaMetadata,
        maximumResolution: Int? = nil,
        appleCompatible: Bool = false
    ) -> MediaFormat? {
        let eligible = eligibleVideoFormats(
            in: metadata,
            maximumResolution: maximumResolution,
            appleCompatible: appleCompatible
        )
        let rolePure = eligible.filter { !$0.hasAudio }
        return sortedVideo(rolePure.isEmpty ? eligible : rolePure).first
    }

    static func bestAudio(
        in metadata: MediaMetadata,
        appleCompatible: Bool = false
    ) -> MediaFormat? {
        let eligible = eligibleAudioFormats(
            in: metadata,
            appleCompatible: appleCompatible
        )
        let rolePure = eligible.filter { !$0.hasVideo }
        return preferredAudio(in: rolePure.isEmpty ? eligible : rolePure)
    }

    static func applyAutomaticSelection(
        to configuration: inout DownloadConfiguration,
        metadata: MediaMetadata
    ) {
        guard configuration.thumbnailBehavior != .thumbnailOnly, !configuration.isSubtitlesOnly else {
            configuration.selectedVideoFormatID = nil
            configuration.selectedAudioFormatID = nil
            return
        }
        let compatible = configuration.preset == .compatible
            || configuration.container == .mp4
            || configuration.videoCodec == .h264
        let maximumResolution = configuration.preset == .small
            ? min(configuration.maximumResolution ?? 720, 720)
            : configuration.maximumResolution

        switch configuration.mode {
        case .videoAndAudio:
            let eligibleVideo = eligibleVideoFormats(
                in: metadata,
                maximumResolution: maximumResolution,
                appleCompatible: compatible
            )
            let eligibleAudio = eligibleAudioFormats(
                in: metadata,
                appleCompatible: compatible
            )
            let videoOnly = sortedVideo(eligibleVideo.filter { !$0.hasAudio }).first
            let audioOnly = preferredAudio(
                in: eligibleAudio.filter { !$0.hasVideo }
            )
            let audioEligibleIDs = Set(eligibleAudio.map(\.formatID))
            let combined = sortedVideo(eligibleVideo.filter {
                $0.hasAudio && audioEligibleIDs.contains($0.formatID)
            }).first
            let preferredVideo = sortedVideo(eligibleVideo).first

            if let combined, configuration.preset == .small {
                configuration.selectedVideoFormatID = combined.formatID
                configuration.selectedAudioFormatID = nil
            } else if let preferredVideo,
                      preferredVideo.hasAudio,
                      audioEligibleIDs.contains(preferredVideo.formatID) {
                configuration.selectedVideoFormatID = preferredVideo.formatID
                configuration.selectedAudioFormatID = nil
            } else if let videoOnly, let audioOnly {
                configuration.selectedVideoFormatID = videoOnly.formatID
                configuration.selectedAudioFormatID = audioOnly.formatID
            } else if let combined {
                configuration.selectedVideoFormatID = combined.formatID
                configuration.selectedAudioFormatID = nil
            } else {
                configuration.selectedVideoFormatID = nil
                configuration.selectedAudioFormatID = nil
            }
        case .audioOnly:
            configuration.selectedVideoFormatID = nil
            configuration.selectedAudioFormatID = bestAudio(
                in: metadata,
                appleCompatible: configuration.audioCodec == .aac
                    || configuration.container == .m4a
                    || configuration.container == .mp4
                    || configuration.videoCodec == .h264
            )?.formatID
        case .videoOnly:
            configuration.selectedVideoFormatID = bestVideo(
                in: metadata,
                maximumResolution: maximumResolution,
                appleCompatible: compatible
            )?.formatID
            configuration.selectedAudioFormatID = nil
        }
        configuration.formatSelectionProvenance = .automatic
    }

    static func estimatedDownloadBytes(
        configuration: DownloadConfiguration,
        metadata: MediaMetadata
    ) -> Int64? {
        let IDs = Set(configuration.selectedFormatIDs)
        let sizes = metadata.formats
            .filter { IDs.contains($0.formatID) }
            .compactMap(\.fileSize)
        guard sizes.count == IDs.count, !sizes.isEmpty,
              sizes.allSatisfy({ $0 >= 0 }) else { return nil }
        return sizes.reduce(0, StorageByteArithmetic.adding)
    }

    static func estimatedOutputBytes(
        configuration: DownloadConfiguration,
        metadata: MediaMetadata
    ) -> Int64? {
        guard let sourceBytes = estimatedDownloadBytes(
            configuration: configuration,
            metadata: metadata
        ) else {
            guard
                let duration = metadata.durationSeconds,
                let audioRate = configuration.audioBitrateKbps,
                configuration.mode == .audioOnly
            else { return nil }
            return StorageByteArithmetic.audioEstimate(
                durationSeconds: duration, bitrateKbps: audioRate
            )
        }
        if configuration.needsConversion,
           configuration.mode == .audioOnly,
           let duration = metadata.durationSeconds,
           let audioRate = configuration.audioBitrateKbps {
            return StorageByteArithmetic.audioEstimate(
                durationSeconds: duration, bitrateKbps: audioRate
            )
        }
        return sourceBytes
    }

    static func estimatedTemporaryBytes(
        configuration: DownloadConfiguration,
        metadata: MediaMetadata
    ) -> Int64? {
        guard
            let download = estimatedDownloadBytes(
                configuration: configuration,
                metadata: metadata
            ),
            let output = estimatedOutputBytes(
                configuration: configuration,
                metadata: metadata
            )
        else { return nil }
        let coverCopies = configuration.thumbnailBehavior == .includeVideoThumbnail
            ? StorageByteArithmetic.adding(output, configuration.splitChapters ? output : 0)
            : 0
        return StorageByteArithmetic.adding(
            StorageByteArithmetic.adding(StorageByteArithmetic.adding(download, output), coverCopies),
            max(268_435_456, output / 10)
        )
    }

    static func sourceQualityWarning(
        configuration: DownloadConfiguration,
        metadata: MediaMetadata
    ) -> String? {
        guard
            configuration.mode == .audioOnly,
            let target = configuration.audioBitrateKbps,
            let selectedID = configuration.selectedAudioFormatID,
            let source = metadata.formats.first(where: {
                $0.formatID == selectedID
            }),
            let sourceRate = source.audioBitrateKbps,
            Double(target) > sourceRate * 1.1
        else { return nil }
        return "The \(Int(sourceRate)) kbps source will not gain quality when encoded at \(target) kbps."
    }

    private static func sortedVideo(_ formats: [MediaFormat]) -> [MediaFormat] {
        let ranked = formats.allSatisfy { ($0.extractorPreferenceRank ?? -1) >= 0 }
        return formats.sorted { left, right in
            if ranked, let leftRank = left.extractorPreferenceRank,
               let rightRank = right.extractorPreferenceRank, leftRank != rightRank {
                return leftRank > rightRank
            }
            return isPreferredVideo(left, right)
        }
    }

    private static func isPreferredVideo(
        _ left: MediaFormat,
        _ right: MediaFormat
    ) -> Bool {
        let leftResolution = left.pResolution ?? 0
        let rightResolution = right.pResolution ?? 0
        if leftResolution != rightResolution {
            return leftResolution > rightResolution
        }
        let leftFPS = left.framesPerSecond ?? 0
        let rightFPS = right.framesPerSecond ?? 0
        if leftFPS != rightFPS { return leftFPS > rightFPS }
        let leftRate = left.videoBitrateKbps ?? left.totalBitrateKbps ?? 0
        let rightRate = right.videoBitrateKbps ?? right.totalBitrateKbps ?? 0
        if leftRate != rightRate { return leftRate > rightRate }
        let leftTransport = transportPreference(left)
        let rightTransport = transportPreference(right)
        if leftTransport != rightTransport {
            return leftTransport > rightTransport
        }
        return left.formatID < right.formatID
    }

    private static func eligibleVideoFormats(
        in metadata: MediaMetadata,
        maximumResolution: Int?,
        appleCompatible: Bool
    ) -> [MediaFormat] {
        metadata.formats.filter { format in
            guard format.hasVideo,
                  supportedTransport(format) != nil
            else { return false }
            if let maximumResolution,
               let pResolution = format.pResolution,
               pResolution > maximumResolution {
                return false
            }
            guard appleCompatible else { return true }
            let codec = format.videoCodec?.lowercased() ?? ""
            let ext = format.extension?.lowercased() ?? ""
            return (codec.contains("avc") || codec.contains("h264")
                    || codec.contains("hevc") || codec.contains("h265"))
                && ["mp4", "mov", "m4v"].contains(ext)
        }
    }

    private static func eligibleAudioFormats(
        in metadata: MediaMetadata,
        appleCompatible: Bool
    ) -> [MediaFormat] {
        metadata.formats.filter { format in
            guard format.hasAudio,
                  supportedTransport(format) != nil
            else { return false }
            guard appleCompatible else { return true }
            let codec = format.audioCodec?.lowercased() ?? ""
            let ext = format.extension?.lowercased() ?? ""
            return codec.contains("aac") || ["m4a", "mp4"].contains(ext)
        }
    }

    private static func preferredAudio(
        in formats: [MediaFormat]
    ) -> MediaFormat? {
        let ranked = formats.allSatisfy { ($0.extractorPreferenceRank ?? -1) >= 0 }
        return formats.sorted { left, right in
            if ranked, let leftRank = left.extractorPreferenceRank,
               let rightRank = right.extractorPreferenceRank, leftRank != rightRank {
                return leftRank > rightRank
            }
            let leftRate = left.audioBitrateKbps
                ?? left.totalBitrateKbps ?? 0
            let rightRate = right.audioBitrateKbps
                ?? right.totalBitrateKbps ?? 0
            if leftRate != rightRate { return leftRate > rightRate }
            let leftTransport = transportPreference(left)
            let rightTransport = transportPreference(right)
            if leftTransport != rightTransport {
                return leftTransport > rightTransport
            }
            return left.formatID < right.formatID
        }.first
    }

    private static func transportPreference(_ format: MediaFormat) -> Int {
        supportedTransport(format) == .directHTTP ? 1 : 0
    }
}

struct RollingSpeedEstimator: Equatable, Sendable {
    private(set) var smoothedBytesPerSecond: Double?
    private(set) var sampleCount = 0
    private let smoothing: Double
    private var lastSampleTime: Double?
    private var lastSampleBytes: Int64 = 0

    init(smoothing: Double = 0.22) {
        self.smoothing = smoothing.isFinite ? min(max(smoothing, 0.01), 1) : 0.22
    }

    /// Accumulate actual byte deltas over a full second, independent of callback frequency.
    /// The first event establishes a baseline so restored bytes never inflate speed.
    mutating func record(totalBytes: Int64, at time: Double) {
        guard totalBytes >= 0, time.isFinite else { return }
        guard let previousTime = lastSampleTime else {
            lastSampleTime = time
            lastSampleBytes = totalBytes
            return
        }
        guard time >= previousTime, totalBytes >= lastSampleBytes else {
            self = Self(smoothing: smoothing)
            lastSampleTime = time
            lastSampleBytes = totalBytes
            return
        }
        let elapsed = time - previousTime
        guard elapsed >= 1 else { return }
        _ = add(bytes: totalBytes - lastSampleBytes, elapsedSeconds: elapsed)
        lastSampleTime = time
        lastSampleBytes = totalBytes
    }

    mutating func add(bytes: Int64, elapsedSeconds: Double) -> Double? {
        guard bytes >= 0, elapsedSeconds.isFinite, elapsedSeconds > 0 else {
            return smoothedBytesPerSecond
        }
        let instantaneous = Double(bytes) / elapsedSeconds
        guard instantaneous.isFinite else { return smoothedBytesPerSecond }
        if let current = smoothedBytesPerSecond {
            let weight = 1 - pow(1 - smoothing, elapsedSeconds)
            smoothedBytesPerSecond =
                weight * instantaneous + (1 - weight) * current
        } else {
            smoothedBytesPerSecond = instantaneous
        }
        sampleCount += 1
        return smoothedBytesPerSecond
    }

    func eta(remainingBytes: Int64) -> Double? {
        guard
            sampleCount >= 3,
            let smoothedBytesPerSecond,
            smoothedBytesPerSecond > 0,
            remainingBytes >= 0
        else { return nil }
        return Double(remainingBytes) / smoothedBytesPerSecond
    }
}

enum FilenameSystem {
    static let supportedFields = [
        "title", "video_id", "channel", "uploader", "upload_date",
        "playlist", "playlist_index", "resolution", "format_id", "codec",
        "container",
    ]

    static func render(
        template: String,
        metadata: MediaMetadata,
        configuration: DownloadConfiguration,
        format: MediaFormat?
    ) -> String {
        var replacements: [String: String] = [
            "title": metadata.title,
            "video_id": metadata.videoID,
            "channel": metadata.channel ?? "",
            "uploader": metadata.uploader ?? "",
            "upload_date": metadata.uploadDate ?? "",
            "resolution": format?.resolution ?? "",
            "format_id": format?.formatID ?? "",
            "codec": format?.videoCodec ?? format?.audioCodec ?? "",
            "container": configuration.container.rawValue.lowercased(),
            "playlist": "",
            "playlist_index": "",
        ]
        replacements = replacements.mapValues(sanitizeComponent)
        var value = template
        for field in supportedFields {
            value = value.replacingOccurrences(
                of: "{\(field)}",
                with: replacements[field] ?? ""
            )
        }
        return sanitizeComponent(value).isEmpty
            ? sanitizeComponent(metadata.title)
            : sanitizeComponent(value)
    }

    static func sanitizeComponent(_ input: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
        let pieces = input.components(separatedBy: illegal)
        var value = pieces.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        while value.utf8.count > 180, !value.isEmpty {
            value.removeLast()
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    static func resolvedCollisionURL(
        desiredURL: URL,
        videoID: String,
        handling: DuplicateHandling,
        fileManager: FileManager = .default
    ) throws -> URL? {
        guard fileManager.fileExists(atPath: desiredURL.path) else {
            return desiredURL
        }
        switch handling {
        case .ask:
            throw ExportError.duplicateDecisionRequired(desiredURL)
        case .skip:
            return nil
        case .overwrite:
            return desiredURL
        case .addVideoID:
            let sanitizedID = sanitizeComponent(videoID)
            guard !sanitizedID.isEmpty else {
                throw IllucetError.filesDestinationUnavailable
            }
            let stem = desiredURL.deletingPathExtension().lastPathComponent
            let identified = desiredURL.deletingLastPathComponent().appending(
                path: "\(stem)-\(sanitizedID)"
            ).appendingPathExtension(desiredURL.pathExtension)
            if !fileManager.fileExists(atPath: identified.path) {
                return identified
            }
            return try resolvedCollisionURL(
                desiredURL: identified,
                videoID: videoID,
                handling: .addNumber,
                fileManager: fileManager
            )
        case .addNumber:
            let stem = desiredURL.deletingPathExtension().lastPathComponent
            let directory = desiredURL.deletingLastPathComponent()
            for index in 2 ... 9_999 {
                let candidate = directory
                    .appending(path: "\(stem) \(index)")
                    .appendingPathExtension(desiredURL.pathExtension)
                if !fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            throw IllucetError.filesDestinationUnavailable
        }
    }
}
