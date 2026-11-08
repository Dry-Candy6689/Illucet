import Foundation

enum RetainedAudioFormat: String, CaseIterable, Identifiable, Sendable {
    case mp3 = "MP3", aac = "AAC / M4A", flac = "FLAC"
    var id: String { rawValue }
    var codec: MediaCodec { switch self { case .mp3: .mp3; case .aac: .aac; case .flac: .flac } }
    var container: MediaContainer { switch self { case .mp3: .mp3; case .aac: .m4a; case .flac: .flac } }
    var fileExtension: String { switch self { case .mp3: "mp3"; case .aac: "m4a"; case .flac: "flac" } }
}

/// A foreground, local conversion from a retained file. Never re-extracts a URL
/// or modifies the original, and uses the same native verifier and exporter.
struct RetainedMediaReprocessor {
    let processor: any MediaProcessor
    let exporter: ExportManager
    var fastStart = AppSettings.defaults.fastStartMP4
    var outputResolver = SavedOutputResolver()
    var folderBookmark: Data? = nil

    func convert(record: HistoryRecord, format: RetainedAudioFormat,
                 progress: @escaping MediaProcessingProgressHandler) async throws -> HistoryRecord {
        guard let sourceURL = URL(string: "https://www.youtube.com/watch?v=" + record.videoID) else { throw IllucetError.invalidURL }
        guard let recordedURL = record.fileURL else { throw IllucetError.filesDestinationUnavailable }
        let access = outputResolver.open(record, fallbackBookmark: folderBookmark)
        defer { withExtendedLifetime(access) {} }
        let source = try access.read(recordedURL) { $0 }
        let original = try await processor.probe(source, verificationClass: .boundedStrong)
        guard original.audioStreamCount > 0, let duration = original.durationSeconds,
              duration.isFinite, duration > 0 else { throw IllucetError.noCompatibleFormat }
        let id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Illucet-" + id.uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("reprocessed." + format.fileExtension)
        let request = MediaProcessingRequest(operationID: id, operation: .transcodeAudio(inputURL: source), destinationURL: output,
            output: MediaOutputSpecification(container: format.container, video: .remove,
                audio: .encode(AudioEncodingSettings(codec: format.codec, bitRate: format == .flac ? nil : 192_000,
                    sampleRate: nil, channelLayout: .preserve, loudnessNormalization: nil)),
                dynamicRange: .preserve, subtitleCodec: nil, fastStart: fastStart, preserveMetadata: true, preserveChapters: false),
            metadata: .empty, chapters: [], trimming: nil, overwriteExisting: false,
            verification: MediaVerificationRequirements(expectedContainer: format.container,
                expectedFileExtension: format.fileExtension, expectedVideoStreams: 0...0, expectedAudioStreams: 1...1,
                expectedSubtitleStreams: 0...0, expectedVideoCodec: nil, expectedAudioCodec: format.codec,
                expectedDimensions: nil, expectedFrameRate: nil, frameRateTolerance: 0.05, expectedHDR: nil,
                expectedAudioSampleRate: nil, expectedAudioChannelCount: nil, expectedDurationSeconds: duration,
                durationToleranceSeconds: 0.5, expectedAudioBitRate: nil, audioBitRateToleranceFraction: 0.2,
                expectedChapterCount: 0...0, requireArtwork: false, requireMetadataKeys: [], expectedMetadataValues: [:],
                forbiddenMetadataKeys: [], requiredVerificationClass: .boundedStrong))
        let result = try await processor.process(request, progress: progress)
        try Task.checkCancellation()
        guard result.outputURLs == [output], let probe = result.probes.first, result.probes.count == 1 else {
            throw IllucetError.filesDestinationUnavailable
        }
        let exported = try await exporter.export(sourceURL: output, destination: .appDocuments,
            filename: FilenameSystem.sanitizeComponent(record.title) + " - " + format.fileExtension,
            folderBookmark: nil, duplicateHandling: .addNumber, videoID: record.videoID, jobID: id,
            title: record.title, assetKind: .audio)
        var configuration = DownloadConfiguration.standard
        configuration.mode = .audioOnly
        configuration.thumbnailBehavior = .none
        configuration.audioCodec = format == .mp3 ? .mp3 : format == .aac ? .aac : .flac
        configuration.container = format == .mp3 ? .mp3 : format == .aac ? .m4a : .flac
        configuration.destination = .appDocuments
        var job = DownloadJob(id: id, sourceURL: sourceURL,
            videoID: record.videoID, title: record.title + " — " + format.rawValue, channel: record.channel,
            thumbnailURL: record.thumbnailURL, createdAt: .now, updatedAt: .now, configuration: configuration,
            state: .completed, stage: .complete, progress: .zero, priority: 0, retryCount: 0, maximumRetries: 0,
            errorCode: nil, errorMessage: nil, outputURL: exported.fileURL, outputProbe: probe,
            selectedFormatIDs: [], extractorVersion: nil)
        job.exportOutcome = exported.outcome
        job.outputReferences = outputResolver.references(for: exported.fileURL.map { [$0] } ?? [])
        return HistoryRecord(job: job)
    }
}
