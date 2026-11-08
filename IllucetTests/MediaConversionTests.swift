import Foundation
import Testing
@testable import Illucet

struct MediaConversionTests {
    @Test
    func conversionCapabilitiesMatchPinnedNativeSurface() {
        #expect(
            ConversionCapabilityMatrix.audioCodecs == [
                .aac,
                .mp3,
                .flac,
                .alac,
                .opus,
                .vorbis,
                .wav,
            ]
        )
        #expect(
            ConversionCapabilityMatrix.selectableVideoCodecs
                == [.h264, .hevc]
        )
        for codec in ConversionCapabilityMatrix.audioCodecs {
            let capability = ConversionCapabilityMatrix.audio(codec)
            #expect(capability != nil)
            #expect(capability?.containers.isEmpty == false)
        }
        for codec in ConversionCapabilityMatrix.unavailableVideoCodecs {
            let capability = ConversionCapabilityMatrix.video(codec)
            #expect(capability?.isSelectable == false)
            #expect(capability?.unavailableReason?.isEmpty == false)
        }
    }

    @Test
    func nativeAudioCodecContainerMatrixProducesVerifiedOutputs() async throws {
        let root = try makeRoot("AudioMatrix")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let processor = NativeFFmpegMediaProcessor()

        for codec in ConversionCapabilityMatrix.audioCodecs {
            let capability = try #require(
                ConversionCapabilityMatrix.audio(codec)
            )
            for choice in capability.containers {
                let container = OutputCapabilityMatrix.mediaContainer(choice)
                let output = root.appending(
                    path: "\(codecID(codec))-\(containerID(choice)).\(fileExtension(choice, codec: codec))"
                )
                let settings = AudioEncodingSettings(
                    codec: capability.nativeCodec,
                    bitRate: capability.rateControls.contains(.bitRate)
                        ? 128_000
                        : nil,
                    quality: !capability.rateControls.contains(.bitRate)
                        && capability.rateControls.contains(.quality)
                        ? AudioEncodingQuality(value: 75)
                        : nil,
                    sampleRate: nil,
                    channelLayout: .preserve,
                    loudnessNormalization: nil
                )
                let result = try await processor.process(
                    request(
                        input: fixtures.audio,
                        output: output,
                        container: container,
                        settings: settings,
                        expectedExtension: output.pathExtension,
                        expectedSampleRate: 48_000,
                        expectedChannels: 2
                    )
                ) { _ in }

                #expect(result.probes.first?.audioStreamCount == 1)
                #expect(
                    result.probes.first?.verificationEvidence?
                        .verificationClass == .boundedStrong
                )
                #expect(
                    result.probes.first?.verificationEvidence?
                        .fullDecodePerformed == false
                )
                #expect(
                    result.probes.first?.streams.first(where: {
                        $0.kind == .audio
                    })?.decodedSampleWindows == 3
                )
                #expect(result.probes.first?.videoStreamCount == 0)
                #expect(
                    result.probes.first?.streams.first(where: {
                        $0.kind == .audio
                    })?.codecName.map {
                        capability.nativeCodec.matches(probeCodec: $0)
                    } == true,
                    "Wrong codec for \(codec.rawValue) in \(choice.rawValue)"
                )
            }
        }
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func productionAudioRequestsProduceEverySelectableOutput() async throws {
        let root = try makeRoot("ProductionAudioRequests")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let processor = NativeFFmpegMediaProcessor()
        let metadata = nativeMetadata()
        var appSettings = AppSettings.defaults
        appSettings.fastStartMP4 = true
        appSettings.preserveMetadata = true

        for codec in ConversionCapabilityMatrix.audioCodecs {
            let capability = try #require(
                ConversionCapabilityMatrix.audio(codec)
            )
            for choice in capability.containers {
                var configuration = DownloadConfiguration.standard
                configuration.mode = .audioOnly
                configuration.preset = .custom
                configuration.selectedVideoFormatID = nil
                configuration.selectedAudioFormatID = "140"
                configuration.videoCodec = .automatic
                configuration.audioCodec = codec
                configuration.container = choice
                configuration.thumbnailBehavior = .none
                configuration.subtitleDelivery = .none
                configuration.bundleStyle = .mediaOnly
                configuration = OutputCapabilityMatrix.normalized(
                    configuration
                )
                let plan = try OutputCapabilityMatrix.makePlan(
                    configuration: configuration,
                    metadata: metadata
                )
                let output = root.appending(
                    path: "production-\(codecID(codec))-\(containerID(choice)).\(fileExtension(choice, codec: codec))"
                )
                let value = try MediaConversionRequestBuilder(
                    plan: plan,
                    configuration: configuration,
                    metadata: metadata,
                    settings: appSettings
                ).request(
                    operationID: UUID(),
                    operation: .transcodeAudio(inputURL: fixtures.audio),
                    destination: output,
                    requireArtwork: false
                )

                let result: MediaProcessingResult
                do {
                    result = try await processor.process(value) { _ in }
                } catch {
                    Issue.record(
                        "Production \(codec.rawValue)/\(choice.rawValue) request failed: \(error)"
                    )
                    continue
                }

                #expect(result.probes.first?.audioStreamCount == 1)
                #expect(
                    result.probes.first?.streams.first(where: {
                        $0.kind == .audio
                    })?.codecName.map {
                        capability.nativeCodec.matches(probeCodec: $0)
                    } == true
                )
            }
        }
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func nativeQualityModesAreRealForSupportedEncoders() async throws {
        let root = try makeRoot("AudioQuality")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let processor = NativeFFmpegMediaProcessor()
        let cases: [
            (AudioCodecPreference, OutputContainerChoice)
        ] = [
            (.aac, .m4a),
            (.mp3, .mp3),
            (.vorbis, .ogg),
        ]

        for (codec, choice) in cases {
            let capability = try #require(
                ConversionCapabilityMatrix.audio(codec)
            )
            #expect(capability.rateControls.contains(.quality))
            for quality in AudioQualityChoice.allCases {
                let output = root.appending(
                    path: "quality-\(codecID(codec))-\(quality.nativeValue).\(fileExtension(choice, codec: codec))"
                )
                let result = try await processor.process(
                    request(
                        input: fixtures.audio,
                        output: output,
                        container:
                            OutputCapabilityMatrix.mediaContainer(choice),
                        settings: AudioEncodingSettings(
                            codec: capability.nativeCodec,
                            bitRate: nil,
                            quality: AudioEncodingQuality(
                                value: quality.nativeValue
                            ),
                            sampleRate: nil,
                            channelLayout: .preserve,
                            loudnessNormalization: nil
                        ),
                        expectedExtension: output.pathExtension,
                        expectedSampleRate: 48_000,
                        expectedChannels: 2
                    )
                ) { _ in }
                #expect(!result.usedStreamCopy)
            }
        }
    }

    @Test
    func nativeAudioControlsMetadataAndFastStartAreApplied() async throws {
        let root = try makeRoot("AudioControls")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let processor = NativeFFmpegMediaProcessor()
        let output = root.appending(path: "controlled.m4a")
        let metadata = MediaTagSet(
            title: "Part 7 title",
            artist: "Illucet channel",
            album: nil,
            albumArtist: nil,
            comment: nil,
            date: "20260729",
            genre: nil,
            language: nil,
            description: "Part 7 description",
            additional: [
                "source_url": "https://www.youtube.com/watch?v=fixture",
                "video_id": "fixture",
                "channel": "Illucet channel",
            ]
        )
        let settings = AudioEncodingSettings(
            codec: .aac,
            bitRate: 128_000,
            sampleRate: 44_100,
            channelLayout: .mono,
            loudnessNormalization: LoudnessNormalizationSettings(
                integratedLoudnessLUFS: -16,
                loudnessRangeLU: 11,
                truePeakDBTP: -1.5
            )
        )
        var value = request(
            input: fixtures.audio,
            output: output,
            container: .m4a,
            settings: settings,
            expectedExtension: "m4a",
            expectedSampleRate: 44_100,
            expectedChannels: 1
        )
        value = MediaProcessingRequest(
            operationID: value.operationID,
            operation: value.operation,
            destinationURL: value.destinationURL,
            output: value.output,
            metadata: metadata,
            chapters: value.chapters,
            trimming: value.trimming,
            overwriteExisting: value.overwriteExisting,
            verification: MediaVerificationRequirements(
                expectedContainer: .m4a,
                expectedFileExtension: "m4a",
                expectedVideoStreams: 0 ... 0,
                expectedAudioStreams: 1 ... 1,
                expectedSubtitleStreams: 0 ... 0,
                expectedVideoCodec: nil,
                expectedAudioCodec: .aac,
                expectedDimensions: nil,
                expectedFrameRate: nil,
                frameRateTolerance: 0.05,
                expectedHDR: nil,
                expectedAudioSampleRate: 44_100,
                expectedAudioChannelCount: 1,
                expectedDurationSeconds: 2,
                durationToleranceSeconds: 1,
                expectedAudioBitRate: 128_000,
                audioBitRateToleranceFraction: 0.20,
                expectedChapterCount: 0 ... 0,
                requireArtwork: false,
                requireMetadataKeys: ["title", "artist", "date"],
                expectedMetadataValues: [
                    "title": "Part 7 title",
                    "artist": "Illucet channel",
                    "date": "20260729",
                ],
                forbiddenMetadataKeys: [],
                requiredVerificationClass: .boundedStrong
            )
        )

        let result = try await processor.process(value) { _ in }

        #expect(result.appliedLoudnessNormalization)
        #expect(try hasFastStart(output))
        let playback = try await ApplePlaybackVerifier().verify(
            fileURL: output
        )
        #expect(playback.playbackAdvanceSeconds >= 0.2)
    }

    @Test
    func metadataRemovalDoesNotRetainSourceTags() async throws {
        let root = try makeRoot("MetadataRemoval")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let output = root.appending(path: "without-source-tags.m4a")
        let processor = NativeFFmpegMediaProcessor()
        let settings = AudioEncodingSettings(
            codec: .aac,
            bitRate: 128_000,
            sampleRate: nil,
            channelLayout: .preserve,
            loudnessNormalization: nil
        )
        let base = request(
            input: fixtures.audio,
            output: output,
            container: .m4a,
            settings: settings,
            expectedExtension: "m4a",
            expectedSampleRate: 48_000,
            expectedChannels: 2
        )
        let withoutMetadata = MediaProcessingRequest(
            operationID: base.operationID,
            operation: base.operation,
            destinationURL: base.destinationURL,
            output: MediaOutputSpecification(
                container: .m4a,
                video: .remove,
                audio: .encode(settings),
                dynamicRange: .preserve,
                subtitleCodec: nil,
                fastStart: true,
                preserveMetadata: false,
                preserveChapters: false
            ),
            metadata: .empty,
            chapters: [],
            trimming: nil,
            overwriteExisting: false,
            verification: MediaVerificationRequirements(
                expectedContainer: .m4a,
                expectedFileExtension: "m4a",
                expectedVideoStreams: 0 ... 0,
                expectedAudioStreams: 1 ... 1,
                expectedSubtitleStreams: 0 ... 0,
                expectedVideoCodec: nil,
                expectedAudioCodec: .aac,
                expectedDimensions: nil,
                expectedFrameRate: nil,
                frameRateTolerance: 0.05,
                expectedHDR: nil,
                expectedAudioSampleRate: 48_000,
                expectedAudioChannelCount: 2,
                expectedDurationSeconds: 2,
                durationToleranceSeconds: 0.25,
                expectedAudioBitRate: 128_000,
                audioBitRateToleranceFraction: 0.20,
                expectedChapterCount: 0 ... 0,
                requireArtwork: false,
                requireMetadataKeys: [],
                expectedMetadataValues: [:],
                forbiddenMetadataKeys: [
                    "title",
                    "artist",
                    "date",
                    "description",
                    "comment",
                    "source_url",
                    "video_id",
                    "channel",
                ],
                requiredVerificationClass: .boundedStrong
            )
        )

        _ = try await processor.process(withoutMetadata) { _ in }
    }

    @Test
    func nativeVideoCodecContainerMatrixProducesVerifiedOutputs() async throws {
        let root = try makeRoot("VideoMatrix")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let processor = NativeFFmpegMediaProcessor()

        for codec in ConversionCapabilityMatrix.selectableVideoCodecs {
            let capability = try #require(
                ConversionCapabilityMatrix.video(codec)
            )
            for choice in capability.containers {
                let container = OutputCapabilityMatrix.mediaContainer(choice)
                let output = root.appending(
                    path: "\(codecID(codec))-\(containerID(choice)).\(videoFileExtension(choice))"
                )
                let result = try await processor.process(
                    videoRequest(
                        input: fixtures.incompatible,
                        output: output,
                        container: container,
                        codec: capability.nativeCodec,
                        dimensions: MediaDimensions(width: 320, height: 180),
                        frameRate: 30
                    )
                ) { _ in }

                #expect(!result.usedStreamCopy)
                #expect(
                    result.probes.first?.verificationEvidence?
                        .verificationClass == .boundedStrong
                )
                #expect(
                    result.probes.first?.verificationEvidence?
                        .fullDecodePerformed == false
                )
                #expect(
                    result.probes.first?.streams.first(where: {
                        $0.kind == .video
                            && !$0.disposition.attachedPicture
                    })?.decodedSampleWindows == 3
                )
                #expect(result.usedHardwareAcceleration)
                #expect(!result.usedSoftwareFallback)
                #expect(result.videoEncoderName == capability.encoderName)
                #expect(
                    result.probes.first?.streams.first(where: {
                        $0.kind == .video
                            && !$0.disposition.attachedPicture
                    })?.codecName.map {
                        capability.nativeCodec.matches(probeCodec: $0)
                    } == true
                )
            }
        }
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func nativeCombinedSelectableMatrixProducesVerifiedOutputs() async throws {
        let root = try makeRoot("CombinedMatrix")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let processor = NativeFFmpegMediaProcessor()
        var videoStages: [String: URL] = [:]
        var audioStages: [String: URL] = [:]

        for videoCodec in ConversionCapabilityMatrix.selectableVideoCodecs {
            let videoCapability = try #require(
                ConversionCapabilityMatrix.video(videoCodec)
            )
            for audioCodec in ConversionCapabilityMatrix.audioCodecs {
                let audioCapability = try #require(
                    ConversionCapabilityMatrix.audio(audioCodec)
                )
                let containers = OutputCapabilityMatrix.enabledContainers(
                    for: .videoAndAudio,
                    audioCodec: audioCodec,
                    videoCodec: videoCodec
                ).filter { $0 != .automatic }
                for choice in containers {
                    let container =
                        OutputCapabilityMatrix.mediaContainer(choice)
                    let suffix = videoFileExtension(choice)
                    let videoKey =
                        "\(codecID(videoCodec))-\(containerID(choice))"
                    let videoStage: URL
                    if let cached = videoStages[videoKey] {
                        videoStage = cached
                    } else {
                        videoStage = root.appending(
                            path: "stage-video-\(videoKey).\(suffix)"
                        )
                        _ = try await processor.process(
                            videoRequest(
                                input: fixtures.incompatible,
                                output: videoStage,
                                container: container,
                                codec: videoCapability.nativeCodec,
                                dimensions: MediaDimensions(
                                    width: 320,
                                    height: 180
                                ),
                                frameRate: 30,
                                copyAudio: false
                            )
                        ) { _ in }
                        videoStages[videoKey] = videoStage
                    }

                    let audioKey =
                        "\(codecID(audioCodec))-\(containerID(choice))"
                    let audioStage: URL
                    if let cached = audioStages[audioKey] {
                        audioStage = cached
                    } else {
                        audioStage = root.appending(
                            path: "stage-audio-\(audioKey).\(suffix)"
                        )
                        _ = try await processor.process(
                            request(
                                input: fixtures.audio,
                                output: audioStage,
                                container: container,
                                settings: AudioEncodingSettings(
                                    codec: audioCapability.nativeCodec,
                                    bitRate: audioCapability.rateControls
                                        .contains(.bitRate)
                                        ? 128_000
                                        : nil,
                                    quality: !audioCapability.rateControls
                                        .contains(.bitRate)
                                        && audioCapability.rateControls
                                            .contains(.quality)
                                        ? AudioEncodingQuality(value: 75)
                                        : nil,
                                    sampleRate: nil,
                                    channelLayout: .preserve,
                                    loudnessNormalization: nil
                                ),
                                expectedExtension: suffix,
                                expectedSampleRate: 48_000,
                                expectedChannels: 2
                            )
                        ) { _ in }
                        audioStages[audioKey] = audioStage
                    }

                    let output = root.appending(
                        path: "combined-\(videoKey)-\(codecID(audioCodec)).\(suffix)"
                    )
                    let result = try await processor.process(
                        mergeRequest(
                            video: videoStage,
                            audio: audioStage,
                            output: output,
                            container: container,
                            videoCodec: videoCapability.nativeCodec,
                            audioCodec: audioCapability.nativeCodec
                        )
                    ) { _ in }
                    #expect(result.probes.first?.videoStreamCount == 1)
                    #expect(result.probes.first?.audioStreamCount == 1)
                }
            }
        }
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func nativeVideoResolutionAndFrameRateControlsAreReal() async throws {
        let root = try makeRoot("VideoControls")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let output = root.appending(path: "scaled-60fps.mp4")
        let result = try await NativeFFmpegMediaProcessor().process(
            videoRequest(
                input: fixtures.incompatible,
                output: output,
                container: .mp4,
                codec: .h264,
                dimensions: MediaDimensions(width: 160, height: 90),
                frameRate: 60
            )
        ) { _ in }

        let video = result.probes.first?.streams.first(where: {
            $0.kind == .video && !$0.disposition.attachedPicture
        })?.video
        #expect(video?.width == 160)
        #expect(video?.height == 90)
        #expect(result.usedHardwareAcceleration)
        #expect(result.videoEncoderName == "h264_videotoolbox")
        #expect(try hasFastStart(output))
    }

    @Test
    func nativeEverySelectableFrameRateIsApplied() async throws {
        let root = try makeRoot("VideoFrameRates")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let processor = NativeFFmpegMediaProcessor()
        for choice in ConversionCapabilityMatrix.frameRates {
            let expected = choice.value ?? 30
            let output = root.appending(
                path: "frame-rate-\(choice.rawValue.replacingOccurrences(of: " ", with: "-")).mp4"
            )
            let result = try await processor.process(
                videoRequest(
                    input: fixtures.incompatible,
                    output: output,
                    container: .mp4,
                    codec: .h264,
                    dimensions: MediaDimensions(width: 320, height: 180),
                    frameRate: choice.value
                )
            ) { _ in }
            let actual = result.probes.first?.streams.first(where: {
                $0.kind == .video && !$0.disposition.attachedPicture
            })?.video?.averageFrameRate?.doubleValue
            #expect(
                actual.map { abs($0 - expected) < 0.05 } == true,
                "Frame-rate request \(choice.rawValue) was not applied."
            )
        }
    }

    @Test
    func nativeHEVCPreservesDeterministicHDR() async throws {
        let root = try makeRoot("HDRPreserve")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "hdr-source.mp4")
        try generateHDRFixture(at: input)
        let processor = NativeFFmpegMediaProcessor()
        let source = try await processor.probeFullyDecoding(input)
        #expect(source.streams.first(where: {
            $0.kind == .video
        })?.video?.isHDR == true)

        let output = root.appending(path: "hdr-preserved.mp4")
        let result = try await processor.process(
            videoRequest(
                input: input,
                output: output,
                container: .mp4,
                codec: .hevc,
                dimensions: MediaDimensions(width: 320, height: 180),
                frameRate: 30,
                expectedHDR: true
            )
        ) { _ in }

        let video = result.probes.first?.streams.first(where: {
            $0.kind == .video && !$0.disposition.attachedPicture
        })?.video
        #expect(video?.isHDR == true)
        #expect(video?.colorTransfer == "smpte2084")
        #expect(video?.colorPrimaries == "bt2020")
        #expect(result.usedHardwareAcceleration)
        #expect(result.videoEncoderName == "hevc_videotoolbox")
    }

    @Test
    func nativeArtworkBeyondMP3MatchesExposedContainers() async throws {
        let root = try makeRoot("ArtworkMatrix")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let processor = NativeFFmpegMediaProcessor()
        let codecs: [AudioCodecPreference] = [.aac, .alac, .flac]

        for codec in codecs {
            let capability = try #require(
                ConversionCapabilityMatrix.audio(codec)
            )
            for choice in capability.supportsArtworkIn {
                let container = OutputCapabilityMatrix.mediaContainer(choice)
                let suffix = fileExtension(choice, codec: codec)
                let plain = root.appending(
                    path: "plain-\(codecID(codec))-\(containerID(choice)).\(suffix)"
                )
                let settings = AudioEncodingSettings(
                    codec: capability.nativeCodec,
                    bitRate: capability.isLossless ? nil : 128_000,
                    sampleRate: nil,
                    channelLayout: .preserve,
                    loudnessNormalization: nil
                )
                _ = try await processor.process(
                    request(
                        input: fixtures.audio,
                        output: plain,
                        container: container,
                        settings: settings,
                        expectedExtension: suffix,
                        expectedSampleRate: 48_000,
                        expectedChannels: 2
                    )
                ) { _ in }

                let covered = root.appending(
                    path: "covered-\(codecID(codec))-\(containerID(choice)).\(suffix)"
                )
                let result = try await processor.process(
                    artworkRequest(
                        media: plain,
                        artwork: fixtures.artwork,
                        output: covered,
                        container: container,
                        codec: capability.nativeCodec
                    )
                ) { _ in }
                #expect(result.probes.first?.streams.count(where: {
                    $0.disposition.attachedPicture
                }) == 1)
            }
        }
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func requestBuilderMetadataSurvivesVerifiedArtworkOutput() async throws {
        let root = try makeRoot("MetadataArtwork")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let processor = NativeFFmpegMediaProcessor()
        let metadata = nativeMetadata()
        var configuration = DownloadConfiguration.standard
        configuration.mode = .audioOnly
        configuration.preset = .custom
        configuration.selectedVideoFormatID = nil
        configuration.selectedAudioFormatID = "140"
        configuration.audioCodec = .aac
        configuration.container = .m4a
        configuration.audioBitrateKbps = 128
        configuration.thumbnailBehavior = .embed
        configuration = OutputCapabilityMatrix.normalized(configuration)
        let plan = try OutputCapabilityMatrix.makePlan(
            configuration: configuration,
            metadata: metadata
        )
        var settings = AppSettings.defaults
        settings.preserveMetadata = true
        settings.fastStartMP4 = true
        let builder = MediaConversionRequestBuilder(
            plan: plan,
            configuration: configuration,
            metadata: metadata,
            settings: settings
        )

        let plain = root.appending(path: "metadata-plain.m4a")
        let transcodeRequest = try builder.request(
            operationID: UUID(),
            operation: .transcodeAudio(inputURL: fixtures.audio),
            destination: plain,
            requireArtwork: false
        )
        #expect(
            transcodeRequest.verification.requiredVerificationClass
                == .boundedStrong
        )
        let transcodeResult = try await processor.process(
            transcodeRequest
        ) { _ in }
        #expect(
            transcodeResult.probes.first?.verificationEvidence?
                .verificationClass == .boundedStrong
        )
        let covered = root.appending(path: "metadata-covered.m4a")
        let artworkRequest = try builder.request(
            operationID: UUID(),
            operation: .attachArtwork(
                mediaURL: plain,
                artworkURL: fixtures.artwork
            ),
            destination: covered,
            requireArtwork: true
        )
        #expect(
            artworkRequest.verification.requiredVerificationClass
                == .boundedStrong
        )
        let result = try await processor.process(artworkRequest) { _ in }
        #expect(
            result.probes.first?.verificationEvidence?.verificationClass
                == .boundedStrong
        )

        #expect(
            result.probes.first?.metadata["comment"]?.contains(
                metadata.canonicalURL.absoluteString
            ) == true
        )
        #expect(try hasFastStart(covered))
    }

    @Test
    func typedStreamCopyPreservesAndRemovesRequestedMetadata() async throws {
        let root = try makeRoot("StreamCopyMetadata")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let processor = NativeFFmpegMediaProcessor()
        let combined = root.appending(path: "stream-copy-source.mp4")
        _ = try await processor.process(
            mergeRequest(
                video: fixtures.video,
                audio: fixtures.audio,
                output: combined,
                container: .mp4,
                videoCodec: MediaCodec(rawValue: "mpeg4"),
                audioCodec: .aac
            )
        ) { _ in }

        let metadata = nativeMetadata()
        let preservingPolicy = ConversionMetadataPolicy(
            metadata: metadata,
            preserve: true,
            container: .mp4
        )
        let tagged = root.appending(path: "stream-copy-tagged.mp4")
        _ = try await processor.process(
            streamCopyMetadataRequest(
                input: combined,
                output: tagged,
                tags: preservingPolicy.tags,
                preserveMetadata: true,
                requiredKeys: preservingPolicy.requiredKeys,
                expectedValues: preservingPolicy.expectedValues,
                forbiddenKeys: []
            )
        ) { _ in }
        #expect(try hasFastStart(tagged))

        let removalPolicy = ConversionMetadataPolicy(
            metadata: metadata,
            preserve: false,
            container: .mp4
        )
        let removed = root.appending(path: "stream-copy-removed.mp4")
        _ = try await processor.process(
            streamCopyMetadataRequest(
                input: tagged,
                output: removed,
                tags: .empty,
                preserveMetadata: false,
                requiredKeys: [],
                expectedValues: [:],
                forbiddenKeys: removalPolicy.forbiddenKeys
            )
        ) { _ in }
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func unavailableVideoRequestsFailClosedBeforePublishing() async throws {
        let root = try makeRoot("VideoFailClosed")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let processor = NativeFFmpegMediaProcessor()
        let cases: [(String, MediaCodec, MediaContainer, DynamicRangePolicy)] = [
            ("vp9", .vp9, .webM, .preserve),
            ("av1", .av1, .webM, .preserve),
            ("h264-webm", .h264, .webM, .preserve),
            ("hdr-to-sdr", .hevc, .mp4, .convertToSDR),
        ]

        for (name, codec, container, dynamicRange) in cases {
            let output = root.appending(path: "\(name).media")
            let value = videoRequest(
                input: fixtures.incompatible,
                output: output,
                container: container,
                codec: codec,
                dimensions: nil,
                frameRate: nil,
                dynamicRange: dynamicRange
            )
            do {
                _ = try await processor.process(value) { _ in }
                Issue.record("\(name) was incorrectly published.")
            } catch is MediaProcessorError {
                #expect(!FileManager.default.fileExists(atPath: output.path))
            }
        }
        let softwareOutput = root.appending(path: "software-only.mp4")
        do {
            _ = try await processor.process(
                videoRequest(
                    input: fixtures.incompatible,
                    output: softwareOutput,
                    container: .mp4,
                    codec: .h264,
                    dimensions: nil,
                    frameRate: nil,
                    acceleration: .softwareOnly
                )
            ) { _ in }
            Issue.record("Unavailable software fallback was published.")
        } catch is MediaProcessorError {
            #expect(
                !FileManager.default.fileExists(
                    atPath: softwareOutput.path
                )
            )
        }
        #expect(try partialFiles(in: root).isEmpty)
    }

    private func request(
        input: URL,
        output: URL,
        container: MediaContainer,
        settings: AudioEncodingSettings,
        expectedExtension: String,
        expectedSampleRate: Int,
        expectedChannels: Int
    ) -> MediaProcessingRequest {
        MediaProcessingRequest(
            operationID: UUID(),
            operation: .transcodeAudio(inputURL: input),
            destinationURL: output,
            output: MediaOutputSpecification(
                container: container,
                video: .remove,
                audio: .encode(settings),
                dynamicRange: .preserve,
                subtitleCodec: nil,
                fastStart: true,
                preserveMetadata: true,
                preserveChapters: false
            ),
            metadata: .empty,
            chapters: [],
            trimming: nil,
            overwriteExisting: false,
            verification: MediaVerificationRequirements(
                expectedContainer: container,
                expectedFileExtension: expectedExtension,
                expectedVideoStreams: 0 ... 0,
                expectedAudioStreams: 1 ... 1,
                expectedSubtitleStreams: 0 ... 0,
                expectedVideoCodec: nil,
                expectedAudioCodec: settings.codec,
                expectedDimensions: nil,
                expectedFrameRate: nil,
                frameRateTolerance: 0.05,
                expectedHDR: nil,
                expectedAudioSampleRate: expectedSampleRate,
                expectedAudioChannelCount: expectedChannels,
                expectedDurationSeconds: 2,
                durationToleranceSeconds: 0.25,
                expectedAudioBitRate: nil,
                audioBitRateToleranceFraction: 0.20,
                expectedChapterCount: 0 ... 0,
                requireArtwork: false,
                requireMetadataKeys: [],
                expectedMetadataValues: [:],
                forbiddenMetadataKeys: [],
                requiredVerificationClass: .boundedStrong
            )
        )
    }

    private func videoRequest(
        input: URL,
        output: URL,
        container: MediaContainer,
        codec: MediaCodec,
        dimensions: MediaDimensions?,
        frameRate: Double?,
        dynamicRange: DynamicRangePolicy = .preserve,
        expectedHDR: Bool? = nil,
        copyAudio: Bool = true,
        acceleration: HardwareAccelerationPolicy = .preferVideoToolbox
    ) -> MediaProcessingRequest {
        MediaProcessingRequest(
            operationID: UUID(),
            operation: .transcodeVideo(inputURL: input),
            destinationURL: output,
            output: MediaOutputSpecification(
                container: container,
                video: .encode(
                    VideoEncodingSettings(
                        codec: codec,
                        bitRate: nil,
                        dimensions: dimensions,
                        frameRate: frameRate,
                        pixelFormat: nil,
                        profile: nil,
                        level: nil,
                        acceleration: acceleration
                    )
                ),
                audio: copyAudio ? .copy : .remove,
                dynamicRange: dynamicRange,
                subtitleCodec: nil,
                fastStart: true,
                preserveMetadata: true,
                preserveChapters: false
            ),
            metadata: .empty,
            chapters: [],
            trimming: nil,
            overwriteExisting: false,
            verification: MediaVerificationRequirements(
                expectedContainer: container,
                expectedFileExtension: output.pathExtension,
                expectedVideoStreams: 1 ... 1,
                expectedAudioStreams: copyAudio ? 1 ... 1 : 0 ... 0,
                expectedSubtitleStreams: 0 ... 0,
                expectedVideoCodec: codec,
                expectedAudioCodec: copyAudio ? .aac : nil,
                expectedDimensions: dimensions
                    ?? MediaDimensions(width: 320, height: 180),
                expectedFrameRate: frameRate ?? 30,
                frameRateTolerance: 0.05,
                expectedHDR: expectedHDR
                    ?? (dynamicRange == .convertToSDR ? false : nil),
                expectedAudioSampleRate: copyAudio ? 48_000 : nil,
                expectedAudioChannelCount: copyAudio ? 2 : nil,
                expectedDurationSeconds: 2,
                durationToleranceSeconds: 0.25,
                expectedAudioBitRate: nil,
                audioBitRateToleranceFraction: 0.20,
                expectedChapterCount: 0 ... 0,
                requireArtwork: false,
                requireMetadataKeys: [],
                expectedMetadataValues: [:],
                forbiddenMetadataKeys: [],
                requiredVerificationClass: .boundedStrong
            )
        )
    }

    private func mergeRequest(
        video: URL,
        audio: URL,
        output: URL,
        container: MediaContainer,
        videoCodec: MediaCodec,
        audioCodec: MediaCodec
    ) -> MediaProcessingRequest {
        MediaProcessingRequest(
            operationID: UUID(),
            operation: .merge(videoURL: video, audioURL: audio),
            destinationURL: output,
            output: MediaOutputSpecification(
                container: container,
                video: .copy,
                audio: .copy,
                dynamicRange: .preserve,
                subtitleCodec: nil,
                fastStart: true,
                preserveMetadata: true,
                preserveChapters: false
            ),
            metadata: .empty,
            chapters: [],
            trimming: nil,
            overwriteExisting: false,
            verification: MediaVerificationRequirements(
                expectedContainer: container,
                expectedFileExtension: output.pathExtension,
                expectedVideoStreams: 1 ... 1,
                expectedAudioStreams: 1 ... 1,
                expectedSubtitleStreams: 0 ... 0,
                expectedVideoCodec: videoCodec,
                expectedAudioCodec: audioCodec,
                expectedDimensions: MediaDimensions(
                    width: 320,
                    height: 180
                ),
                expectedFrameRate: 30,
                frameRateTolerance: 0.05,
                expectedHDR: nil,
                expectedAudioSampleRate: 48_000,
                expectedAudioChannelCount: 2,
                expectedDurationSeconds: 2,
                durationToleranceSeconds: 0.25,
                expectedAudioBitRate: nil,
                audioBitRateToleranceFraction: 0.20,
                expectedChapterCount: 0 ... 0,
                requireArtwork: false,
                requireMetadataKeys: [],
                expectedMetadataValues: [:],
                forbiddenMetadataKeys: [],
                requiredVerificationClass: .fastStructural
            )
        )
    }

    private func streamCopyMetadataRequest(
        input: URL,
        output: URL,
        tags: MediaTagSet,
        preserveMetadata: Bool,
        requiredKeys: Set<String>,
        expectedValues: [String: String],
        forbiddenKeys: Set<String>
    ) -> MediaProcessingRequest {
        MediaProcessingRequest(
            operationID: UUID(),
            operation: .remux(inputURL: input),
            destinationURL: output,
            output: MediaOutputSpecification(
                container: .mp4,
                video: .copy,
                audio: .copy,
                dynamicRange: .preserve,
                subtitleCodec: nil,
                fastStart: true,
                preserveMetadata: preserveMetadata,
                preserveChapters: false
            ),
            metadata: tags,
            chapters: [],
            trimming: nil,
            overwriteExisting: false,
            verification: MediaVerificationRequirements(
                expectedContainer: .mp4,
                expectedFileExtension: "mp4",
                expectedVideoStreams: 1 ... 1,
                expectedAudioStreams: 1 ... 1,
                expectedSubtitleStreams: 0 ... 0,
                expectedVideoCodec: MediaCodec(rawValue: "mpeg4"),
                expectedAudioCodec: .aac,
                expectedDimensions: MediaDimensions(
                    width: 320,
                    height: 180
                ),
                expectedFrameRate: 30,
                frameRateTolerance: 0.05,
                expectedHDR: false,
                expectedAudioSampleRate: 48_000,
                expectedAudioChannelCount: 2,
                expectedDurationSeconds: 2,
                durationToleranceSeconds: 0.25,
                expectedAudioBitRate: nil,
                audioBitRateToleranceFraction: 0.20,
                expectedChapterCount: 0 ... 0,
                requireArtwork: false,
                requireMetadataKeys: requiredKeys,
                expectedMetadataValues: expectedValues,
                forbiddenMetadataKeys: forbiddenKeys,
                requiredVerificationClass: .fastStructural
            )
        )
    }

    private func artworkRequest(
        media: URL,
        artwork: URL,
        output: URL,
        container: MediaContainer,
        codec: MediaCodec
    ) -> MediaProcessingRequest {
        MediaProcessingRequest(
            operationID: UUID(),
            operation: .attachArtwork(
                mediaURL: media,
                artworkURL: artwork
            ),
            destinationURL: output,
            output: MediaOutputSpecification(
                container: container,
                video: .copy,
                audio: .copy,
                dynamicRange: .preserve,
                subtitleCodec: nil,
                fastStart: true,
                preserveMetadata: true,
                preserveChapters: false
            ),
            metadata: .empty,
            chapters: [],
            trimming: nil,
            overwriteExisting: false,
            verification: MediaVerificationRequirements(
                expectedContainer: container,
                expectedFileExtension: output.pathExtension,
                expectedVideoStreams: 0 ... 0,
                expectedAudioStreams: 1 ... 1,
                expectedSubtitleStreams: 0 ... 0,
                expectedVideoCodec: nil,
                expectedAudioCodec: codec,
                expectedDimensions: nil,
                expectedFrameRate: nil,
                frameRateTolerance: 0.05,
                expectedHDR: nil,
                expectedAudioSampleRate: 48_000,
                expectedAudioChannelCount: 2,
                expectedDurationSeconds: 2,
                durationToleranceSeconds: 0.25,
                expectedAudioBitRate: nil,
                audioBitRateToleranceFraction: 0.20,
                expectedChapterCount: 0 ... 0,
                requireArtwork: true,
                requireMetadataKeys: [],
                expectedMetadataValues: [:],
                forbiddenMetadataKeys: [],
                requiredVerificationClass: .fastStructural
            )
        )
    }

    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part7-\(name)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func generateFixtures(
        in root: URL
    ) throws -> (
        video: URL,
        audio: URL,
        incompatible: URL,
        artwork: URL
    ) {
        let video = root.appending(path: "video.mp4")
        let audio = root.appending(path: "audio.m4a")
        let incompatible = root.appending(path: "incompatible.mkv")
        let artwork = root.appending(path: "artwork.jpg")
        var rawError: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(rawError) }
        let status = video.path.withCString { videoPath in
            audio.path.withCString { audioPath in
                incompatible.path.withCString { incompatiblePath in
                    artwork.path.withCString { artworkPath in
                        illucet_ffmpeg_generate_fixtures(
                            videoPath,
                            audioPath,
                            incompatiblePath,
                            artworkPath,
                            nil,
                            &rawError
                        )
                    }
                }
            }
        }
        guard status == ILLUCET_FFMPEG_OK else {
            throw MediaProcessorError.nativeFailure(
                rawError.map { String(cString: $0) }
                    ?? "Fixture generation failed."
            )
        }
        return (video, audio, incompatible, artwork)
    }

    private func generateHDRFixture(at output: URL) throws {
        var rawError: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(rawError) }
        let status = output.path.withCString {
            illucet_ffmpeg_generate_hdr_fixture(
                $0,
                nil,
                &rawError
            )
        }
        guard status == ILLUCET_FFMPEG_OK else {
            throw MediaProcessorError.nativeFailure(
                rawError.map { String(cString: $0) }
                    ?? "HDR fixture generation failed."
            )
        }
    }

    private func nativeMetadata() -> MediaMetadata {
        let base = DeveloperFixtures.media
        return MediaMetadata(
            canonicalURL: base.canonicalURL,
            videoID: base.videoID,
            title: base.title,
            channel: base.channel,
            uploader: base.uploader,
            durationSeconds: 2,
            uploadDate: base.uploadDate,
            description: base.description,
            isLive: false,
            liveStatus: nil,
            thumbnails: base.thumbnails,
            chapters: [],
            subtitles: [],
            formats: base.formats
        )
    }

    private func codecID(_ codec: AudioCodecPreference) -> String {
        codec.rawValue.lowercased().replacingOccurrences(
            of: " ",
            with: "-"
        )
    }

    private func codecID(_ codec: VideoCodecPreference) -> String {
        codec.rawValue.lowercased().replacingOccurrences(
            of: " ",
            with: "-"
        )
    }

    private func containerID(_ container: OutputContainerChoice) -> String {
        container.rawValue.lowercased()
    }

    private func fileExtension(
        _ container: OutputContainerChoice,
        codec: AudioCodecPreference
    ) -> String {
        switch container {
        case .m4a: "m4a"
        case .mov: "mov"
        case .mp4: "mp4"
        case .mkv: "mka"
        case .webm: "webm"
        case .mp3: "mp3"
        case .opus: "opus"
        case .ogg: "ogg"
        case .flac: "flac"
        case .wav: "wav"
        case .alac:
            codec == .alac ? "m4a" : "media"
        case .automatic:
            "media"
        }
    }

    private func videoFileExtension(
        _ container: OutputContainerChoice
    ) -> String {
        switch container {
        case .mp4: "mp4"
        case .mov: "mov"
        case .mkv: "mkv"
        default: "media"
        }
    }

    private func partialFiles(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.contains("illucet-partial")
        }
    }

    private func hasFastStart(_ URL: URL) throws -> Bool {
        let data = try Data(contentsOf: URL)
        guard
            let moov = data.range(of: Data("moov".utf8))?.lowerBound,
            let mediaData = data.range(of: Data("mdat".utf8))?.lowerBound
        else {
            return false
        }
        return moov < mediaData
    }
}
