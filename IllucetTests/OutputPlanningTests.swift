import Foundation
import Testing
@testable import Illucet

@Suite("deterministic planning")
struct OutputPlanningTests {
    @Test
    func everySelectableAudioCodecContainerPlansTypedEncoding() throws {
        for codec in ConversionCapabilityMatrix.audioCodecs {
            let capability = try #require(
                ConversionCapabilityMatrix.audio(codec)
            )
            for container in capability.containers {
                var value = audioConfiguration()
                value.audioCodec = codec
                value.container = container
                value.sampleRate = .hz44100
                value.channels = .mono
                value.loudnessNormalization = true
                value = OutputCapabilityMatrix.normalized(value)

                let plan = try OutputCapabilityMatrix.makePlan(
                    configuration: value,
                    metadata: DeveloperFixtures.media
                )

                #expect(plan.strategy == .transcodeAudio)
                #expect(plan.containerChoice == container)
                #expect(plan.expectedAudioCodec == capability.nativeCodec)
                #expect(plan.expectedSampleRate == 44_100)
                #expect(plan.expectedChannelCount == 1)
                #expect(
                    plan.audioEncodingSettings?
                        .loudnessNormalization != nil
                )
            }
        }
    }

    @Test
    func everySelectableAudioRateAndQualityRequestIsDeterministic() throws {
        for codec in ConversionCapabilityMatrix.audioCodecs {
            let capability = try #require(
                ConversionCapabilityMatrix.audio(codec)
            )
            for bitRate in capability.bitRatesKbps {
                var value = audioConfiguration()
                value.audioCodec = codec
                value.container = capability.containers[0]
                value.audioRateControl = .bitRate
                value.audioBitrateKbps = bitRate
                value = OutputCapabilityMatrix.normalized(value)
                let plan = try OutputCapabilityMatrix.makePlan(
                    configuration: value,
                    metadata: DeveloperFixtures.media
                )
                #expect(
                    plan.audioEncodingSettings?.bitRate
                        == Int64(bitRate * 1_000)
                )
                #expect(plan.audioEncodingSettings?.quality == nil)
            }
            guard capability.rateControls.contains(.quality) else {
                continue
            }
            for quality in AudioQualityChoice.allCases {
                var value = audioConfiguration()
                value.audioCodec = codec
                value.container = capability.containers[0]
                value.audioRateControl = .quality
                value.audioQuality = quality
                value = OutputCapabilityMatrix.normalized(value)
                let plan = try OutputCapabilityMatrix.makePlan(
                    configuration: value,
                    metadata: DeveloperFixtures.media
                )
                #expect(plan.audioEncodingSettings?.bitRate == nil)
                #expect(
                    plan.audioEncodingSettings?.quality?.value
                        == quality.nativeValue
                )
            }
        }
    }

    @Test
    func everySelectableSampleRateChannelAndNormalizationRequestPlans()
        throws
    {
        for codec in ConversionCapabilityMatrix.audioCodecs {
            let capability = try #require(
                ConversionCapabilityMatrix.audio(codec)
            )
            for sampleRate in OutputCapabilityMatrix.enabledSampleRates {
                for channels in OutputCapabilityMatrix.enabledChannelChoices {
                    for normalize in [false, true] {
                        var value = audioConfiguration()
                        value.audioCodec = codec
                        value.container = capability.containers[0]
                        value.sampleRate = sampleRate
                        value.channels = channels
                        value.loudnessNormalization = normalize
                        value = OutputCapabilityMatrix.normalized(value)

                        let plan = try OutputCapabilityMatrix.makePlan(
                            configuration: value,
                            metadata: DeveloperFixtures.media
                        )

                        #expect(
                            plan.audioEncodingSettings?.sampleRate
                                == sampleRate.value
                        )
                        #expect(
                            plan.expectedChannelCount
                                == expectedChannelCount(channels)
                        )
                        #expect(
                            (plan.audioEncodingSettings?
                                .loudnessNormalization != nil)
                                == normalize
                        )
                    }
                }
            }
        }
    }

    @Test
    func everySelectableVideoCodecContainerAndFrameRatePlansExactly()
        throws
    {
        for codec in ConversionCapabilityMatrix.selectableVideoCodecs {
            let capability = try #require(
                ConversionCapabilityMatrix.video(codec)
            )
            for container in capability.containers {
                for frameRate in OutputCapabilityMatrix.enabledFrameRates {
                    var value = videoConfiguration()
                    value.videoCodec = codec
                    value.container = container
                    value.frameRate = frameRate
                    value = OutputCapabilityMatrix.normalized(value)

                    let plan = try OutputCapabilityMatrix.makePlan(
                        configuration: value,
                        metadata: DeveloperFixtures.media
                    )

                    #expect(plan.strategy == .transcodeVideo)
                    #expect(plan.containerChoice == container)
                    #expect(plan.expectedVideoCodec == capability.nativeCodec)
                    #expect(
                        plan.videoEncodingFrameRate == frameRate.value
                    )
                    #expect(
                        plan.expectedFrameRate == frameRate.value ?? 30
                    )
                }
            }
        }
    }

    @Test
    func portraitMaximumResolutionScalesThePDimension() throws {
        var value = videoConfiguration()
        value.videoCodec = .h264
        value.container = .mp4
        value.maximumResolution = 720
        value.preserveSourceResolution = false
        value = OutputCapabilityMatrix.normalized(value)

        let scaled = try OutputCapabilityMatrix.makePlan(
            configuration: value,
            metadata: portraitMetadata()
        )
        #expect(
            scaled.expectedDimensions
                == MediaDimensions(width: 720, height: 1_280)
        )

        value.maximumResolution = 1_080
        value = OutputCapabilityMatrix.normalized(value)
        let preserved = try OutputCapabilityMatrix.makePlan(
            configuration: value,
            metadata: portraitMetadata()
        )
        #expect(
            preserved.expectedDimensions
                == MediaDimensions(width: 1_080, height: 1_920)
        )
    }

    @Test
    func semanticQualityTierWinsAcrossLandscapePortraitAndWideGeometry()
        throws
    {
        let cases: [(String?, Int?, Int?, String?, Int)] = [
            ("1080p", 1_920, 1_080, "1920x1080", 1_080),
            ("1080p portrait", 1_080, 1_920, "1080x1920", 1_080),
            ("1080p", 1_920, 804, "1920x804", 1_080),
            ("720p60", 1_280, nil, "1280x?", 720),
            (nil, 1_280, 536, "720p", 720),
        ]
        for (note, width, height, resolution, expected) in cases {
            let metadata = qualityMetadata(
                formatNote: note,
                width: width,
                height: height,
                resolution: resolution
            )
            let format = try #require(
                metadata.formats.first { $0.formatID == "401" }
            )
            #expect(format.pResolution == expected)
        }

        let fallback = try #require(
            qualityMetadata(
                formatNote: "Premium",
                width: 1_920,
                height: 804,
                resolution: "1920x804"
            ).formats.first { $0.formatID == "401" }
        )
        #expect(fallback.pResolution == 804)

        let boundedFallback = try #require(
            qualityMetadata(
                formatNote: "99999p",
                width: 1_920,
                height: 804,
                resolution: "1920x804"
            ).formats.first { $0.formatID == "401" }
        )
        #expect(boundedFallback.pResolution == 804)
    }

    @Test
    func wideSemanticTierDrivesMaximumResolutionScaling() throws {
        var value = videoConfiguration()
        value.videoCodec = .h264
        value.container = .mp4
        value.maximumResolution = 720
        value.preserveSourceResolution = false
        value = OutputCapabilityMatrix.normalized(value)

        let scaled = try OutputCapabilityMatrix.makePlan(
            configuration: value,
            metadata: qualityMetadata(
                formatNote: "1080p",
                width: 1_920,
                height: 804,
                resolution: "1920x804"
            )
        )
        #expect(
            scaled.expectedDimensions
                == MediaDimensions(width: 1_280, height: 536)
        )
    }

    @Test
    func everySelectableCombinedCodecContainerPairHasARealWorkflow()
        throws
    {
        for videoCodec in ConversionCapabilityMatrix.selectableVideoCodecs {
            for audioCodec in ConversionCapabilityMatrix.audioCodecs {
                let containers = OutputCapabilityMatrix.enabledContainers(
                    for: .videoAndAudio,
                    audioCodec: audioCodec,
                    videoCodec: videoCodec
                ).filter { $0 != .automatic }
                #expect(!containers.isEmpty)
                for container in containers {
                    var value = combinedConfiguration()
                    value.videoCodec = videoCodec
                    value.audioCodec = audioCodec
                    value.container = container
                    value = OutputCapabilityMatrix.normalized(value)

                    let plan = try OutputCapabilityMatrix.makePlan(
                        configuration: value,
                        metadata: DeveloperFixtures.media
                    )

                    #expect(plan.strategy == .assembleConvertedStreams)
                    #expect(plan.needsVideoConversion)
                    #expect(plan.needsAudioConversion)
                    #expect(plan.containerChoice == container)
                }
            }
        }
    }

    @Test
    func unavailableCodecContainerAndHDRRequestsFailClosed() {
        var unavailable = videoConfiguration()
        unavailable.videoCodec = .vp9
        #expect(
            OutputCapabilityMatrix.normalized(unavailable).videoCodec
                == .automatic
        )

        var webM = videoConfiguration()
        webM.videoCodec = .h264
        webM.container = .webm
        #expect(throws: OutputCompatibilityError.self) {
            try OutputCapabilityMatrix.makePlan(
                configuration: webM,
                metadata: DeveloperFixtures.media
            )
        }

        var HDR = videoConfiguration()
        HDR.videoCodec = .h264
        HDR.container = .mp4
        #expect(throws: OutputCompatibilityError.self) {
            try OutputCapabilityMatrix.makePlan(
                configuration: HDR,
                metadata: HDRMetadata()
            )
        }
    }

    @Test
    func requestBuilderCarriesFastStartMetadataAndRemovalPolicy() throws {
        var value = audioConfiguration()
        value.audioCodec = .aac
        value.container = .m4a
        value = OutputCapabilityMatrix.normalized(value)
        let plan = try OutputCapabilityMatrix.makePlan(
            configuration: value,
            metadata: DeveloperFixtures.media
        )
        var settings = AppSettings.defaults
        settings.fastStartMP4 = true
        settings.preserveMetadata = true
        let destination = URL(filePath: "/tmp/part7-request.m4a")
        let preserving = try MediaConversionRequestBuilder(
            plan: plan,
            configuration: value,
            metadata: DeveloperFixtures.media,
            settings: settings
        ).request(
            operationID: UUID(),
            operation: .transcodeAudio(
                inputURL: URL(filePath: "/tmp/source.m4a")
            ),
            destination: destination
        )

        #expect(preserving.output.fastStart)
        #expect(preserving.output.preserveMetadata)
        #expect(preserving.metadata.title == DeveloperFixtures.media.title)
        #expect(
            preserving.metadata.additional["source_url"]
                == DeveloperFixtures.media.canonicalURL.absoluteString
        )
        #expect(
            preserving.verification.requireMetadataKeys.contains(
                "comment"
            )
        )

        settings.preserveMetadata = false
        let removing = try MediaConversionRequestBuilder(
            plan: plan,
            configuration: value,
            metadata: DeveloperFixtures.media,
            settings: settings
        ).request(
            operationID: UUID(),
            operation: .transcodeAudio(
                inputURL: URL(filePath: "/tmp/source.m4a")
            ),
            destination: destination
        )
        #expect(removing.metadata == .empty)
        #expect(
            removing.verification.forbiddenMetadataKeys.contains(
                "source_url"
            )
        )
    }

    private func audioConfiguration() -> DownloadConfiguration {
        var value = DownloadConfiguration.standard
        value.mode = .audioOnly
        value.preset = .custom
        value.selectedVideoFormatID = nil
        value.selectedAudioFormatID = "140"
        value.videoCodec = .automatic
        value.audioCodec = .original
        value.container = .automatic
        value.thumbnailBehavior = .none
        value.subtitleDelivery = .none
        value.bundleStyle = .mediaOnly
        return OutputCapabilityMatrix.normalized(value)
    }

    private func videoConfiguration() -> DownloadConfiguration {
        var value = DownloadConfiguration.standard
        value.mode = .videoOnly
        value.preset = .custom
        value.selectedVideoFormatID = "401"
        value.selectedAudioFormatID = nil
        value.videoCodec = .automatic
        value.audioCodec = .automatic
        value.container = .automatic
        value.thumbnailBehavior = .none
        value.subtitleDelivery = .none
        value.bundleStyle = .mediaOnly
        return OutputCapabilityMatrix.normalized(value)
    }

    private func combinedConfiguration() -> DownloadConfiguration {
        var value = DownloadConfiguration.standard
        value.mode = .videoAndAudio
        value.preset = .custom
        value.selectedVideoFormatID = "401"
        value.selectedAudioFormatID = "140"
        value.videoCodec = .automatic
        value.audioCodec = .automatic
        value.container = .automatic
        value.thumbnailBehavior = .none
        value.subtitleDelivery = .none
        value.bundleStyle = .mediaOnly
        return OutputCapabilityMatrix.normalized(value)
    }

    private func expectedChannelCount(
        _ choice: AudioChannelChoice
    ) -> Int? {
        switch choice {
        case .preserve: nil
        case .mono: 1
        case .stereo: 2
        }
    }

    private func HDRMetadata() -> MediaMetadata {
        let base = DeveloperFixtures.media
        let formats = base.formats.map { format in
            guard format.formatID == "401" else { return format }
            return MediaFormat(
                formatID: format.formatID,
                formatNote: format.formatNote,
                extension: format.extension,
                container: format.container,
                videoCodec: format.videoCodec,
                audioCodec: format.audioCodec,
                width: format.width,
                height: format.height,
                resolution: format.resolution,
                framesPerSecond: format.framesPerSecond,
                dynamicRange: "HDR10",
                isHDR: true,
                audioBitrateKbps: format.audioBitrateKbps,
                videoBitrateKbps: format.videoBitrateKbps,
                totalBitrateKbps: format.totalBitrateKbps,
                exactFileSizeBytes: format.exactFileSizeBytes,
                approximateFileSizeBytes: format.approximateFileSizeBytes,
                hasVideo: format.hasVideo,
                hasAudio: format.hasAudio,
                protocolName: format.protocolName,
                sourceType: format.sourceType,
                language: format.language
            )
        }
        return MediaMetadata(
            canonicalURL: base.canonicalURL,
            videoID: base.videoID,
            title: base.title,
            channel: base.channel,
            uploader: base.uploader,
            durationSeconds: base.durationSeconds,
            uploadDate: base.uploadDate,
            description: base.description,
            isLive: base.isLive,
            liveStatus: base.liveStatus,
            thumbnails: base.thumbnails,
            chapters: base.chapters,
            subtitles: base.subtitles,
            formats: formats
        )
    }

    private func portraitMetadata() -> MediaMetadata {
        qualityMetadata(
            formatNote: "1080p portrait",
            width: 1_080,
            height: 1_920,
            resolution: "1080x1920"
        )
    }

    private func qualityMetadata(
        formatNote: String?,
        width: Int?,
        height: Int?,
        resolution: String?
    ) -> MediaMetadata {
        let base = DeveloperFixtures.media
        let formats = base.formats.map { format in
            guard format.formatID == "401" else { return format }
            return MediaFormat(
                formatID: format.formatID,
                formatNote: formatNote,
                extension: format.extension,
                container: format.container,
                videoCodec: format.videoCodec,
                audioCodec: format.audioCodec,
                width: width,
                height: height,
                resolution: resolution,
                framesPerSecond: format.framesPerSecond,
                dynamicRange: format.dynamicRange,
                isHDR: format.isHDR,
                audioBitrateKbps: format.audioBitrateKbps,
                videoBitrateKbps: format.videoBitrateKbps,
                totalBitrateKbps: format.totalBitrateKbps,
                exactFileSizeBytes: format.exactFileSizeBytes,
                approximateFileSizeBytes: format.approximateFileSizeBytes,
                hasVideo: format.hasVideo,
                hasAudio: format.hasAudio,
                protocolName: format.protocolName,
                sourceType: format.sourceType,
                language: format.language
            )
        }
        return MediaMetadata(
            canonicalURL: base.canonicalURL,
            videoID: base.videoID,
            title: base.title,
            channel: base.channel,
            uploader: base.uploader,
            durationSeconds: base.durationSeconds,
            uploadDate: base.uploadDate,
            description: base.description,
            isLive: base.isLive,
            liveStatus: base.liveStatus,
            thumbnails: base.thumbnails,
            chapters: base.chapters,
            subtitles: base.subtitles,
            formats: formats
        )
    }
}
