import CryptoKit
import Foundation

struct LiveExtractionValidation: Equatable, Sendable {
    let identityIsValid: Bool
    let thumbnailIsValid: Bool
    let formatsAreValid: Bool
    let providerPathIsValid: Bool
    let expectedVideoID: String?
    let issues: [String]
}

enum SubtitleMetadataContract {
    static let maximumTrackCount = 1_000
    static let maximumFormatsPerTrack = 1_000
    static let maximumURLBytes = 4_096

    static func violation(
        in tracks: [MediaSubtitleTrack]
    ) -> String? {
        guard tracks.count <= maximumTrackCount else {
            return "subtitle track count"
        }

        var trackIDs: Set<String> = []
        var formatIDs: Set<String> = []
        for track in tracks {
            guard
                isIdentity(track.trackID, prefix: "subtitle-"),
                trackIDs.insert(track.trackID).inserted
            else {
                return "subtitle track identity"
            }
            guard
                isRequiredText(track.language, maximum: 128),
                isOptionalText(track.name, maximum: 256)
            else {
                return "subtitle track text"
            }
            guard
                !track.formats.isEmpty,
                track.formats.count <= maximumFormatsPerTrack
            else {
                return "subtitle format count"
            }

            var trackURLs: Set<String> = []
            for format in track.formats {
                guard
                    isIdentity(
                        format.formatID,
                        prefix: "subtitle-format-"
                    ),
                    formatIDs.insert(format.formatID).inserted
                else {
                    return "subtitle format identity"
                }
                guard
                    isOptionalText(format.extension, maximum: 32),
                    isOptionalText(format.name, maximum: 256)
                else {
                    return "subtitle format text"
                }
                let rawURL = format.url.absoluteString
                guard
                    isSafeTransportURL(format.url),
                    trackURLs.insert(rawURL).inserted
                else {
                    return "subtitle transport URL"
                }
            }
        }
        return nil
    }

    private static func isIdentity(
        _ value: String,
        prefix: String
    ) -> Bool {
        guard value.hasPrefix(prefix) else {
            return false
        }
        let digest = value.dropFirst(prefix.count)
        return digest.utf8.count == 24 &&
            digest.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    private static func isRequiredText(
        _ value: String,
        maximum: Int
    ) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            value.utf8.count <= maximum
    }

    private static func isOptionalText(
        _ value: String?,
        maximum: Int
    ) -> Bool {
        guard let value else {
            return true
        }
        return isRequiredText(value, maximum: maximum)
    }

    private static func isSafeTransportURL(_ url: URL) -> Bool {
        let rawURL = url.absoluteString
        guard
            rawURL.utf8.count <= maximumURLBytes,
            rawURL == rawURL.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !rawURL.contains("\\"),
            !rawURL.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0) ||
                    $0.value < 0x20
            }),
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ),
            components.scheme?.lowercased() == "https",
            components.user == nil,
            components.password == nil,
            let host = components.host,
            !host.isEmpty,
            components.port != 0
        else {
            return false
        }
        return true
    }
}

/// Expected evidence comes from the verified generation selected at startup,
/// never from the metadata response being validated.
struct LiveExtractorContract: Decodable, Sendable {
    let ytDLP: String
    let ejs: String
    let quickJS: String
    let ejsCoreSHA3512: String
    let ejsLibrarySHA3512: String

    static let bundled = LiveExtractorContract(
        ytDLP: DependencyVersions.ytDLP, ejs: DependencyVersions.ejs,
        quickJS: DependencyVersions.quickJS,
        ejsCoreSHA3512: LiveExtractionValidator.expectedEJSCoreSHA3512,
        ejsLibrarySHA3512: LiveExtractionValidator.expectedEJSLibrarySHA3512)
}

enum LiveExtractionValidator {
    static let expectedYTDLPVersion = DependencyVersions.ytDLP
    static let expectedEJSVersion = DependencyVersions.ejs
    static let expectedQuickJSVersion = DependencyVersions.quickJS
    static let expectedEJSCoreSHA3512 =
        "ee5b307d07f55e91e4723edf5ac205cc877a474187849d757dc1322e38427b1"
        + "57a9d706d510c1723d3670f98e5a3f8cbcde77874a80406bd7204bc9fea30f283"
    static let expectedEJSLibrarySHA3512 =
        "8420c259ad16e99ce004e4651ac1bcabb53b4457bf5668a97a9359be9a998a7"
        + "89fee8ab124ee17f91a2ea8fd84e0f2b2fc8eabcaf0b16a186ba734cf422ad053"

