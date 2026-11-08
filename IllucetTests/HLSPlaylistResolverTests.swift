import Foundation
import Testing
@testable import Illucet

@Suite("P10.4 HLS playlist parsing")
struct HLSPlaylistParserTests {
    @Test
    func projectsCompletedMediaPlaylistInExactEventOrder() throws {
        let document = try HLSPlaylistParser.parse(
            Data(mediaPlaylist.utf8),
            finalPlaylistURL: mediaURL
        )
        guard case let .media(plan) = document else {
            Issue.record("Expected a media playlist.")
            return
        }

        #expect(plan.mediaSegmentCount == 2)
        #expect(plan.initializationCount == 0)
        #expect(plan.events.count == 3)
        #expect(plan.events.map(\.position) == [0, 1, 2])
        #expect(plan.events.compactMap(\.resource).map(\.position) == [0, 1])
        #expect(
            plan.events.compactMap(\.resource).map(\.URL.absoluteString) == [
                "https://manifest.googlevideo.com/hls/segments/one.ts?sig=segment-secret",
                "https://manifest.googlevideo.com/hls/segments/two.ts?sig=segment-secret-two",
            ]
        )
        #expect(
            plan.events[1] == .discontinuity(eventPosition: 1)
        )
    }

    @Test
    func preservesInitRepeatsAssociationsAndExactByteRanges() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="shared.mp4?sig=resource",BYTERANGE="4@0"
        #EXTINF:6,
        #EXT-X-BYTERANGE:3@4
        shared.mp4?sig=resource
        #EXT-X-DISCONTINUITY
        #EXT-X-MAP:URI="shared.mp4?sig=resource",BYTERANGE="4@0"
        #EXTINF:6,
        #EXT-X-BYTERANGE:3
        shared.mp4?sig=resource
        #EXTINF:6,
        shared.mp4?sig=resource
        #EXT-X-ENDLIST
        """
        let document = try HLSPlaylistParser.parse(
            Data(playlist.utf8),
            finalPlaylistURL: mediaURL
        )
        let plan = try #require(document.mediaPlan)

        #expect(plan.mediaSegmentCount == 3)
        #expect(plan.initializationCount == 2)
        #expect(plan.events.count == 6)
        #expect(plan.events.compactMap(\.resource).map(\.position)
            == [0, 1, 2, 3, 4])
        #expect(plan.events.compactMap(\.resource).map(\.byteRange) == [
            HLSMediaByteRange(offset: 0, length: 4),
            HLSMediaByteRange(offset: 4, length: 3),
            HLSMediaByteRange(offset: 0, length: 4),
            HLSMediaByteRange(offset: 7, length: 3),
            nil,
        ])
        #expect(
            plan.events[0] == .initialization(
                eventPosition: 0,
                resource: plan.events[0].resource!
            )
        )
        #expect(plan.events[2] == .discontinuity(eventPosition: 2))
        guard
            case let .media(_, _, firstInit) = plan.events[1],
            case let .media(_, _, secondInit) = plan.events[4],
            case let .media(_, _, thirdInit) = plan.events[5]
        else {
            Issue.record("Expected ordered media events.")
            return
        }
        #expect(firstInit == 0)
        #expect(secondInit == 3)
        #expect(thirdInit == 3)
        #expect(
            plan.events.compactMap(\.resource).map(\.URL).allSatisfy {
                $0.absoluteString
                    == "https://manifest.googlevideo.com/hls/shared.mp4?sig=resource"
            }
        )
    }

    @Test
    func omittedCrossResourceMissingAndOverflowRangesFailClosed() {
        let invalid: [(String, HLSPlaylistParsingError)] = [
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\n#EXT-X-BYTERANGE:3\none.ts\n#EXT-X-ENDLIST\n",
                .ambiguousByteRange
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\n#EXT-X-BYTERANGE:3@0\none.ts\n#EXTINF:6,\n#EXT-X-BYTERANGE:3\ntwo.ts\n#EXT-X-ENDLIST\n",
                .ambiguousByteRange
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MAP:URI=init.mp4,BYTERANGE=4\n#EXTINF:6,\none.ts\n#EXT-X-ENDLIST\n",
                .ambiguousByteRange
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\n#EXT-X-BYTERANGE:2@9223372036854775807\none.ts\n#EXT-X-ENDLIST\n",
                .invalidByteRange
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\n#EXT-X-BYTERANGE:1@9223372036854775807\none.ts\n#EXTINF:6,\n#EXT-X-BYTERANGE:1\none.ts\n#EXT-X-ENDLIST\n",
                .invalidByteRange
            ),
        ]
        for (playlist, expected) in invalid {
            do {
                _ = try HLSPlaylistParser.parse(
                    Data(playlist.utf8),
                    finalPlaylistURL: mediaURL
                )
                Issue.record("Invalid HLS byte range unexpectedly parsed.")
            } catch let error as HLSPlaylistParsingError {
                #expect(error == expected)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test
    func mediaInitAndForgedProjectedPlanBoundsFailClosed() throws {
        let tooManyMedia = "#EXTM3U\n#EXT-X-TARGETDURATION:1\n"
            + (0...HLSPlaylistParser.maximumMediaEntries).map {
                "#EXTINF:1,\n\($0).ts"
            }.joined(separator: "\n")
            + "\n#EXT-X-ENDLIST\n"
        #expect(throws: HLSPlaylistParsingError.tooManyMediaEntries) {
            _ = try HLSPlaylistParser.parse(
                Data(tooManyMedia.utf8),
                finalPlaylistURL: mediaURL
            )
        }

        let tooManyInit = "#EXTM3U\n#EXT-X-TARGETDURATION:1\n"
            + (0...HLSPlaylistParser.maximumInitializationDeclarations)
                .map { "#EXT-X-MAP:URI=init-\($0).mp4" }
                .joined(separator: "\n")
            + "\n#EXTINF:1,\none.ts\n#EXT-X-ENDLIST\n"
        #expect(
            throws: HLSPlaylistParsingError.tooManyInitializationSections
        ) {
            _ = try HLSPlaylistParser.parse(
                Data(tooManyInit.utf8),
                finalPlaylistURL: mediaURL
            )
        }

        let valid = try #require(
            try HLSPlaylistParser.parse(
                Data(mediaPlaylist.utf8),
                finalPlaylistURL: mediaURL
            ).mediaPlan
        )
        let forged = HLSMediaResourcePlan(
            events: valid.events,
            mediaSegmentCount: valid.mediaSegmentCount,
            initializationCount: valid.initializationCount,
            projectedByteCount: HLSPlaylistParser.maximumProjectedPlanBytes + 1
        )
        #expect(!HLSPlaylistParser.isValidMediaResourcePlan(forged))
    }

    @Test
    func masterResolvesRelativeAbsoluteAndRenditionURIsExactly() throws {
        let document = try HLSPlaylistParser.parse(
            Data(masterPlaylist.utf8),
            finalPlaylistURL: masterURL
        )
        guard case let .master(variants) = document else {
            Issue.record("Expected a master playlist.")
            return
        }

        #expect(variants.count == 4)
        #expect(variants.map(\.kind) == [
            .audioRendition,
            .stream,
            .stream,
            .stream,
        ])
        #expect(
            variants[0].playlistURL.absoluteString
                == "https://manifest.googlevideo.com/hls/audio/en.m3u8?sig=audio"
        )
        #expect(
            variants[2].playlistURL.absoluteString
                == "https://manifest.googlevideo.com/hls/720.m3u8?sig=selected"
        )
        #expect(
            variants[3].playlistURL.absoluteString
                == "https://manifest.googlevideo.com/absolute/1080.m3u8?sig=absolute"
        )

        let exact = try HLSPlaylistParser.exactVariant(
            in: document,
            requestedMediaPlaylistURL: mediaURL
        )
        #expect(exact.kind == .stream)
        #expect(exact.playlistURL == mediaURL)
    }

    @Test
    func missingDuplicateReorderedAndMalformedInputsFailClosed() throws {
        let duplicate = masterPlaylist.replacingOccurrences(
            of: "#EXT-X-ENDLIST",
            with: ""
        ) + "\n#EXT-X-STREAM-INF:BANDWIDTH=2500000\n720.m3u8?sig=selected\n"
        let duplicateDocument = try HLSPlaylistParser.parse(
            Data(duplicate.utf8),
            finalPlaylistURL: masterURL
        )
        #expect(throws: HLSPlaylistParsingError.ambiguousVariant) {
            _ = try HLSPlaylistParser.exactVariant(
                in: duplicateDocument,
                requestedMediaPlaylistURL: mediaURL
            )
        }
        #expect(throws: HLSPlaylistParsingError.requestedVariantMissing) {
            _ = try HLSPlaylistParser.exactVariant(
                in: duplicateDocument,
                requestedMediaPlaylistURL: URL(
                    string: "https://manifest.googlevideo.com/hls/missing.m3u8"
                )!
            )
        }

        let malformed: [(String, HLSPlaylistParsingError)] = [
            (
                "#EXTM3U\n720.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=1\n",
                .malformedDirective
            ),
            (
                "#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=1280x720\n720.m3u8\n",
                .malformedDirective
            ),
            (
                "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,BANDWIDTH=2\n720.m3u8\n",
                .malformedDirective
            ),
            (
                "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n#comment\n720.m3u8\n",
                .malformedDirective
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts\n",
                .malformedDirective
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-STREAM-INF:BANDWIDTH=1\n720.m3u8\n",
                .mixedPlaylistKinds
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key\"\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST\n",
                .encryptionUnsupported
            ),
            (
                "#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"key\"\n#EXT-X-STREAM-INF:BANDWIDTH=1\n720.m3u8\n",
                .sessionKeyUnsupported
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\n#EXT-X-GAP\nsegment.ts\n#EXT-X-ENDLIST\n",
                .unsupportedDirective
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-PART:DURATION=1,URI=\"part.ts\"\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST\n",
                .unsupportedDirective
            ),
            (
                "#EXTM3U\n#EXT-X-DEFINE:NAME=\"host\",VALUE=\"secret\"\n#EXT-X-STREAM-INF:BANDWIDTH=1\n{$host}/720.m3u8\n",
                .unsupportedDirective
            ),
        ]
        for (playlist, expected) in malformed {
            do {
                _ = try HLSPlaylistParser.parse(
                    Data(playlist.utf8),
                    finalPlaylistURL: masterURL
                )
                Issue.record("Malformed HLS playlist unexpectedly parsed.")
            } catch let error as HLSPlaylistParsingError {
                #expect(error == expected)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test
    func unsafeVariantURIsFailClosed() {
        let unsafeURIs = [
            "http://manifest.googlevideo.com/720.m3u8",
            "https://example.invalid/720.m3u8",
            "https://user:password@manifest.googlevideo.com/720.m3u8",
            "https://manifest.googlevideo.com:8443/720.m3u8",
            "https://manifest.googlevideo.com/720.m3u8#fragment",
            "//example.invalid/720.m3u8",
            "folder\\720.m3u8",
            "folder/720 playlist.m3u8",
        ]

        for URI in unsafeURIs {
            let playlist = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000000
            \(URI)

            """
            #expect(throws: HLSPlaylistParsingError.self) {
                _ = try HLSPlaylistParser.parse(
                    Data(playlist.utf8),
                    finalPlaylistURL: masterURL
                )
            }
        }

        let unsafeMedia = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="https://example.invalid/init.mp4"
        #EXTINF:6,
        https://example.invalid/segment.ts
        #EXT-X-ENDLIST
        """
        #expect(throws: HLSPlaylistParsingError.unsafeURI) {
            _ = try HLSPlaylistParser.parse(
                Data(unsafeMedia.utf8),
                finalPlaylistURL: mediaURL
            )
        }
    }

    @Test
    func UTF8ByteLineVariantAndControlBoundsFailClosed() {
        #expect(throws: HLSPlaylistParsingError.invalidUTF8) {
            _ = try HLSPlaylistParser.parse(
                Data([0xff, 0xfe, 0xfd]),
                finalPlaylistURL: masterURL
            )
        }
        let oversizedBytes = Data(
            repeating: 0x23,
            count: HLSPlaylistParser.maximumManifestBytes + 1
        )
        #expect(throws: HLSPlaylistParsingError.invalidManifest) {
            _ = try HLSPlaylistParser.parse(
                oversizedBytes,
                finalPlaylistURL: masterURL
            )
        }
        let oversizedLine = "#EXTM3U\n#" + String(
            repeating: "x",
            count: HLSPlaylistParser.maximumLineBytes
        )
        #expect(throws: HLSPlaylistParsingError.lineTooLong) {
            _ = try HLSPlaylistParser.parse(
                Data(oversizedLine.utf8),
                finalPlaylistURL: masterURL
            )
        }
        let tooManyLines = "#EXTM3U\n" + String(
            repeating: "\n",
            count: HLSPlaylistParser.maximumLines
        )
        #expect(throws: HLSPlaylistParsingError.tooManyLines) {
            _ = try HLSPlaylistParser.parse(
                Data(tooManyLines.utf8),
                finalPlaylistURL: masterURL
            )
        }
        let tooManyVariants = "#EXTM3U\n" + (0...HLSPlaylistParser.maximumVariants)
            .map {
                "#EXT-X-STREAM-INF:BANDWIDTH=\($0 + 1)\n\($0).m3u8"
            }
            .joined(separator: "\n")
        #expect(throws: HLSPlaylistParsingError.tooManyVariants) {
            _ = try HLSPlaylistParser.parse(
                Data(tooManyVariants.utf8),
                finalPlaylistURL: masterURL
            )
        }
        let control = "#EXTM3U\n#EXT-X-TARGETDURATION:6\u{0}\n"
        #expect(throws: HLSPlaylistParsingError.controlCharacter) {
            _ = try HLSPlaylistParser.parse(
                Data(control.utf8),
                finalPlaylistURL: masterURL
            )
        }
    }

    private var masterURL: URL {
        URL(
            string: "https://manifest.googlevideo.com/hls/master.m3u8?sig=master"
        )!
    }

    private var mediaURL: URL {
        URL(
            string: "https://manifest.googlevideo.com/hls/720.m3u8?sig=selected"
        )!
    }

    private var masterPlaylist: String {
        """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",DEFAULT=YES,URI="audio/en.m3u8?sig=audio"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,AUDIO="audio"
        360.m3u8?sig=other
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,AVERAGE-BANDWIDTH=2200000,RESOLUTION=1280x720,FRAME-RATE=30.0,AUDIO="audio"
        720.m3u8?sig=selected
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        https://manifest.googlevideo.com/absolute/1080.m3u8?sig=absolute
        """
    }

    private var mediaPlaylist: String {
        """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:6.0,
        segments/one.ts?sig=segment-secret
        #EXT-X-DISCONTINUITY
        #EXTINF:5.5,Second
        segments/two.ts?sig=segment-secret-two
        #EXT-X-ENDLIST
        """
    }
}

private extension HLSPlaylistDocument {
    var mediaPlan: HLSMediaResourcePlan? {
        guard case let .media(plan) = self else { return nil }
        return plan
    }
}

@Suite("P10.4 exact HLS playlist resolution")
struct HLSPlaylistResolverTests {
    @Test
    func requestHeadersAndNativeSessionPolicyStayStrictlyBounded() {
        #expect(HLSPlaylistSecurity.areAllowedHeaders([
            "Accept": "application/vnd.apple.mpegurl",
            "Accept-Language": "en-US",
            "Origin": "https://www.youtube.com",
            "Referer": "https://www.youtube.com/",
            "User-Agent": "Illucet-HLS-Test",
            "Sec-Fetch-Mode": "navigate",
        ]))
        #expect(!HLSPlaylistSecurity.areAllowedHeaders([
            "Sec-Fetch-Mode": "arbitrary-secret",
        ]))
        #expect(!HLSPlaylistSecurity.areAllowedHeaders([
            "Authorization": "Bearer secret",
        ]))
        #expect(!HLSPlaylistSecurity.areAllowedHeaders([
            "User-Agent": "one",
            "user-agent": "two",
        ]))
        let acceptsControlCharacters = HLSPlaylistSecurity.areAllowedHeaders([
            "User-Agent": "unsafe\r\nX-Secret: value",
        ])
        #expect(acceptsControlCharacters == false)
        #expect(!HLSPlaylistSecurity.areAllowedHeaders([
            "User-Agent": String(repeating: "x", count: 1_025),
        ]))

        let policy = HLSPlaylistSessionPolicy.secure
        #expect(policy.maximumRedirects == 4)
        #expect(!policy.acceptsCookies)
        #expect(!policy.usesCredentialStorage)
        #expect(!policy.usesURLCache)
        #expect(policy.usesDefaultTLSVerification)
    }

    @Test
    func identityDecoderAcceptsOnlyExactEphemeralHLSFacts() throws {
        let identity = try decode(validIdentityResponse)

        #expect(identity.videoID == "AbCdEf123_-")
        #expect(identity.formatID == "hls-720")
        #expect(identity.protocolName == "m3u8_native")
        #expect(identity.sourceType == "hls")
        #expect(identity.fileExtension == "mp4")
        #expect(identity.hasVideo)
        #expect(identity.hasAudio)
        #expect(identity.HTTPHeaders == ["User-Agent": "Illucet-HLS-Test"])
        #expect(identity.manifestURL == masterURL)
        #expect(identity.mediaPlaylistURL == mediaURL)

        let invalid = [
            validIdentityResponse.replacingOccurrences(
                of: #""extension": "mp4""#,
                with: #""extension": "ts""#
            ),
            validIdentityResponse.replacingOccurrences(
                of: #""protocol": "m3u8_native""#,
                with: #""protocol": "https""#
            ),
            validIdentityResponse.replacingOccurrences(
                of: "manifest.googlevideo.com/hls/master",
                with: "example.invalid/hls/master"
            ),
            validIdentityResponse.replacingOccurrences(
                of: #""User-Agent": "Illucet-HLS-Test""#,
                with: #""Authorization": "Bearer secret""#
            ),
            validIdentityResponse.replacingOccurrences(
                of: #""manifest_url":"#,
                with: #""cookies":"secret","manifest_url":"#
            ),
            validIdentityResponse.replacingOccurrences(
                of: #""has_video": true"#,
                with: #""has_video": false"#
            ).replacingOccurrences(
                of: #""has_audio": true"#,
                with: #""has_audio": false"#
            ),
        ]
        for response in invalid {
            #expect(throws: HLSPlaylistResolutionError.invalidResponse) {
                _ = try decode(response)
            }
        }
    }

    @Test
    func identityKeepsAvailabilityAndRejectsMalformedDeadlines() throws {
        let timestamp = Date.now.timeIntervalSince1970 + 4
        let response = validIdentityResponse.replacingOccurrences(of: #""has_video": true"#,
            with: "\"available_at\": \(timestamp), \"has_video\": true")
        #expect(try decode(response).availableAt?.timeIntervalSince1970 == timestamp)
        for value in ["true", "-1", "4102444800", #""1800000000""#] {
            let malformed = validIdentityResponse.replacingOccurrences(of: #""has_video": true"#,
                with: "\"available_at\": \(value), \"has_video\": true")
            #expect(throws: HLSPlaylistResolutionError.invalidResponse) { try decode(malformed) }
        }
    }

    @Test
    func cancelledAvailabilityWaitDoesNotRequestTheManifest() async throws {
        let networking = FixtureHLSPlaylistNetworking(responses: [mediaURL.absoluteString: [.ok(mediaPlaylist)]])
        let delayed = identity(availableAt: .now.addingTimeInterval(30))
        let operation = Task {
            try await YTDLPHLSPlaylistResolver.resolveValidatedIdentity(delayed, networking: networking)
        }
        try await Task.sleep(for: .milliseconds(20))
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await networking.requestedURLs().isEmpty)
    }

    @Test
    func directMediaLeafUsesOneControlPlaneRequestAndNoSegmentRequest()
        async throws
    {
        let networking = FixtureHLSPlaylistNetworking(
            responses: [
                mediaURL.absoluteString: [
                    .ok(mediaPlaylist),
                ],
            ]
        )
        let selection = try await YTDLPHLSPlaylistResolver
            .resolveValidatedIdentity(
                identity(
                    manifestURL: mediaURL,
                    mediaPlaylistURL: mediaURL
                ),
                networking: networking
            )

        #expect(selection.route == .directMedia)
        #expect(selection.playlistRequestCount == 1)
        #expect(selection.redirectCount == 0)
        #expect(selection.masterVariantCount == 0)
        #expect(selection.mediaSegmentCount == 2)
        #expect(selection.mediaPlaylistURL == mediaURL)
        #expect(await networking.requestedURLs() == [mediaURL])
        #expect(
            await networking.requestHeader(
                named: "User-Agent",
                at: 0
            ) == "Illucet-HLS-Test"
        )
    }

    @Test
    func exactLeafIgnoresRegeneratedMasterSignatures() async throws {
        let refreshedMaster = masterPlaylist.replacingOccurrences(
            of: "720.m3u8?sig=selected",
            with: "720.m3u8?sig=regenerated"
        )
        let networking = FixtureHLSPlaylistNetworking(responses: [
            masterURL.absoluteString: [.ok(refreshedMaster)],
            mediaURL.absoluteString: [.ok(mediaPlaylist)],
        ])
        let selection = try await YTDLPHLSPlaylistResolver
            .resolveValidatedIdentity(identity(), networking: networking)

        #expect(selection.route == .directMedia)
        #expect(selection.playlistRequestCount == 1)
        #expect(selection.redirectCount == 0)
        #expect(selection.masterVariantCount == 0)
        #expect(selection.mediaSegmentCount == 2)
        #expect(selection.mediaPlaylistURL == mediaURL)
        #expect(await networking.requestedURLs() == [mediaURL])
    }

    @Test
    func safeLeafRedirectsResolveRelativeResourcesAtFinalURL() async throws {
        let intermediate = URL(
            string: "https://manifest.googlevideo.com/hls/redirected.m3u8"
        )!
        let final = URL(
            string: "https://manifest.googlevideo.com/final/720.m3u8"
        )!
        let networking = FixtureHLSPlaylistNetworking(responses: [
            mediaURL.absoluteString: [.redirect("redirected.m3u8")],
            intermediate.absoluteString: [.redirect(final.absoluteString)],
            final.absoluteString: [.ok(mediaPlaylist)],
        ])
        let selection = try await YTDLPHLSPlaylistResolver
            .resolveValidatedIdentity(identity(), networking: networking)

        #expect(selection.redirectCount == 2)
        #expect(selection.mediaPlaylistURL == final)
        #expect(selection.resourcePlan.events.compactMap(\.resource).map(\.URL) == [
            URL(string: "https://manifest.googlevideo.com/final/segments/one.ts?sig=segment-secret")!,
            URL(string: "https://manifest.googlevideo.com/final/segments/two.ts?sig=segment-secret-two")!,
        ])
        #expect(await networking.requestedURLs() == [mediaURL, intermediate, final])
    }

    @Test
    func playlistHTTPFailuresPreserveRetryClassification() async {
        for status in [401, 403, 404, 410, 429, 500, 503] {
            let networking = FixtureHLSPlaylistNetworking(responses: [
                mediaURL.absoluteString: [
                    HLSPlaylistHTTPResponse(statusCode: status, headers: [:], body: Data()),
                ],
            ])
            await #expect(throws: StreamDownloadError.HTTPFailure(statusCode: status)) {
                _ = try await YTDLPHLSPlaylistResolver.resolveValidatedIdentity(
                    identity(manifestURL: mediaURL, mediaPlaylistURL: mediaURL),
                    networking: networking
                )
            }
        }
    }

    @Test
    func unsafeOversizedAndExcessRedirectResponsesFailClosed() async {
        let unsafe = FixtureHLSPlaylistNetworking(
            responses: [
                mediaURL.absoluteString: [
                    .redirect("https://example.invalid/master.m3u8"),
                ],
            ]
        )
        await expectTransportError(.tooManyRedirects) {
            try await YTDLPHLSPlaylistResolver.resolveValidatedIdentity(
                identity(),
                networking: unsafe
            )
        }

        let oversized = FixtureHLSPlaylistNetworking(
            responses: [
                mediaURL.absoluteString: [
                    HLSPlaylistHTTPResponse(
                        statusCode: 200,
                        headers: [:],
                        body: Data(
                            repeating: 0x23,
                            count: HLSPlaylistParser.maximumManifestBytes + 1
                        )
                    ),
                ],
            ]
        )
        await expectTransportError(.responseTooLarge) {
            try await YTDLPHLSPlaylistResolver.resolveValidatedIdentity(
                identity(
                    manifestURL: mediaURL,
                    mediaPlaylistURL: mediaURL
                ),
                networking: oversized
            )
        }

        var responses: [String: [HLSPlaylistHTTPResponse]] = [:]
        var current = mediaURL
        for index in 1...5 {
            let next = URL(
                string: "https://manifest.googlevideo.com/hls/r\(index).m3u8"
            )!
            responses[current.absoluteString] = [
                .redirect(next.absoluteString),
            ]
            current = next
        }
        let excessive = FixtureHLSPlaylistNetworking(responses: responses)
        await expectTransportError(.tooManyRedirects) {
            try await YTDLPHLSPlaylistResolver.resolveValidatedIdentity(
                identity(),
                networking: excessive
            )
        }
    }

    @Test
    func unavailableLeafDoesNotFallBackToMasterOrAnotherVariant() async {
        let networking = FixtureHLSPlaylistNetworking(responses: [
            masterURL.absoluteString: [.ok(masterPlaylist)],
            mediaURL.absoluteString: [
                HLSPlaylistHTTPResponse(statusCode: 404, headers: [:], body: Data()),
            ],
        ])
        await #expect(throws: StreamDownloadError.HTTPFailure(statusCode: 404)) {
            _ = try await YTDLPHLSPlaylistResolver.resolveValidatedIdentity(
                identity(), networking: networking
            )
        }
        #expect(await networking.requestedURLs() == [mediaURL])
    }

    @Test
    func masterAtExactLeafAndRedirectCyclesFailClosed() async {
        let childMaster = FixtureHLSPlaylistNetworking(responses: [
            mediaURL.absoluteString: [.ok(masterPlaylist)],
        ])
        await expectResolutionError(.recursivePlaylist) {
            try await YTDLPHLSPlaylistResolver.resolveValidatedIdentity(
                identity(), networking: childMaster
            )
        }
        #expect(await childMaster.requestedURLs() == [mediaURL])

        let cycle = FixtureHLSPlaylistNetworking(responses: [
            mediaURL.absoluteString: [.redirect(masterURL.absoluteString)],
            masterURL.absoluteString: [.redirect(mediaURL.absoluteString)],
        ])
        await expectTransportError(.tooManyRedirects) {
            try await YTDLPHLSPlaylistResolver.resolveValidatedIdentity(
                identity(), networking: cycle
            )
        }
        #expect(await cycle.requestedURLs() == [mediaURL, masterURL])
    }

    private func decode(_ response: String) throws
        -> ResolvedHLSPlaylistIdentity
    {
        try YTDLPHLSPlaylistResolver.decodeIdentityResponse(
            response,
            normalizedURL: URL(
                string: "https://www.youtube.com/watch?v=AbCdEf123_-"
            )!,
            formatID: "hls-720"
        )
    }

    private func identity(
        manifestURL: URL? = nil,
        mediaPlaylistURL: URL? = nil,
        availableAt: Date? = nil
    ) -> ResolvedHLSPlaylistIdentity {
        ResolvedHLSPlaylistIdentity(
            videoID: "AbCdEf123_-",
            formatID: "hls-720",
            protocolName: "m3u8_native",
            sourceType: "hls",
            fileExtension: "mp4",
            hasVideo: true,
            hasAudio: true,
            HTTPHeaders: ["User-Agent": "Illucet-HLS-Test"],
            manifestURL: manifestURL ?? masterURL,
            mediaPlaylistURL: mediaPlaylistURL ?? mediaURL,
            availableAt: availableAt
        )
    }

    private func expectTransportError(
        _ expected: HLSPlaylistTransportError,
        operation: () async throws -> ResolvedHLSPlaylistSelection
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected HLS transport failure.")
        } catch let error as HLSPlaylistTransportError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func expectParsingError(
        _ expected: HLSPlaylistParsingError,
        operation: () async throws -> ResolvedHLSPlaylistSelection
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected HLS parsing failure.")
        } catch let error as HLSPlaylistParsingError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func expectResolutionError(
        _ expected: HLSPlaylistResolutionError,
        operation: () async throws -> ResolvedHLSPlaylistSelection
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected HLS resolution failure.")
        } catch let error as HLSPlaylistResolutionError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private var masterURL: URL {
        URL(
            string: "https://manifest.googlevideo.com/hls/master.m3u8?sig=master"
        )!
    }

    private var mediaURL: URL {
        URL(
            string: "https://manifest.googlevideo.com/hls/720.m3u8?sig=selected"
        )!
    }

    private var validIdentityResponse: String {
        """
        {
          "ok": true,
          "action": "resolve_hls_playlist_plan",
          "data": {
            "video_id": "AbCdEf123_-",
            "format_id": "hls-720",
            "protocol": "m3u8_native",
            "source_type": "hls",
            "extension": "mp4",
            "has_video": true,
            "has_audio": true,
            "http_headers": {"User-Agent": "Illucet-HLS-Test"},
            "manifest_url": "https://manifest.googlevideo.com/hls/master.m3u8?sig=master",
            "media_playlist_url": "https://manifest.googlevideo.com/hls/720.m3u8?sig=selected"
          },
          "error": null
        }
        """
    }

    private var masterPlaylist: String {
        """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        360.m3u8?sig=other
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
        720.m3u8?sig=selected
        """
    }

    private var mediaPlaylist: String {
        """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:6.0,
        segments/one.ts?sig=segment-secret
        #EXTINF:5.0,
        segments/two.ts?sig=segment-secret-two
        #EXT-X-ENDLIST
        """
    }
}

private actor FixtureHLSPlaylistNetworking: HLSPlaylistNetworking {
    private var responses: [String: [HLSPlaylistHTTPResponse]]
    private var requests: [URLRequest] = []

    init(responses: [String: [HLSPlaylistHTTPResponse]]) {
        self.responses = responses
    }

    func response(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> HLSPlaylistHTTPResponse {
        guard
            maximumBytes == HLSPlaylistParser.maximumManifestBytes,
            let URL = request.url
        else {
            throw HLSPlaylistTransportError.HTTPFailure
        }
        requests.append(request)
        guard
            var queued = responses[URL.absoluteString],
            !queued.isEmpty
        else {
            throw HLSPlaylistTransportError.HTTPFailure
        }
        let response = queued.removeFirst()
        responses[URL.absoluteString] = queued
        return response
    }

    func requestedURLs() -> [URL] {
        requests.compactMap(\.url)
    }

    func requestHeader(named name: String, at index: Int) -> String? {
        guard requests.indices.contains(index) else { return nil }
        return requests[index].value(forHTTPHeaderField: name)
    }
}

private extension HLSPlaylistHTTPResponse {
    static func ok(_ body: String) -> Self {
        Self(statusCode: 200, headers: [:], body: Data(body.utf8))
    }

    static func redirect(_ location: String) -> Self {
        Self(
            statusCode: 302,
            headers: ["Location": location],
            body: Data()
        )
    }
}
