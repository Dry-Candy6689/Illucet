import Foundation

enum QuickStartLaunchBehavior: String, Codable, CaseIterable, Identifiable,
    Sendable
{
    case confirmation = "Show quick confirmation"
    case immediate = "Download immediately"

    var id: String { rawValue }
}

struct QuickStartPreset: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var systemImage: String
    var configuration: DownloadConfiguration
    var launchBehavior: QuickStartLaunchBehavior

    init(
        id: UUID = UUID(),
        name: String,
        systemImage: String,
        configuration: DownloadConfiguration,
        launchBehavior: QuickStartLaunchBehavior = .confirmation
    ) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.configuration = configuration
        self.launchBehavior = launchBehavior
    }

    func resolvedConfiguration(
        metadata: MediaMetadata
    ) throws -> DownloadConfiguration {
        var result = configuration
        // Fresh downloads use the complete video and automatic artwork selection.
        // Persisted jobs keep their original configuration for retry/resume.
        result.trimStartSeconds = nil
        result.trimEndSeconds = nil
        result.trimMode = nil
        result.thumbnailID = nil
        var sponsorBlock = result.sponsorBlock
        sponsorBlock.promoteCategoryOverridesToDefaults()
        sponsorBlock.clearSelection()
        result.sponsorBlock = sponsorBlock
        result.selectedVideoFormatID = nil
        result.selectedAudioFormatID = nil
        result = OutputCapabilityMatrix.normalized(result)
        FormatSelection.applyAutomaticSelection(
            to: &result,
            metadata: metadata
        )
        if result.subtitleDelivery != .none, result.subtitleSelections == nil,
           let english = SubtitleSelectionPlanner.defaultEnglishSelection(in: metadata.subtitles) {
            result.subtitleSelections = [english]
            result = OutputCapabilityMatrix.normalized(result)
        }
        try OutputCapabilityMatrix.validate(result, metadata: metadata)
        return result
    }

    var qualityLabel: String {
        if configuration.thumbnailBehavior == .thumbnailOnly { return "Best available image" }
        switch configuration.mode {
        case .audioOnly:
            if let capability = ConversionCapabilityMatrix.audio(
                configuration.audioCodec
            ) {
                if capability.isLossless {
                    return "Lossless \(configuration.audioCodec.rawValue)"
                }
                if configuration.resolvedAudioRateControl == .quality {
                    return "\(configuration.resolvedAudioQuality.rawValue) \(configuration.audioCodec.rawValue)"
                }
                return "\(configuration.audioBitrateKbps ?? 192) kbps \(configuration.audioCodec.rawValue)"
            }
            return "Best original audio"
        case .videoAndAudio, .videoOnly:
            if let maximum = configuration.maximumResolution {
                return "Up to \(maximum)p"
            }
            switch configuration.preset {
            case .compatible: return "Best Apple-compatible"
            case .small: return "Up to 720p"
            default: return "Best available"
            }
        }
    }

    var outputLabel: String {
        if configuration.thumbnailBehavior == .thumbnailOnly { return "Thumbnail only" }
        switch configuration.mode {
        case .audioOnly:
            return ConversionCapabilityMatrix.audio(
                configuration.audioCodec
            ) == nil
                ? "Original audio"
                : "\(configuration.audioCodec.rawValue) audio"
        case .videoOnly:
            return "Video only • no audio"
        case .videoAndAudio:
            if configuration.container == .mp4
                || configuration.videoCodec == .h264 {
                return "Compatible MP4 video"
            }
            return "Video + audio"
        }
    }
}

enum QuickStartPresetLibrary {
    static let allowedSystemImages = [
        "photo",
        "sparkles",
        "iphone",
        "leaf",
        "waveform",
        "music.note",
        "video",
        "film",
        "bolt.fill",
        "arrow.down.circle.fill",
        "headphones",
        "play.rectangle",
        "externaldrive",
    ]