    static func validate(
        _ extraction: LiveMetadataExtraction,
        requestedURL: URL,
        contract: LiveExtractorContract = .bundled
    ) -> LiveExtractionValidation {
        let metadata = extraction.metadata
        let evidence = extraction.providerEvidence
        let expectedID = youtubeVideoID(from: requestedURL)
        let expectedCanonicalURL = expectedID.flatMap {
            URL(string: "https://www.youtube.com/watch?v=\($0)")
        }
        var issues: [String] = []

        let identityIsValid =
            !metadata.videoID.isEmpty &&
            expectedID.map { $0 == metadata.videoID } != false &&
            !metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty &&
            metadata.title.utf8.count <= 512 &&
            (metadata.channel?.utf8.count ?? 0) <= 512 &&
            (metadata.uploader?.utf8.count ?? 0) <= 512 &&
            (metadata.description?.utf8.count ?? 0) <= 100_000 &&
            metadata.durationSeconds.map { $0.isFinite && $0 > 0 } == true &&
            metadata.canonicalURL == expectedCanonicalURL &&
            (metadata.channel?.isEmpty == false ||
                metadata.uploader?.isEmpty == false)
        if !identityIsValid {
            issues.append(
                "Identity must include the requested video ID, a title, "
                    + "positive duration, HTTPS canonical URL, and uploader."
            )
        }

        let thumbnailIsValid =
            !metadata.thumbnails.isEmpty &&
            metadata.thumbnails.count <= 100 &&
            metadata.thumbnails.allSatisfy {
                isSafeThumbnailURL($0.url)
            }
        if !thumbnailIsValid {
            issues.append(
                "Every thumbnail must be a bounded HTTPS URL from the "
                    + "approved YouTube image hosts."
            )
        }

        let formatIDs = metadata.formats.map(\.formatID)
        let formatsAreValid =
            !metadata.formats.isEmpty &&
            metadata.formats.count <= 2_000 &&
            Set(formatIDs).count == formatIDs.count &&
            metadata.formats.allSatisfy {
                !$0.formatID.isEmpty && $0.formatID.utf8.count <= 256 &&
                    ($0.hasVideo || $0.hasAudio) &&
                    !$0.sourceType.isEmpty &&
                    $0.sourceType.utf8.count <= 128 &&
                    ($0.extractorPreferenceRank.map { $0 >= 0 } ?? true)
            } &&
            metadata.chapters.count <= 10_000 &&
            SubtitleMetadataContract.violation(
                in: metadata.subtitles
            ) == nil
        if !formatsAreValid {
            issues.append(
                "The bounded usable-format inventory must have unique IDs "
                    + "and contain audio or video; "
                    + "subtitle discovery metadata must satisfy its bounded "
                    + "HTTPS transport contract."
            )
        }

        let countFieldsAreValid = [
            evidence.challengeRequestCount,
            evidence.challengeResponseCount,
            evidence.formatCount,
            evidence.warningCount,
            evidence.errorCount,
            evidence.providerConstructedCount,
            evidence.providerAvailableCount,
            evidence.bulkSolveCallCount,
            evidence.challengeRequestCounts.n,
            evidence.challengeRequestCounts.sig,
            evidence.challengeResponseCounts.n,
            evidence.challengeResponseCounts.sig,
            evidence.runtimeCallCount,
            evidence.runtimeErrorCount,
            evidence.runtimeCancellationCount,
            evidence.runtimeTimeoutCount,
            evidence.providerFailureCount,
        ].allSatisfy { $0 >= 0 }
        let observedChallengeTypes = Set(
            [
                evidence.challengeRequestCounts.n > 0 ? "n" : nil,
                evidence.challengeRequestCounts.sig > 0 ? "sig" : nil,
            ].compactMap { $0 }
        )
        let challengeCountsMatch =
            evidence.challengeResponseCount ==
                evidence.challengeRequestCount &&
            evidence.challengeResponseCounts ==
                evidence.challengeRequestCounts &&
            evidence.challengeRequestCount ==
                evidence.challengeRequestCounts.n +
                evidence.challengeRequestCounts.sig &&
            evidence.challengeResponseCount ==
                evidence.challengeResponseCounts.n +
                evidence.challengeResponseCounts.sig &&
            Set(evidence.challengeTypes) == observedChallengeTypes
        let challengeUseIsValid: Bool
        if evidence.challengeProviderUsed {
            challengeUseIsValid =
                evidence.challengeRequestCount > 0 &&
                evidence.providerConstructedCount > 0 &&
                evidence.providerAvailableCount > 0 &&
                evidence.providerAvailable &&
                evidence.bulkSolveCallCount > 0 &&
                evidence.runtimeCallCount > 0 &&
                challengeCountsMatch
        } else {
            challengeUseIsValid =
                evidence.challengeRequestCount == 0 &&
                evidence.challengeResponseCount == 0 &&
                evidence.challengeRequestCounts ==
                    JavaScriptChallengeCounts(n: 0, sig: 0) &&
                evidence.challengeResponseCounts ==
                    JavaScriptChallengeCounts(n: 0, sig: 0) &&
                evidence.challengeTypes.isEmpty &&
                evidence.bulkSolveCallCount == 0 &&
                evidence.runtimeCallCount == 0
        }
        let providerAvailabilityIsConsistent =
            evidence.providerAvailable ==
                (evidence.providerAvailableCount > 0) &&
            (
                evidence.providerAvailableCount == 0 ||
                    evidence.providerConstructedCount > 0
            )
        let providerWasNeverNeeded =
            !evidence.challengeProviderUsed &&
            evidence.providerConstructedCount == 0 &&
            evidence.providerAvailableCount == 0 &&
            !evidence.providerAvailable
        let ejsAssetHashesAreValid =
            (
                evidence.ejsCoreSHA3512 == contract.ejsCoreSHA3512 &&
                    evidence.ejsLibrarySHA3512 ==
                        contract.ejsLibrarySHA3512
            ) ||
            (
                providerWasNeverNeeded &&
                    evidence.ejsCoreSHA3512 == nil &&
                    evidence.ejsLibrarySHA3512 == nil
            )
        let inventoryDigest = formatInventorySHA256(
            for: metadata.formats
        )
        let providerPathIsValid =
            evidence.ytDLPVersion == contract.ytDLP &&
            evidence.ejsVersion == contract.ejs &&
            evidence.quickJSVersion == contract.quickJS &&
            evidence.providerKey == "IllucetQuickJS" &&
            evidence.providerRegistered &&
            !evidence.externalJSRuntimesEnabled &&
            !evidence.remoteComponentsEnabled &&
            countFieldsAreValid &&
            providerAvailabilityIsConsistent &&
            challengeUseIsValid &&
            evidence.formatCount == metadata.formats.count &&
            evidence.errorCount == 0 &&
            evidence.runtimeErrorCount == 0 &&
            evidence.runtimeCancellationCount == 0 &&
            evidence.runtimeTimeoutCount == 0 &&
            evidence.providerFailureCount == 0 &&
            ejsAssetHashesAreValid &&
            isLowercaseSHA256(evidence.formatInventorySHA256) &&
            inventoryDigest == evidence.formatInventorySHA256
        if !providerPathIsValid {
            issues.append(
                "The pinned in-process QuickJS provider must solve every "
                    + "observed challenge without external runtimes."
            )
        }

        return LiveExtractionValidation(
            identityIsValid: identityIsValid,
            thumbnailIsValid: thumbnailIsValid,
            formatsAreValid: formatsAreValid,
            providerPathIsValid: providerPathIsValid,
            expectedVideoID: expectedID,
            issues: issues
        )
    }

