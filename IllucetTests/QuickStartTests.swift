import Foundation
import Testing
@testable import Illucet

struct QuickStartTests {
    @Test
    func emptyQuickStartRecoveryRetainsAndReplacesExactIntent() throws {
        var recovery = QuickStartInputRecoveryState()
        var clipboardReads = 0
        var first = try #require(
            QuickStartPresetLibrary.legacyDefaults.first {
                $0.name == "MP3 Audio"
            }
        )
        first.launchBehavior = .immediate
        let replacement = try #require(
            QuickStartPresetLibrary.legacyDefaults.first {
                $0.name == "Video Only"
            }
        )

        #expect(
            QuickStartInputRecoveryState.requiresRecovery(for: "")
        )
        #expect(
            QuickStartInputRecoveryState.requiresRecovery(
                for: " \n\t "
            )
        )
        #expect(
            !QuickStartInputRecoveryState.requiresRecovery(
                for: " https://youtu.be/dQw4w9WgXcQ "
            )
        )
        #expect(clipboardReads == 0)

        recovery.begin(preset: first) {
            clipboardReads += 1
            return "https://youtu.be/dQw4w9WgXcQ"
        }
        #expect(clipboardReads == 1)
        #expect(recovery.pendingPreset == first)
        #expect(recovery.pendingPreset?.launchBehavior == .immediate)
        #expect(recovery.showsGuidance)
        #expect(recovery.offersClipboardContinuation)

        recovery.begin(preset: replacement) {
            clipboardReads += 1
            return "not a URL"
        }
        #expect(clipboardReads == 2)
        #expect(recovery.pendingPreset == replacement)
        #expect(recovery.showsGuidance)
        #expect(!recovery.offersClipboardContinuation)

        recovery.cancel()
        #expect(!recovery.isActive)
        #expect(!recovery.showsGuidance)
    }

    @Test
    func manualRecoveryConsumesRetainedPresetOnlyWhenAnalysisBegins() throws {
        var recovery = QuickStartInputRecoveryState()
        let preset = try #require(
            QuickStartPresetLibrary.legacyDefaults.first {
                $0.name == "Small Video"
            }
        )

        recovery.begin(preset: preset) { nil }
        recovery.URLTextDidChange(
            from: "   ",
            to: "https://youtu.be/dQw4w9WgXcQ"
        )
        #expect(recovery.pendingPreset == preset)
        #expect(!recovery.showsGuidance)
        #expect(!recovery.offersClipboardContinuation)

        let consumed = recovery.analysisDidBegin()
        #expect(consumed == preset)
        #expect(!recovery.isActive)
        #expect(recovery.analysisDidBegin() == nil)

        recovery.begin(preset: preset) { nil }
        recovery.URLTextDidChange(
            from: "https://youtu.be/dQw4w9WgXcQ",
            to: " \n "
        )
        #expect(!recovery.isActive)
    }

    @Test
    func clipboardContinuationRequiresOfferAndConsumesIntentOnce() throws {
        var recovery = QuickStartInputRecoveryState()
        let preset = try #require(
            QuickStartPresetLibrary.legacyDefaults.first {
                $0.name == "Compatible Video"
            }
        )
        var clipboardReads = 0

        recovery.begin(preset: preset) {
            clipboardReads += 1
            return "https://youtu.be/dQw4w9WgXcQ"
        }
        #expect(clipboardReads == 1)
        recovery.declineClipboardContinuation()
        #expect(recovery.pendingPreset == preset)
        #expect(!recovery.offersClipboardContinuation)
        #expect(
            recovery.acceptClipboardContinuation {
                clipboardReads += 1
                return "https://youtu.be/dQw4w9WgXcQ"
            } == nil
        )
        #expect(clipboardReads == 1)

        recovery.begin(preset: preset) {
            clipboardReads += 1
            return "https://youtu.be/dQw4w9WgXcQ"
        }
        let continuation = recovery.acceptClipboardContinuation {
            clipboardReads += 1
            return "  https://youtu.be/dQw4w9WgXcQ  "
        }
        #expect(clipboardReads == 3)
        #expect(continuation?.URLText == "https://youtu.be/dQw4w9WgXcQ")
        #expect(continuation?.preset == preset)
        #expect(!recovery.isActive)
        #expect(
            recovery.acceptClipboardContinuation {
                clipboardReads += 1
                return "https://youtu.be/dQw4w9WgXcQ"
            } == nil
        )
        #expect(clipboardReads == 3)
    }

    @Test
    func clipboardDetectionRejectsUnsupportedAndRetainsNoURLValue() throws {
        let preset = try #require(QuickStartPresetLibrary.legacyDefaults.first)
        var first = QuickStartInputRecoveryState()
        var second = QuickStartInputRecoveryState()
        var unsupported = QuickStartInputRecoveryState()

        first.begin(preset: preset) {
            "https://youtu.be/dQw4w9WgXcQ"
        }
        second.begin(preset: preset) {
            "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
        }
        unsupported.begin(preset: preset) {
            "https://example.com/not-supported"
        }

        #expect(first == second)
        #expect(first.offersClipboardContinuation)
        #expect(!unsupported.offersClipboardContinuation)
        #expect(unsupported.pendingPreset == preset)
    }

    @Test
    func legacyPresetsRemainUsableAsCustomPresets() throws {
        let presets = QuickStartPresetLibrary.legacyDefaults
        #expect(
            presets.map(\.name) == [
                "Best Video",
                "Compatible Video",
                "Small Video",
                "MP3 Audio",
                "Original Audio",
                "Video Only",
            ]
        )
        #expect(Set(presets.map(\.id)).count == presets.count)

        for preset in presets {
            let configuration = try preset.resolvedConfiguration(
                metadata: DeveloperFixtures.media
            )
            #expect(!configuration.selectedFormatIDs.isEmpty)
            try OutputCapabilityMatrix.validate(
                configuration,
                metadata: DeveloperFixtures.media
            )
            #expect(configuration.sponsorBlock == .disabled)
            #expect(configuration.subtitleDelivery == .none)
            #expect(!configuration.writeChapters)
            #expect(!configuration.splitChapters)
        }
    }

    @Test
    func MP3QuickStartResolvesOnlyAudioAndKeepsFullConfiguration() throws {
        let preset = try #require(
            QuickStartPresetLibrary.legacyDefaults.first {
                $0.name == "MP3 Audio"
            }
        )
        let resolved = try preset.resolvedConfiguration(
            metadata: DeveloperFixtures.media
        )

        #expect(resolved.mode == .audioOnly)
        #expect(resolved.audioCodec == .mp3)
        #expect(resolved.container == .mp3)
        #expect(resolved.audioBitrateKbps == 192)
        #expect(resolved.selectedVideoFormatID == nil)
        #expect(resolved.selectedAudioFormatID != nil)
        #expect(resolved.thumbnailBehavior == .separateAndEmbed)
        #expect(resolved.destination == .appDocuments)
        #expect(resolved.filenameTemplate == "{title}")
    }

    @Test
    func videoOnlyAndSmallPresetsCannotSelectWrongStreamTypes() throws {
        let videoOnly = try #require(
            QuickStartPresetLibrary.legacyDefaults.first {
                $0.name == "Video Only"
            }
        )
        let videoOnlyConfiguration = try videoOnly.resolvedConfiguration(
            metadata: DeveloperFixtures.media
        )
        #expect(videoOnlyConfiguration.mode == .videoOnly)
        #expect(videoOnlyConfiguration.selectedVideoFormatID != nil)
        #expect(videoOnlyConfiguration.selectedAudioFormatID == nil)

        let small = try #require(
            QuickStartPresetLibrary.legacyDefaults.first {
                $0.name == "Small Video"
            }
        )
        let smallConfiguration = try small.resolvedConfiguration(
            metadata: DeveloperFixtures.media
        )
        let selected = DeveloperFixtures.media.formats.first {
            $0.formatID == smallConfiguration.selectedVideoFormatID
        }
        #expect((selected?.pResolution ?? 0) <= 720)
    }

    @Test
    func incompatibleSavedFieldsNormalizeBeforeSelection() throws {
        var preset = try #require(QuickStartPresetLibrary.legacyDefaults.last)
        preset.configuration.mode = .audioOnly
        preset.configuration.videoCodec = .vp9
        preset.configuration.audioCodec = .flac
        preset.configuration.container = .webm
        preset.configuration.subtitleDelivery = .embed
        preset.configuration.splitChapters = true

        let resolved = try preset.resolvedConfiguration(
            metadata: DeveloperFixtures.media
        )

        #expect(resolved.mode == .audioOnly)
        #expect(resolved.videoCodec == .automatic)
        // FLAC became a verified Part 7 conversion target. Keep the now-valid
        // codec while still discarding the incompatible WebM container.
        #expect(resolved.audioCodec == .flac)
        #expect(resolved.container == .automatic)
        #expect(resolved.subtitleDelivery == .none)
        #expect(!resolved.splitChapters)
    }

    @Test
    func duplicateReorderDeleteAndResetAreDeterministic() throws {
        let source = try #require(QuickStartPresetLibrary.legacyDefaults.first)
        let duplicated = QuickStartPresetLibrary.duplicate(
            source,
            in: QuickStartPresetLibrary.legacyDefaults
        )
        #expect(duplicated.count == 7)
        #expect(duplicated[1].name == "Best Video Copy")
        #expect(duplicated[1].id != source.id)
        #expect(duplicated[1].configuration == source.configuration)

        let moved = QuickStartPresetLibrary.move(
            duplicated,
            fromOffsets: IndexSet(integer: 0),
            toOffset: duplicated.endIndex
        )
        #expect(moved.last?.id == source.id)

        let deleted = moved.filter { $0.id != source.id }
        #expect(deleted.count == 6)
        #expect(QuickStartPresetLibrary.legacyDefaults.count == 6)
    }

    @Test
    func legacySnapshotWithoutPresetsRestoresBuiltIns() throws {
        let encoded = try JSONEncoder.illucetEncoder.encode(IllucetSnapshot.empty)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object.removeValue(forKey: "quickStartPresets")
        object["schemaVersion"] = 1
        let legacy = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        let decoded = try JSONDecoder.illucetDecoder.decode(
            IllucetSnapshot.self,
            from: legacy
        )

        #expect(
            decoded.quickStartPresets == QuickStartPresetLibrary.defaults
        )
    }

    @Test
    func immediatePolicyStopsForEveryRequiredLocalBlocker() throws {
        let preset = try #require(
            QuickStartPresetLibrary.legacyDefaults.first {
                $0.name == "MP3 Audio"
            }
        )
        var configuration = try preset.resolvedConfiguration(
            metadata: DeveloperFixtures.media
        )

        configuration.destination = .askEveryTime
        #expect(throws: IllucetError.self) {
            try QuickStartLaunchPolicy.validate(
                configuration: configuration,
                metadata: DeveloperFixtures.media,
                hasFilesFolder: false,
                availableBytes: Int64.max,
                reserveBytes: 0
            )
        }

        configuration.destination = .filesFolder
        #expect(throws: IllucetError.filesDestinationUnavailable) {
            try QuickStartLaunchPolicy.validate(
                configuration: configuration,
                metadata: DeveloperFixtures.media,
                hasFilesFolder: false,
                availableBytes: Int64.max,
                reserveBytes: 0
            )
        }

        configuration.destination = .appDocuments
        #expect(throws: IllucetError.self) {
            try QuickStartLaunchPolicy.validate(
                configuration: configuration,
                metadata: DeveloperFixtures.media,
                hasFilesFolder: true,
                availableBytes: 1,
                reserveBytes: 0
            )
        }

        configuration.destination = .photos
        #expect(throws: IllucetError.photosIncompatible) {
            try QuickStartLaunchPolicy.validate(
                configuration: configuration,
                metadata: DeveloperFixtures.media,
                hasFilesFolder: true,
                availableBytes: Int64.max,
                reserveBytes: 0
            )
        }
    }

    @Test
    func recentLinkTimestampsUseMinuteOrLargerPrecision() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cases = [
            (0.0, "Just now"),
            (59.0, "Just now"),
            (180.0, "3 min ago"),
            (7_200.0, "2 hr ago"),
            (90_000.0, "Yesterday"),
            (345_600.0, "4 days ago"),
        ]
        for (secondsAgo, expected) in cases {
            #expect(
                RelativeTimestampFormatter.string(
                    from: now.addingTimeInterval(-secondsAgo),
                    relativeTo: now
                ) == expected
            )
        }
    }
}