    static let legacyDefaults: [QuickStartPreset] = [
        QuickStartPreset(
            id: UUID(
                uuidString: "D1000000-0000-0000-0000-000000000001"
            )!,
            name: "Best Video",
            systemImage: "sparkles",
            configuration: configuration { value in
                value.mode = .videoAndAudio
                value.preset = .best
                value.maximumResolution = nil
                value.preserveSourceResolution = true
                value.videoCodec = .automatic
                value.audioCodec = .automatic
                value.container = .automatic
                value.thumbnailBehavior = .separate
            }
        ),
        QuickStartPreset(
            id: UUID(
                uuidString: "D1000000-0000-0000-0000-000000000002"
            )!,
            name: "Compatible Video",
            systemImage: "iphone",
            configuration: configuration { value in
                value.mode = .videoAndAudio
                value.preset = .compatible
                value.maximumResolution = nil
                value.preserveSourceResolution = true
                value.videoCodec = .h264
                value.audioCodec = .automatic
                value.container = .mp4
                value.thumbnailBehavior = .separate
            }
        ),
        QuickStartPreset(
            id: UUID(
                uuidString: "D1000000-0000-0000-0000-000000000003"
            )!,
            name: "Small Video",
            systemImage: "leaf",
            configuration: configuration { value in
                value.mode = .videoAndAudio
                value.preset = .small
                value.maximumResolution = 720
                value.preserveSourceResolution = false
                value.videoCodec = .automatic
                value.audioCodec = .automatic
                value.container = .automatic
                value.thumbnailBehavior = .separate
            }
        ),
        QuickStartPreset(
            id: UUID(
                uuidString: "D1000000-0000-0000-0000-000000000004"
            )!,
            name: "MP3 Audio",
            systemImage: "waveform",
            configuration: configuration { value in
                value.mode = .audioOnly
                value.preset = .audio
                value.videoCodec = .automatic
                value.audioCodec = .mp3
                value.container = .mp3
                value.audioBitrateKbps = 192
                value.thumbnailBehavior = .separateAndEmbed
            }
        ),
        QuickStartPreset(
            id: UUID(
                uuidString: "D1000000-0000-0000-0000-000000000005"
            )!,
            name: "Original Audio",
            systemImage: "music.note",
            configuration: configuration { value in
                value.mode = .audioOnly
                value.preset = .custom
                value.videoCodec = .automatic
                value.audioCodec = .original
                value.container = .automatic
                value.audioBitrateKbps = nil
                value.thumbnailBehavior = .separate
            }
        ),
        QuickStartPreset(
            id: UUID(
                uuidString: "D1000000-0000-0000-0000-000000000006"
            )!,
            name: "Video Only",
            systemImage: "video",
            configuration: configuration { value in
                value.mode = .videoOnly
                value.preset = .best
                value.maximumResolution = nil
                value.preserveSourceResolution = true
                value.videoCodec = .automatic
                value.audioCodec = .automatic
                value.container = .automatic
                value.thumbnailBehavior = .separate
            }
        ),
    ]

    static let defaults: [QuickStartPreset] = {
        var best = legacyDefaults[0]
        best.name = "Best video"
        var audio = legacyDefaults[4]
        audio.name = "Best audio"
        var compatible = legacyDefaults[1]
        compatible.name = "Compatible video"
        var thumbnail = best
        thumbnail.id = UUID(uuidString: "D1000000-0000-0000-0000-000000000007")!
        thumbnail.name = "Thumbnail"
        thumbnail.systemImage = "photo"
        thumbnail.configuration.thumbnailBehavior = .thumbnailOnly
        thumbnail.configuration.cropArtworkSquare = false
        var media = [best, audio, compatible]
        for index in media.indices {
            // Compatible output can embed a video thumbnail. Original-quality
            // presets keep their own source/container choices.
            media[index].configuration.thumbnailBehavior = media[index].configuration.preset == .compatible ? .includeVideoThumbnail : .none
            media[index].configuration.preserveChapters = true
            media[index].configuration.writeChapters = true
        }
        return normalized(media + [thumbnail])
    }()

    static func migratingStockPresets(_ presets: [QuickStartPreset],
                                      referencedID: UUID?) -> [QuickStartPreset] {
        var previousDefaults = defaults
        previousDefaults[3].configuration.cropArtworkSquare = true
        guard normalized(presets) == normalized(legacyDefaults)
            || normalized(presets) == previousDefaults else {
            return normalized(presets)
        }
        if let referencedID, !defaults.contains(where: { $0.id == referencedID }) {
            return normalized(presets)
        }
        return defaults
    }

    static func normalized(
        _ presets: [QuickStartPreset]
    ) -> [QuickStartPreset] {
        var seen = Set<UUID>()
        return presets.prefix(24).compactMap { preset in
            guard seen.insert(preset.id).inserted else { return nil }
            var result = preset
            let trimmedName = result.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            result.name = String(
                (trimmedName.isEmpty ? "Quick Start" : trimmedName).prefix(48)
            )
            if !allowedSystemImages.contains(result.systemImage) {
                result.systemImage = "bolt.fill"
            }
            result.configuration = OutputCapabilityMatrix.normalized(
                result.configuration
            )
            var sponsorBlock = result.configuration.sponsorBlock
            sponsorBlock.promoteCategoryOverridesToDefaults()
            sponsorBlock.clearSelection()
            result.configuration.sponsorBlock = sponsorBlock
            return result
        }
    }

    /// Consume the old global override once so each preset owns its behavior.
    static func migrateLaunchBehavior(settings: inout AppSettings, presets: inout [QuickStartPreset]) {
        guard settings.experience.instantQuickStart else { return }
        for index in presets.indices { presets[index].launchBehavior = .immediate }
        settings.experience.instantQuickStart = false
    }