    static func youtubeVideoID(from url: URL) -> String? {
        guard let host = url.host()?.lowercased() else {
            return nil
        }

        if host == "youtu.be" || host == "www.youtu.be" {
            return validVideoID(
                url.pathComponents.dropFirst().first
            )
        }

        let normalizedHost = host.hasPrefix("www.")
            ? String(host.dropFirst(4))
            : host
        guard
            normalizedHost == "youtube.com" ||
                normalizedHost == "m.youtube.com" ||
                normalizedHost == "music.youtube.com"
        else {
            return nil
        }

        if url.path == "/watch" {
            let value = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.queryItems?.first { $0.name == "v" }?.value
            return validVideoID(value)
        }

        let components = url.pathComponents.filter { $0 != "/" }
        guard
            components.count >= 2,
            ["shorts", "embed", "live"].contains(components[0])
        else {
            return nil
        }
        return validVideoID(components[1])
    }

    private static func validVideoID(_ candidate: String?) -> String? {
        guard
            let candidate,
            candidate.utf8.count == 11,
            candidate.utf8.allSatisfy({ byte in
                (48...57).contains(byte) ||
                    (65...90).contains(byte) ||
                    (97...122).contains(byte) ||
                    byte == 45 ||
                    byte == 95
            })
        else {
            return nil
        }
        return candidate
    }

    static func formatInventorySHA256(
        for formats: [MediaFormat]
    ) -> String? {
        guard let canonicalJSON = canonicalFormatInventoryJSON(formats) else {
            return nil
        }
        return SHA256.hash(data: Data(canonicalJSON.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func canonicalFormatInventoryJSON(
        _ formats: [MediaFormat]
    ) -> String? {
        var objects: [String] = []
        objects.reserveCapacity(formats.count)

        for format in formats {
            guard
                let audioBitrate = canonicalNumber(
                    format.audioBitrateKbps
                ),
                let frameRate = canonicalNumber(
                    format.framesPerSecond
                ),
                let totalBitrate = canonicalNumber(
                    format.totalBitrateKbps
                ),
                let videoBitrate = canonicalNumber(
                    format.videoBitrateKbps
                )
            else {
                return nil
            }
            let fields = [
                jsonField(
                    "approximate_file_size_bytes",
                    canonicalNumber(format.approximateFileSizeBytes)
                ),
                jsonField("audio_bitrate_kbps", audioBitrate),
                jsonField(
                    "audio_codec",
                    canonicalString(format.audioCodec)
                ),
                jsonField(
                    "container",
                    canonicalString(format.container)
                ),
                jsonField(
                    "dynamic_range",
                    canonicalString(format.dynamicRange)
                ),
                jsonField(
                    "exact_file_size_bytes",
                    canonicalNumber(format.exactFileSizeBytes)
                ),
                jsonField(
                    "extension",
                    canonicalString(format.extension)
                ),
                // Older saved inventories omit this field. Current extraction
                // includes it, so it must also participate in the Python digest.
                format.extractorPreferenceRank.map {
                    jsonField("extractor_preference_rank", canonicalNumber($0))
                },
                jsonField(
                    "format_id",
                    canonicalString(format.formatID)
                ),
                jsonField(
                    "format_note",
                    canonicalString(format.formatNote)
                ),
                jsonField("frames_per_second", frameRate),
                jsonField(
                    "has_audio",
                    format.hasAudio ? "true" : "false"
                ),
                jsonField(
                    "has_video",
                    format.hasVideo ? "true" : "false"
                ),
                jsonField("height", canonicalNumber(format.height)),
                jsonField(
                    "is_hdr",
                    format.isHDR ? "true" : "false"
                ),
                jsonField(
                    "language",
                    canonicalString(format.language)
                ),
                jsonField(
                    "protocol",
                    canonicalString(format.protocolName)
                ),
                jsonField(
                    "resolution",
                    canonicalString(format.resolution)
                ),
                jsonField(
                    "source_type",
                    canonicalString(format.sourceType)
                ),
                jsonField("total_bitrate_kbps", totalBitrate),
                jsonField("video_bitrate_kbps", videoBitrate),
                jsonField(
                    "video_codec",
                    canonicalString(format.videoCodec)
                ),
                jsonField("width", canonicalNumber(format.width)),
            ]
            objects.append("{\(fields.compactMap { $0 }.joined(separator: ","))}")
        }
        return "[\(objects.joined(separator: ","))]"
    }

    private static func jsonField(
        _ key: String,
        _ encodedValue: String
    ) -> String {
        "\(canonicalString(key)):\(encodedValue)"
    }

    private static func canonicalString(_ value: String?) -> String {
        guard let value else {
            return "null"
        }
        return canonicalString(value)
    }

    private static func canonicalString(_ value: String) -> String {
        var output = "\""
        output.reserveCapacity(value.utf8.count + 2)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08:
                output.append("\\b")
            case 0x09:
                output.append("\\t")
            case 0x0A:
                output.append("\\n")
            case 0x0C:
                output.append("\\f")
            case 0x0D:
                output.append("\\r")
            case 0x22:
                output.append("\\\"")
            case 0x5C:
                output.append("\\\\")
            case 0x00...0x1F:
                output.append(
                    String(format: "\\u%04x", scalar.value)
                )
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output.append("\"")
        return output
    }

    private static func canonicalNumber(_ value: Double?) -> String? {
        guard let value else {
            return "null"
        }
        guard value.isFinite, value >= 0 else {
            return nil
        }
        return String(value)
    }

    private static func canonicalNumber<T: BinaryInteger>(
        _ value: T?
    ) -> String {
        guard let value else {
            return "null"
        }
        return String(value)
    }

    private static func isSafeThumbnailURL(_ url: URL) -> Bool {
        guard
            url.absoluteString.utf8.count <= 4_096,
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ),
            components.scheme?.lowercased() == "https",
            components.user == nil,
            components.password == nil,
            let host = components.host?.lowercased(),
            !host.isEmpty,
            components.port == nil ||
                components.port == 80 ||
                components.port == 443,
            components.query == nil,
            components.fragment == nil
        else {
            return false
        }
        return host.hasSuffix(".ytimg.com") ||
            host.hasSuffix(".ggpht.com")
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 &&
            value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}