    static func newPreset(
        sponsorBlock: SponsorBlockPolicy = .disabled
    ) -> QuickStartPreset {
        var configuration = DownloadConfiguration.standard
        configuration.sponsorBlock = sponsorBlock
        configuration = OutputCapabilityMatrix.normalized(configuration)
        return QuickStartPreset(
            name: "New Preset",
            systemImage: "bolt.fill",
            configuration: configuration
        )
    }

    static func duplicate(
        _ preset: QuickStartPreset,
        in presets: [QuickStartPreset]
    ) -> [QuickStartPreset] {
        guard let sourceIndex = presets.firstIndex(where: {
            $0.id == preset.id
        }) else {
            return presets
        }
        var copy = preset
        copy.id = UUID()
        copy.name = availableCopyName(for: preset.name, in: presets)
        var result = presets
        result.insert(copy, at: sourceIndex + 1)
        return normalized(result)
    }

    static func move(
        _ presets: [QuickStartPreset],
        fromOffsets offsets: IndexSet,
        toOffset destination: Int
    ) -> [QuickStartPreset] {
        let validOffsets = offsets.sorted().filter {
            presets.indices.contains($0)
        }
        guard !validOffsets.isEmpty else { return presets }
        let moving = validOffsets.map { presets[$0] }
        let movingSet = Set(validOffsets)
        var remaining = presets.enumerated().compactMap { index, preset in
            movingSet.contains(index) ? nil : preset
        }
        let adjustedDestination = destination
            - validOffsets.count(where: { $0 < destination })
        remaining.insert(
            contentsOf: moving,
            at: min(max(0, adjustedDestination), remaining.count)
        )
        return remaining
    }

    private static func configuration(
        _ update: (inout DownloadConfiguration) -> Void
    ) -> DownloadConfiguration {
        var result = DownloadConfiguration.standard
        // Built-in Quick Starts intentionally remain the compact path. The
        // analyzed download options own all advanced Part 8 decisions.
        result.preserveChapters = false
        result.writeChapters = false
        result.splitChapters = false
        update(&result)
        return OutputCapabilityMatrix.normalized(result)
    }

    private static func availableCopyName(
        for name: String,
        in presets: [QuickStartPreset]
    ) -> String {
        let names = Set(presets.map { $0.name.localizedLowercase })
        let first = "\(name) Copy"
        if !names.contains(first.localizedLowercase) {
            return first
        }
        var index = 2
        while names.contains("\(first) \(index)".localizedLowercase) {
            index += 1
        }
        return "\(first) \(index)"
    }
}

enum QuickStartLaunchPolicy {
    static func validate(
        configuration: DownloadConfiguration,
        metadata: MediaMetadata,
        hasFilesFolder: Bool,
        availableBytes: Int64?,
        reserveBytes: Int64
    ) throws {
        try OutputCapabilityMatrix.validate(
            configuration,
            metadata: metadata
        )
        let sponsorPlan = try SponsorBlockPlanner.validateLaunch(
            policy: configuration.effectiveSponsorBlock,
            videoID: metadata.videoID,
            analyzedDuration: metadata.durationSeconds
        )
        if sponsorPlan.entries.contains(where: { $0.action == .remove }) {
            try SponsorBlockExecutionSupport.validate(
                plan: sponsorPlan,
                policy: configuration.effectiveSponsorBlock,
                configuration: configuration,
                outputPlan: try OutputCapabilityMatrix.makePlan(
                    configuration: configuration,
                    metadata: metadata
                )
            )
        }
        guard configuration.playlistBehavior == .referencedVideo else {
            throw IllucetError.playlistConfirmationRequired
        }
        guard configuration.destination != .askEveryTime else {
            throw IllucetError.internalFailure(
                "Choose a destination before using this Quick Start preset."
            )
        }
        if [
            ExportDestination.filesFolder,
            .filesAndPhotos,
        ].contains(configuration.destination), !hasFilesFolder {
            throw IllucetError.filesDestinationUnavailable
        }
        if let availableBytes,
           let required = FormatSelection.estimatedTemporaryBytes(
               configuration: configuration,
               metadata: metadata
           ) {
            try StorageByteArithmetic.validateBudget(
                requiredBytes: required,
                reserveBytes: reserveBytes,
                availableBytes: availableBytes
            )
        }
    }
}

enum RelativeTimestampFormatter {
    static func string(from date: Date, relativeTo now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60:
            return "Just now"
        case ..<3_600:
            return "\(max(1, Int(seconds / 60))) min ago"
        case ..<86_400:
            return "\(max(1, Int(seconds / 3_600))) hr ago"
        case ..<172_800:
            return "Yesterday"
        case ..<2_592_000:
            return "\(max(2, Int(seconds / 86_400))) days ago"
        case ..<31_536_000:
            return "\(max(1, Int(seconds / 2_592_000))) mo ago"
        default:
            return "\(max(1, Int(seconds / 31_536_000))) yr ago"
        }
    }
}
