import Foundation
import Testing
@testable import Illucet

private actor ScriptedSubtitleDNS: SubtitleDNSResolving {
    private var answers: [String: [[String]]]

    init(_ answers: [String: [[String]]]) {
        self.answers = answers
    }

    func addresses(for host: String) async throws -> Set<SubtitleIPAddress> {
        guard var values = answers[host], !values.isEmpty else {
            throw SubtitlePipelineError.DNSResolutionFailed
        }
        let selected = values.count > 1 ? values.removeFirst() : values[0]
        answers[host] = values
        return Set(selected.compactMap(SubtitleIPAddress.init))
    }
}

private enum ScriptedHTTPStep: Sendable {
    case response(SubtitleHTTPResponse)
    case failure(SubtitlePipelineError)
}

private actor ScriptedSubtitleHTTP: SubtitleHTTPNetworking {
    private var steps: [ScriptedHTTPStep]
    private(set) var requestTimeouts: [TimeInterval] = []

    init(_ steps: [ScriptedHTTPStep]) {
        self.steps = steps
    }

    func response(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> SubtitleHTTPResponse {
        requestTimeouts.append(request.timeoutInterval)
        guard !steps.isEmpty else {
            throw SubtitlePipelineError.HTTPFailure
        }
        let step = steps.removeFirst()
        switch step {
        case let .response(response):
            guard response.body.count <= maximumBytes else {
                throw SubtitlePipelineError.responseTooLarge
            }
            return response
        case let .failure(error):
            throw error
        }
    }
}

private actor ScriptedSubtitleTransport: SubtitleTransporting {
    private var results: [Result<Data, SubtitlePipelineError>]
    private(set) var callCount = 0
    private(set) var requestedURLs: [URL] = []

    init(_ results: [Result<Data, SubtitlePipelineError>]) {
        self.results = results
    }

    func download(from URL: URL) async throws -> Data {
        callCount += 1
        requestedURLs.append(URL)
        guard !results.isEmpty else {
            throw SubtitlePipelineError.HTTPFailure
        }
        return try results.removeFirst().get()
    }
}

private struct CancellableSubtitleTransport: SubtitleTransporting {
    func download(from URL: URL) async throws -> Data {
        try await Task.sleep(for: .seconds(30))
        return Data()
    }
}

private final class SubtitleFixtureExtractor:
    ExtractorEngine,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var results: [MediaMetadata]
    private(set) var callCount = 0

    init(_ results: [MediaMetadata]) {
        self.results = results
    }

    func versions() async throws -> ExtractorVersions {
        ExtractorVersions(python: "fixture", ytDLP: "fixture", ejs: "fixture")
    }

    func analyze(url: URL) async throws -> MediaMetadata {
        lock.withLock {
            callCount += 1
            if results.count > 1 { return results.removeFirst() }
            return results[0]
        }
    }

    func cancel(requestID: UInt64) {}
}

private struct SubtitleFixturePhotoLibrary: PhotoLibraryExporting {
    func saveAsset(
        at fileURL: URL,
        kind: ExportAssetKind
    ) async throws -> String {
        "fixture-photo"
    }
}

@Suite("P8.2 subtitle sidecars")
struct SubtitleSidecarTests {
    @Test
    func enablesVerifiedSidecarsAndEmbedding() {
        #expect(
            OutputCapabilityMatrix.enabledSubtitleDeliveries == [
                .none,
                .sidecarVTT,
                .sidecarSRT,
                .embed,
                .burnIn,
            ]
        )
        var value = DownloadConfiguration.standard
        value.subtitleDelivery = .embed
        #expect(OutputCapabilityMatrix.normalized(value).subtitleDelivery == .embed)
        value.mode = .audioOnly
        #expect(OutputCapabilityMatrix.normalized(value).subtitleDelivery == .none)
        value.mode = .videoAndAudio
        value.subtitleDelivery = .burnIn
        #expect(OutputCapabilityMatrix.normalized(value).subtitleDelivery == .burnIn)
    }

    @Test
    func plansExactManualAndAutomaticSelections() throws {
        var configuration = DownloadConfiguration.standard
        configuration.subtitleDelivery = .sidecarVTT
        configuration.subtitleSelections = [manualSelection, automaticSelection]
        configuration = OutputCapabilityMatrix.normalized(configuration)

        let plans = try SubtitleSelectionPlanner.plans(
            configuration: configuration,
            metadata: fixtureMetadata
        )

        #expect(plans.map(\.selection) == [manualSelection, automaticSelection])
        #expect(plans.allSatisfy { $0.kind == .webVTT })
        #expect(configuration.subtitleLanguages == ["en"])
        #expect(configuration.includeAutomaticSubtitles)
    }

    @Test
    func refusesIdentityOrFormatSubstitution() {
        var configuration = DownloadConfiguration.standard
        configuration.subtitleDelivery = .sidecarSRT
        configuration.subtitleSelections = [
            SubtitleTrackSelection(
                trackID: manualSelection.trackID,
                formatID: automaticSelection.formatID,
                language: "en",
                automatic: false
            ),
        ]
        configuration = OutputCapabilityMatrix.normalized(configuration)

        #expect(throws: SubtitlePipelineError.formatUnavailable) {
            try SubtitleSelectionPlanner.plans(
                configuration: configuration,
                metadata: fixtureMetadata
            )
        }
    }

    @Test
    func photosOnlyRejectsSidecarsBeforeQueueing() {
        var configuration = DownloadConfiguration.standard
        configuration.subtitleDelivery = .sidecarVTT
        configuration.subtitleSelections = [manualSelection]
        configuration.destination = .photos
        configuration = OutputCapabilityMatrix.normalized(configuration)

        #expect(throws: SubtitlePipelineError.photosOnlyDestination) {
            try OutputCapabilityMatrix.validate(
                configuration,
                metadata: fixtureMetadata
            )
        }
    }

    @Test
    func filenameUsesActualMediaBasenameAndTrackOrigin() throws {
        let sidecars = [
            prepared(manualSelection, kind: .webVTT),
            prepared(automaticSelection, kind: .subRip),
        ]
        let names = try SubtitleFilenamePlanner.filenames(
            mediaURL: URL(filePath: "/tmp/Final Media 2.mp4"),
            sidecars: sidecars
        )

        #expect(names == [
            "Final Media 2.en.manual.vtt",
            "Final Media 2.en.auto.srt",
        ])
    }

    @Test
    func filenameSanitizesTraversalReservedAndUnicodeCollisions() throws {
        let first = SubtitleTrackSelection(
            trackID: "subtitle-aaaaaaaaaaaaaaaaaaaaaaaa",
            formatID: "subtitle-format-aaaaaaaaaaaaaaaaaaaaaaaa",
            language: "../CON/e\u{301}n",
            automatic: false
        )
        let second = SubtitleTrackSelection(
            trackID: "subtitle-bbbbbbbbbbbbbbbbbbbbbbbb",
            formatID: "subtitle-format-bbbbbbbbbbbbbbbbbbbbbbbb",
            language: "../CON/én",
            automatic: false
        )
        let names = try SubtitleFilenamePlanner.filenames(
            mediaURL: URL(filePath: "/tmp/CON.mp4"),
            sidecars: [
                prepared(first, kind: .webVTT),
                prepared(second, kind: .webVTT),
            ]
        )
        #expect(Set(names).count == 2)
        #expect(names.allSatisfy { !$0.contains("/") && !$0.contains("\\") })
        #expect(names.allSatisfy { $0.utf8.count <= 240 })
        #expect(names[1].contains("bbbbbbbb"))
    }

    @Test
    func filenameDistinguishesTwoFormatsFromTheSameTrack() throws {
        let alternate = SubtitleTrackSelection(
            trackID: manualSelection.trackID,
            formatID: "subtitle-format-333333333333333333333333",
            language: manualSelection.language,
            automatic: manualSelection.automatic
        )
        let names = try SubtitleFilenamePlanner.filenames(
            mediaURL: URL(filePath: "/tmp/Media.mp4"),
            sidecars: [
                prepared(manualSelection, kind: .webVTT),
                prepared(alternate, kind: .webVTT),
            ]
        )

        #expect(Set(names).count == 2)
        #expect(names[1].contains("11111111-33333333"))
    }

    @Test
    func preservesNormalizedVTTWithRequiredStructures() throws {
        let source = "\u{feff}WEBVTT Fixture\r\n\r\n"
            + "NOTE ignored metadata\r\nline\r\n\r\n"
            + "STYLE\r\n::cue { color: lime; }\r\n\r\n"
            + "REGION\r\nid:main\r\n\r\n"
            + "cue-one\r\n00:01.000 --> 00:02.500 align:start\r\n"
            + "First line\r\nSecond line\r\n\r\n"
            + "01:02:03.004 --> 01:02:04.005\r\nLast\r\n"
        let input = Data(source.utf8)
        let output = try WebVTTProcessor.process(input, as: .webVTT)
        let text = try #require(String(data: output, encoding: .utf8))

        #expect(text.hasPrefix("WEBVTT Fixture\n\n"))
        #expect(!text.contains("\r"))
        #expect(text.contains("NOTE ignored metadata"))
        #expect(text.hasSuffix("Last\n"))
    }

    @Test
    func convertsRealVTTToSequentialSRT() throws {
        let input = Data(
            ("WEBVTT\n\n"
                + "NOTE skip\nanything\n\n"
                + "first\n00:01.000 --> 00:02.500 line:90%\nA\nB\n\n"
                + "01:02:03.004 --> 01:02:04.005\nC\n").utf8
        )
        let output = try WebVTTProcessor.process(input, as: .subRip)
        let text = try #require(String(data: output, encoding: .utf8))

        #expect(
            text == "1\n00:00:01,000 --> 00:00:02,500\nA\nB\n\n"
                + "2\n01:02:03,004 --> 01:02:04,005\nC\n"
        )
        #expect(!text.contains("NOTE"))
        #expect(!text.contains("line:90%"))
    }

    @Test
    func rendersEstablishedYouTubeWebVTTShapeWithinBounds() throws {
        let source = """
        WEBVTT
        Kind: captions
        Language: en

        00:00:00.160 --> 00:00:02.520 align:start position:0%
        <v Speaker>Hello<00:00:01.040><c.colorE5E5E5> world</c></v>

        """
        let input = Data(source.utf8)

        let cues = try WebVTTProcessor.renderingCues(input)
        let cue = try #require(cues.first)

        #expect(cues.count == 1)
        #expect(cue.startSeconds == 0.16)
        #expect(cue.endSeconds == 2.52)
        #expect(cue.text == "Hello world")
    }

    @Test
    func classifiesUnusableBodiesWithoutRetainingContent() {
        let marker = "signed-secret-marker"
        let longWhitespace = String(repeating: " ", count: 1_024)
        let whitespacePrefixedHTML = Data(
            (longWhitespace + "<title>\(marker)</title>").utf8
        )
        let whitespacePrefixedJSON = Data(
            (longWhitespace + "{\"error\":\"\(marker)\"}").utf8
        )
        let cases: [(Data, SubtitleResponseClassification)] = [
            (Data(), .emptyBody),
            (Data("  \n\t".utf8), .emptyBody),
            (
                Data("<!doctype html><html>\(marker)</html>".utf8),
                .HTMLBody
            ),
            (Data("\u{feff}  <h1>error</h1>".utf8), .HTMLBody),
            (whitespacePrefixedHTML, .HTMLBody),
            (Data("{\"error\":\"\(marker)\"}".utf8), .JSONBody),
            (Data("\"\(marker)\"".utf8), .JSONBody),
            (whitespacePrefixedJSON, .JSONBody),
            (Data("<?xml version=\"1.0\"?><error/>".utf8), .XMLBody),
            (Data("<!-- XML comment --><error/>".utf8), .XMLBody),
            (Data("plain \(marker)".utf8), .otherNonWebVTTBody),
            (Data([0xff, 0xfe, 0x00, 0x01]), .otherNonWebVTTBody),
            (
                Data(
                    ("WEBVTT\n\n00:02.000 --> 00:01.000\n"
                        + "Backwards\n").utf8
                ),
                .webVTTParserRejected
            ),
            (
                Data(
                    ("\u{feff}WEBVTT\n\n00:02.000 --> 00:01.000\n"
                        + "Backwards\n").utf8
                ),
                .webVTTParserRejected
            ),
        ]

        for (body, classification) in cases {
            do {
                _ = try WebVTTProcessor.processTransportResponse(
                    body,
                    as: .webVTT
                )
                Issue.record("Expected classified subtitle rejection")
            } catch let error as SubtitlePipelineError {
                #expect(error == .unusableResponse(classification))
                #expect(error.diagnosticCode == classification.diagnosticCode)
                #expect(!error.localizedDescription.contains(marker))
            } catch {
                Issue.record("Unexpected error type")
            }
        }
    }

    @Test(arguments: [
        "",
        "not vtt",
        "<html>error</html>",
        "{\"error\":true}",
        "WEBVTT\n\n00:99.000 --> 01:00.000\nBad\n",
        "WEBVTT\n\n00:02.000 --> 00:01.000\nBackwards\n",
        "WEBVTT\n\nidentifier only\n",
        "WEBVTT\n",
    ])
    func rejectsMalformedWebVTT(_ value: String) {
        #expect(throws: SubtitlePipelineError.self) {
            try WebVTTProcessor.process(Data(value.utf8), as: .subRip)
        }
    }

    @Test
    func rejectsOversizedAndBinaryBodies() {
        #expect(throws: SubtitlePipelineError.responseTooLarge) {
            try WebVTTProcessor.process(
                Data(repeating: 65, count: WebVTTProcessor.maximumInputBytes + 1),
                as: .webVTT
            )
        }
        #expect(throws: SubtitlePipelineError.invalidWebVTT) {
            try WebVTTProcessor.process(
                Data([0xff, 0xfe, 0x00, 0x01]),
                as: .webVTT
            )
        }
    }

    @Test(arguments: [
        "0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1",
        "169.254.1.1", "172.16.0.1", "192.168.0.1", "192.0.2.1",
        "198.18.0.1", "198.51.100.1", "203.0.113.1", "224.0.0.1",
        "255.255.255.255", "::", "::1", "fe80::1", "fc00::1",
        "ff02::1", "64:ff9b::7f00:1", "100::1", "2001::1",
        "2001:db8::1", "2002:7f00:1::1", "3fff::1", "5f00::1",
        "::ffff:127.0.0.1",
    ])
    func rejectsNonPublicAddresses(_ value: String) throws {
        let address = try #require(SubtitleIPAddress(value))
        #expect(!address.isPublic)
    }

    @Test
    func acceptsOnlyGlobalPublicAddressExamples() throws {
        #expect(try #require(SubtitleIPAddress("1.1.1.1")).isPublic)
        #expect(try #require(SubtitleIPAddress("2606:4700:4700::1111")).isPublic)
    }

    #if DEBUG
    // The synthetic native DNS answer-chain helper is Debug-only.
    @Test
    func nativeResolverInspectsCompleteAnswerChainWithinBound() throws {
        let inspection = SystemSubtitleDNSResolver
            .inspectNumericAnswerChainForTesting([
                "1.1.1.1",
                "2606:4700:4700::1111",
                "1.1.1.1",
            ])

        #expect(inspection.status == 0)
        #expect(inspection.addressCount == 2)
        let addresses = try SystemSubtitleDNSResolver.addresses(
            nativeStatus: inspection.status,
            output: inspection.output,
            addressCount: inspection.addressCount
        )
        #expect(addresses.count == 2)
        #expect(addresses.allSatisfy { $0.isPublic })
    }

    @Test
    func nativeResolverFailsClosedWhenOutputCannotContainCompleteChain() {
        let inspection = SystemSubtitleDNSResolver
            .inspectNumericAnswerChainForTesting(
                ["1.1.1.1", "8.8.8.8"],
                outputCapacity: 8
            )

        #expect(inspection.status != 0)
        #expect(inspection.addressCount == 0)
        #expect(inspection.output.isEmpty)
        #expect(throws: SubtitlePipelineError.DNSResolutionFailed) {
            try SystemSubtitleDNSResolver.addresses(
                nativeStatus: inspection.status,
                output: inspection.output,
                addressCount: inspection.addressCount
            )
        }
    }

    @Test
    func nativeResolverCannotHideProhibitedThirtyThirdUniqueAddress() throws {
        let acceptable = (1...32).map { "1.0.0.\($0)" }
        #expect(
            try acceptable.allSatisfy {
                try #require(SubtitleIPAddress($0)).isPublic
            }
        )
        let prohibited = "127.0.0.1"
        #expect(!((try #require(SubtitleIPAddress(prohibited))).isPublic))

        let inspection = SystemSubtitleDNSResolver
            .inspectNumericAnswerChainForTesting(
                acceptable + [prohibited]
            )

        #expect(inspection.status != 0)
        #expect(inspection.addressCount == 0)
        #expect(inspection.output.isEmpty)
        #expect(throws: SubtitlePipelineError.DNSResolutionFailed) {
            try SystemSubtitleDNSResolver.addresses(
                nativeStatus: inspection.status,
                output: inspection.output,
                addressCount: inspection.addressCount
            )
        }
    }
    #endif

    @Test
    func rejectsMixedPublicPrivateDNSAnswers() async {
        let transport = SecureSubtitleTransport(
            resolver: ScriptedSubtitleDNS([
                "captions.example": [["1.1.1.1", "10.0.0.1"]],
            ]),
            networking: ScriptedSubtitleHTTP([])
        )
        await #expect(throws: SubtitlePipelineError.unsafeDestination) {
            try await transport.download(
                from: URL(string: "https://captions.example/track.vtt")!
            )
        }
    }

    @Test
    func validatesRedirectsAndRejectsDowngrade() async throws {
        let HTTP = ScriptedSubtitleHTTP([
            .response(
                SubtitleHTTPResponse(
                    statusCode: 302,
                    headers: ["Location": "https://edge.example/track.vtt"],
                    body: Data()
                )
            ),
            .response(successResponse),
        ])
        let transport = SecureSubtitleTransport(
            resolver: ScriptedSubtitleDNS([
                "captions.example": [["1.1.1.1"]],
                "edge.example": [["8.8.8.8"]],
            ]),
            networking: HTTP
        )
        let body = try await transport.download(
            from: URL(string: "https://captions.example/start")!
        )
        #expect(body == successResponse.body)

        let downgrade = SecureSubtitleTransport(
            resolver: ScriptedSubtitleDNS([
                "captions.example": [["1.1.1.1"]],
            ]),
            networking: ScriptedSubtitleHTTP([
                .response(
                    SubtitleHTTPResponse(
                        statusCode: 302,
                        headers: ["Location": "http://edge.example/track.vtt"],
                        body: Data()
                    )
                ),
            ])
        )
        await #expect(throws: SubtitlePipelineError.insecureRedirect) {
            try await downgrade.download(
                from: URL(string: "https://captions.example/start")!
            )
        }
    }

    @Test
    func rejectsRedirectLoopsAndLimits() async {
        let redirects = (0...4).map { index in
            ScriptedHTTPStep.response(
                SubtitleHTTPResponse(
                    statusCode: 302,
                    headers: [
                        "Location": "https://captions.example/\(index + 1)",
                    ],
                    body: Data()
                )
            )
        }
        let transport = SecureSubtitleTransport(
            resolver: ScriptedSubtitleDNS([
                "captions.example": [["1.1.1.1"]],
            ]),
            networking: ScriptedSubtitleHTTP(redirects)
        )
        await #expect(throws: SubtitlePipelineError.tooManyRedirects) {
            try await transport.download(
                from: URL(string: "https://captions.example/0")!
            )
        }
    }

    @Test
    func rejectsDNSRebindingAndDisjointAnswerChanges() async {
        let privateRebind = SecureSubtitleTransport(
            resolver: ScriptedSubtitleDNS([
                "captions.example": [["1.1.1.1"], ["127.0.0.1"]],
            ]),
            networking: ScriptedSubtitleHTTP([.response(successResponse)])
        )
        await #expect(throws: SubtitlePipelineError.unsafeDestination) {
            try await privateRebind.download(
                from: URL(string: "https://captions.example/track")!
            )
        }

        let disjoint = SecureSubtitleTransport(
            resolver: ScriptedSubtitleDNS([
                "captions.example": [["1.1.1.1"], ["8.8.8.8"]],
            ]),
            networking: ScriptedSubtitleHTTP([.response(successResponse)])
        )
        await #expect(throws: SubtitlePipelineError.DNSAnswerChanged) {
            try await disjoint.download(
                from: URL(string: "https://captions.example/track")!
            )
        }

        let chainedDisjoint = SecureSubtitleTransport(
            resolver: ScriptedSubtitleDNS([
                "captions.example": [
                    ["1.1.1.1", "8.8.8.8"],
                    ["8.8.8.8", "9.9.9.9"],
                    ["9.9.9.9"],
                ],
            ]),
            networking: ScriptedSubtitleHTTP([
                .response(
                    SubtitleHTTPResponse(
                        statusCode: 302,
                        headers: [
                            "Location": "https://captions.example/final",
                        ],
                        body: Data()
                    )
                ),
                .response(successResponse),
            ])
        )
        await #expect(throws: SubtitlePipelineError.DNSAnswerChanged) {
            try await chainedDisjoint.download(
                from: URL(string: "https://captions.example/start")!
            )
        }
    }

    @Test
    func enforcesStatusSizeTimeoutAndDefaultTLSPolicy() async {
        let policy = SubtitleSessionPolicy.secure
        #expect(policy.requestTimeout == 15)
        #expect(policy.resourceTimeout == 45)
        #expect(!policy.acceptsCookies)
        #expect(!policy.usesCredentialStorage)
        #expect(!policy.usesURLCache)
        #expect(policy.usesDefaultTLSVerification)

        let HTTP = ScriptedSubtitleHTTP([
            .response(
                SubtitleHTTPResponse(
                    statusCode: 500,
                    headers: [:],
                    body: Data("failure".utf8)
                )
            ),
        ])
        let transport = SecureSubtitleTransport(
            resolver: ScriptedSubtitleDNS([
                "captions.example": [["1.1.1.1"]],
            ]),
            networking: HTTP,
            policy: policy
        )
        await #expect(throws: SubtitlePipelineError.HTTPFailure) {
            try await transport.download(
                from: URL(string: "https://captions.example/track")!
            )
        }
        #expect(await HTTP.requestTimeouts == [15])
    }

    @Test
    func classifiesSuccessfulEmptyTransportResponse() async {
        let transport = SecureSubtitleTransport(
            resolver: ScriptedSubtitleDNS([
                "captions.example": [["1.1.1.1"]],
            ]),
            networking: ScriptedSubtitleHTTP([
                .response(
                    SubtitleHTTPResponse(
                        statusCode: 200,
                        headers: ["Content-Type": "text/vtt"],
                        body: Data()
                    )
                ),
            ])
        )

        await #expect(
            throws: SubtitlePipelineError.unusableResponse(.emptyBody)
        ) {
            try await transport.download(
                from: URL(
                    string: "https://captions.example/empty.vtt"
                )!
            )
        }
    }

    @Test
    func errorsNeverRevealTransportURL() {
        for error in [
            SubtitlePipelineError.unsafeDestination,
            .DNSResolutionFailed,
            .DNSAnswerChanged,
            .expiredTransport,
            .HTTPFailure,
            .invalidWebVTT,
            .unusableResponse(.emptyBody),
            .unusableResponse(.HTMLBody),
            .unusableResponse(.JSONBody),
            .unusableResponse(.XMLBody),
            .unusableResponse(.otherNonWebVTTBody),
            .unusableResponse(.webVTTParserRejected),
        ] {
            let message = error.localizedDescription.lowercased()
            #expect(!message.contains("https://"))
            #expect(!message.contains("token"))
            #expect(!message.contains("signature"))
            #expect(!error.diagnosticCode.contains("https"))
        }
    }

    @Test
    func expiredURLReextractsAndExactlyRematchesOnce() async throws {
        let transport = ScriptedSubtitleTransport([
            .failure(.expiredTransport),
            .success(validVTT),
        ])
        let extractor = SubtitleFixtureExtractor([fixtureMetadata])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workflow = SubtitleSidecarWorkflow(
            transport: transport,
            exporter: ExportManager(documentsRootURL: root),
            fileManager: .default,
            maximumRefreshAttempts: 1
        )
        let plans = try plansForManualVTT()

        let prepared = try await workflow.prepare(
            plans: plans,
            sourceURL: fixtureMetadata.canonicalURL,
            expectedVideoID: fixtureMetadata.videoID,
            extractor: extractor,
            temporaryRoot: root
        )

        #expect(prepared.count == 1)
        #expect(prepared[0].selection == manualSelection)
        #expect(await transport.callCount == 2)
        #expect(extractor.callCount == 1)
        #expect(
            FileManager.default.fileExists(
                atPath: prepared[0].temporaryURL.path
            )
        )
    }

    @Test
    func unusableBodyNeverSubstitutesARefreshedDifferentVideo() async {
        let refreshedMetadata = metadata(
            subtitles: fixtureMetadata.subtitles,
            videoID: "different-video-id"
        )
        let transport = ScriptedSubtitleTransport([
            .success(Data("<html>expired</html>".utf8)),
            .success(validVTT),
        ])
        let extractor = SubtitleFixtureExtractor([refreshedMetadata])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workflow = SubtitleSidecarWorkflow(
            transport: transport,
            exporter: ExportManager(documentsRootURL: root)
        )

        await #expect(throws: SubtitlePipelineError.trackUnavailable) {
            try await workflow.prepare(
                plans: try plansForManualVTT(),
                sourceURL: fixtureMetadata.canonicalURL,
                expectedVideoID: fixtureMetadata.videoID,
                extractor: extractor,
                temporaryRoot: root
            )
        }
        #expect(await transport.callCount == 1)
        #expect(extractor.callCount == 1)
    }

    @Test
    func unusableSuccessfulBodyReextractsAndExactlyRematchesOnce()
        async throws
    {
        let refreshedURL = URL(
            string: "https://captions.example/refreshed.vtt"
        )!
        let refreshedMetadata = metadata(subtitles: [
            track(
                selection: manualSelection,
                name: "English",
                transportURL: refreshedURL
            ),
        ])
        let transport = ScriptedSubtitleTransport([
            .success(Data("{\"error\":true}".utf8)),
            .success(validVTT),
        ])
        let extractor = SubtitleFixtureExtractor([refreshedMetadata])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workflow = SubtitleSidecarWorkflow(
            transport: transport,
            exporter: ExportManager(documentsRootURL: root),
            maximumRefreshAttempts: 1
        )
        let plans = try plansForManualVTT()

        let prepared = try await workflow.prepare(
            plans: plans,
            sourceURL: fixtureMetadata.canonicalURL,
            expectedVideoID: fixtureMetadata.videoID,
            extractor: extractor,
            temporaryRoot: root
        )

        #expect(prepared.count == 1)
        #expect(await transport.callCount == 2)
        #expect(extractor.callCount == 1)
        #expect(
            await transport.requestedURLs
                == [plans[0].transportURL, refreshedURL]
        )
    }

    @Test
    func unusableRefreshBudgetIsStructurallyLimitedToOne() async {
        let transport = ScriptedSubtitleTransport([
            .success(Data("<html>expired</html>".utf8)),
            .success(Data("{\"error\":true}".utf8)),
            .success(validVTT),
        ])
        let extractor = SubtitleFixtureExtractor([fixtureMetadata])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workflow = SubtitleSidecarWorkflow(
            transport: transport,
            exporter: ExportManager(documentsRootURL: root),
            maximumRefreshAttempts: 99
        )

        await #expect(
            throws: SubtitlePipelineError.unusableResponse(.JSONBody)
        ) {
            try await workflow.prepare(
                plans: try plansForManualVTT(),
                sourceURL: fixtureMetadata.canonicalURL,
                expectedVideoID: fixtureMetadata.videoID,
                extractor: extractor,
                temporaryRoot: root
            )
        }
        #expect(await transport.callCount == 2)
        #expect(extractor.callCount == 1)
    }

    @Test
    func parserRejectedWebVTTFailsClosedWithoutPointlessRefresh() async {
        let transport = ScriptedSubtitleTransport([
            .success(
                Data(
                    ("WEBVTT\n\n00:02.000 --> 00:01.000\n"
                        + "Backwards\n").utf8
                )
            ),
        ])
        let extractor = SubtitleFixtureExtractor([fixtureMetadata])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workflow = SubtitleSidecarWorkflow(
            transport: transport,
            exporter: ExportManager(documentsRootURL: root)
        )

        await #expect(
            throws: SubtitlePipelineError.unusableResponse(
                .webVTTParserRejected
            )
        ) {
            try await workflow.prepare(
                plans: try plansForManualVTT(),
                sourceURL: fixtureMetadata.canonicalURL,
                expectedVideoID: fixtureMetadata.videoID,
                extractor: extractor,
                temporaryRoot: root
            )
        }
        #expect(await transport.callCount == 1)
        #expect(extractor.callCount == 0)
    }

    @Test
    func expiredURLNeverSubstitutesMissingTrack() async {
        let transport = ScriptedSubtitleTransport([
            .failure(.expiredTransport),
        ])
        let extractor = SubtitleFixtureExtractor([
            metadata(subtitles: [fixtureMetadata.subtitles[1]]),
        ])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workflow = SubtitleSidecarWorkflow(
            transport: transport,
            exporter: ExportManager(documentsRootURL: root),
            maximumRefreshAttempts: 1
        )

        await #expect(throws: SubtitlePipelineError.trackUnavailable) {
            try await workflow.prepare(
                plans: try plansForManualVTT(),
                sourceURL: fixtureMetadata.canonicalURL,
                expectedVideoID: fixtureMetadata.videoID,
                extractor: extractor,
                temporaryRoot: root
            )
        }
        #expect(await transport.callCount == 1)
    }

    @Test
    func expiredURLRefreshRetryIsStrictlyBounded() async {
        let transport = ScriptedSubtitleTransport([
            .failure(.expiredTransport),
            .failure(.expiredTransport),
            .success(validVTT),
        ])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workflow = SubtitleSidecarWorkflow(
            transport: transport,
            exporter: ExportManager(documentsRootURL: root),
            maximumRefreshAttempts: 1
        )

        await #expect(throws: SubtitlePipelineError.expiredTransport) {
            try await workflow.prepare(
                plans: try plansForManualVTT(),
                sourceURL: fixtureMetadata.canonicalURL,
                expectedVideoID: fixtureMetadata.videoID,
                extractor: SubtitleFixtureExtractor([fixtureMetadata]),
                temporaryRoot: root
            )
        }
        #expect(await transport.callCount == 2)
    }

    @Test
    func conversionFailureAndCancellationPublishNoPartials() async {
        let invalidTransport = ScriptedSubtitleTransport([
            .success(Data("not-vtt".utf8)),
        ])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workflow = SubtitleSidecarWorkflow(
            transport: invalidTransport,
            exporter: ExportManager(documentsRootURL: root),
            maximumRefreshAttempts: 0
        )
        await #expect(
            throws: SubtitlePipelineError.unusableResponse(
                .otherNonWebVTTBody
            )
        ) {
            try await workflow.prepare(
                plans: try plansForManualVTT(),
                sourceURL: fixtureMetadata.canonicalURL,
                expectedVideoID: fixtureMetadata.videoID,
                extractor: SubtitleFixtureExtractor([fixtureMetadata]),
                temporaryRoot: root
            )
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []
        #expect(contents.allSatisfy { !$0.lastPathComponent.contains("partial") })

        let cancellable = SubtitleSidecarWorkflow(
            transport: CancellableSubtitleTransport(),
            exporter: ExportManager(documentsRootURL: root)
        )
        let task = Task {
            try await cancellable.prepare(
                plans: try plansForManualVTT(),
                sourceURL: fixtureMetadata.canonicalURL,
                expectedVideoID: fixtureMetadata.videoID,
                extractor: SubtitleFixtureExtractor([fixtureMetadata]),
                temporaryRoot: root
            )
        }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        let afterCancellation = (try? FileManager.default
            .contentsOfDirectory(
                at: root.appending(path: "Subtitles"),
                includingPropertiesForKeys: nil
            )) ?? []
        #expect(afterCancellation.isEmpty)
    }

    @Test
    func sidecarsFollowCollisionAdjustedMediaAndNeverOverwrite() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let temporary = root.appending(path: "Temporary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: documents,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        try Data("existing".utf8).write(to: documents.appending(path: "Media.mp4"))
        let source = temporary.appending(path: "source.mp4")
        try Data("media".utf8).write(to: source)
        let sidecar = temporary.appending(path: "source.vtt")
        try validVTT.write(to: sidecar)
        let exporter = ExportManager(documentsRootURL: documents)
        let job = fixtureJob(destination: .appDocuments)
        let mediaResult = try await exporter.export(
            sourceURL: source,
            destination: .appDocuments,
            filename: "Media",
            folderBookmark: nil,
            duplicateHandling: .addNumber,
            videoID: job.videoID,
            jobID: job.id,
            title: job.title,
            assetKind: .video
        )
        let workflow = SubtitleSidecarWorkflow(
            transport: ScriptedSubtitleTransport([]),
            exporter: exporter
        )
        let prepared = [
            PreparedSubtitleSidecar(
                selection: manualSelection,
                kind: .webVTT,
                temporaryURL: sidecar
            ),
        ]
        let result = try await workflow.export(
            prepared,
            mediaResult: mediaResult,
            job: job,
            folderBookmark: nil
        )
        let URL = try #require(result.records.first?.localURL)
        #expect(mediaResult.fileURL?.lastPathComponent == "Media 2.mp4")
        #expect(URL.lastPathComponent == "Media 2.en.manual.vtt")

        await #expect(throws: SubtitlePipelineError.sidecarCollision) {
            try await workflow.export(
                prepared,
                mediaResult: mediaResult,
                job: job,
                folderBookmark: nil
            )
        }
        #expect(try Data(contentsOf: URL) == validVTT)
    }

    @Test
    func shareRequestTruthfullyContainsMediaAndSidecarsAndCleansUp() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.mp4")
        let sidecar = root.appending(path: "source.srt")
        try Data("media".utf8).write(to: source)
        try Data("1\n00:00:00,000 --> 00:00:01,000\nText\n".utf8)
            .write(to: sidecar)
        let shareRoot = root.appending(path: "Shares", directoryHint: .isDirectory)
        let exporter = ExportManager(
            documentsRootURL: root,
            shareRootURL: shareRoot
        )
        let job = fixtureJob(destination: .share)
        let mediaResult = try await exporter.export(
            sourceURL: source,
            destination: .share,
            filename: "Shared",
            folderBookmark: nil,
            duplicateHandling: .addNumber,
            videoID: job.videoID,
            jobID: job.id,
            title: job.title,
            assetKind: .video
        )
        let workflow = SubtitleSidecarWorkflow(
            transport: ScriptedSubtitleTransport([]),
            exporter: exporter
        )
        let exported = try await workflow.export(
            [
                PreparedSubtitleSidecar(
                    selection: manualSelection,
                    kind: .subRip,
                    temporaryURL: sidecar
                ),
            ],
            mediaResult: mediaResult,
            job: job,
            folderBookmark: nil
        )
        #expect(exported.shareRequest?.fileURLs.count == 2)
        #expect(exported.shareRequest?.fileURLs.map(\.pathExtension).sorted() == [
            "mp4", "srt",
        ])
        try await exporter.finishShare(jobID: job.id, state: .completed)
        #expect(await exporter.pendingShareRequest(jobID: job.id, title: job.title) == nil)
    }

    @Test
    func filesAndPhotosKeepsSidecarBesideActualFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(
            path: "Files",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let source = root.appending(path: "source.mp4")
        let sidecar = root.appending(path: "source.vtt")
        try Data("media".utf8).write(to: source)
        try validVTT.write(to: sidecar)
        let exporter = ExportManager(
            photoLibrary: SubtitleFixturePhotoLibrary(),
            documentsRootURL: root
        )
        let bookmark = try await exporter.bookmark(for: folder)
        let job = fixtureJob(destination: .filesAndPhotos)
        let mediaResult = try await exporter.export(
            sourceURL: source,
            destination: .filesAndPhotos,
            filename: "Combined",
            folderBookmark: bookmark,
            duplicateHandling: .addNumber,
            videoID: job.videoID,
            jobID: job.id,
            title: job.title,
            assetKind: .video
        )
        let workflow = SubtitleSidecarWorkflow(
            transport: ScriptedSubtitleTransport([]),
            exporter: exporter
        )
        let exported = try await workflow.export(
            [
                PreparedSubtitleSidecar(
                    selection: manualSelection,
                    kind: .webVTT,
                    temporaryURL: sidecar
                ),
            ],
            mediaResult: mediaResult,
            job: job,
            folderBookmark: bookmark
        )
        let mediaURL = try #require(mediaResult.fileURL)
        let subtitleURL = try #require(exported.records.first?.localURL)
        #expect(mediaResult.outcome == .filesAndPhotos)
        #expect(mediaResult.photoAssetLocalIdentifiers == ["fixture-photo"])
        #expect(subtitleURL.deletingLastPathComponent() == mediaURL.deletingLastPathComponent())
        #expect(subtitleURL.lastPathComponent == "Combined.en.manual.vtt")
    }

    @Test
    func optionalSidecarFieldsMigrateWithoutRemoteURLs() throws {
        var configuration = DownloadConfiguration.standard
        configuration.subtitleDelivery = .sidecarVTT
        configuration.subtitleSelections = [manualSelection]
        var job = fixtureJob(destination: .appDocuments)
        job.configuration = configuration
        job.subtitleSidecars = [
            SubtitleSidecarRecord(
                selection: manualSelection,
                kind: .webVTT,
                filename: "Media.en.manual.vtt",
                localURL: URL(filePath: "/local/Media.en.manual.vtt")
            ),
        ]
        let data = try JSONEncoder.illucetEncoder.encode(job)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("captions.example"))
        #expect(!text.contains("transportURL"))

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "subtitleSidecars")
        var oldConfiguration = try #require(
            object["configuration"] as? [String: Any]
        )
        oldConfiguration.removeValue(forKey: "subtitleSelections")
        object["configuration"] = oldConfiguration
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let migrated = try JSONDecoder.illucetDecoder.decode(
            DownloadJob.self,
            from: oldData
        )
        #expect(migrated.subtitleSidecars == nil)
        #expect(migrated.configuration.subtitleSelections == nil)

        let historyData = try JSONEncoder.illucetEncoder.encode(
            HistoryRecord(job: job)
        )
        var historyObject = try #require(
            JSONSerialization.jsonObject(with: historyData) as? [String: Any]
        )
        historyObject.removeValue(forKey: "subtitleSidecars")
        let oldHistoryData = try JSONSerialization.data(
            withJSONObject: historyObject
        )
        let migratedHistory = try JSONDecoder.illucetDecoder.decode(
            HistoryRecord.self,
            from: oldHistoryData
        )
        #expect(migratedHistory.subtitleSidecars == nil)
        #expect(migratedHistory.ownedFileURLs == [])
    }

    @Test
    func playlistChildStateAndNamesRemainIndependent() throws {
        var first = fixtureJob(destination: .appDocuments)
        var second = fixtureJob(destination: .appDocuments)
        first.subtitleSidecars = [
            SubtitleSidecarRecord(
                selection: manualSelection,
                kind: .webVTT,
                filename: "001 Item.en.manual.vtt",
                localURL: URL(filePath: "/batch/001 Item.en.manual.vtt")
            ),
        ]
        second.subtitleSidecars = [
            SubtitleSidecarRecord(
                selection: automaticSelection,
                kind: .subRip,
                filename: "002 Item.en.auto.srt",
                localURL: URL(filePath: "/batch/002 Item.en.auto.srt")
            ),
        ]
        #expect(first.subtitleSidecars != second.subtitleSidecars)
        #expect(Set(first.subtitleSidecars!.map(\.filename)).isDisjoint(
            with: Set(second.subtitleSidecars!.map(\.filename))
        ))
    }

    private let validVTT = Data(
        "WEBVTT\n\n00:00.000 --> 00:01.000\nText\n".utf8
    )

    private var successResponse: SubtitleHTTPResponse {
        SubtitleHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/vtt"],
            body: validVTT
        )
    }

    private let manualSelection = SubtitleTrackSelection(
        trackID: "subtitle-111111111111111111111111",
        formatID: "subtitle-format-111111111111111111111111",
        language: "en",
        automatic: false
    )

    private let automaticSelection = SubtitleTrackSelection(
        trackID: "subtitle-222222222222222222222222",
        formatID: "subtitle-format-222222222222222222222222",
        language: "en",
        automatic: true
    )

    private var fixtureMetadata: MediaMetadata {
        metadata(subtitles: [
            track(selection: manualSelection, name: "English"),
            track(selection: automaticSelection, name: "English automatic"),
        ])
    }

    private func track(
        selection: SubtitleTrackSelection,
        name: String,
        transportURL: URL = URL(
            string: "https://captions.example/fixture.vtt"
        )!
    ) -> MediaSubtitleTrack {
        MediaSubtitleTrack(
            trackID: selection.trackID,
            language: selection.language,
            name: name,
            automatic: selection.automatic,
            formats: [
                MediaSubtitleFormat(
                    formatID: selection.formatID,
                    url: transportURL,
                    extension: "vtt",
                    name: "WebVTT"
                ),
            ]
        )
    }

    private func metadata(
        subtitles: [MediaSubtitleTrack],
        videoID: String? = nil
    ) -> MediaMetadata {
        let base = DeveloperFixtures.media
        return MediaMetadata(
            canonicalURL: base.canonicalURL,
            videoID: videoID ?? base.videoID,
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
            subtitles: subtitles,
            formats: base.formats
        )
    }

    private func plansForManualVTT() throws -> [SubtitleDownloadPlan] {
        var configuration = DownloadConfiguration.standard
        configuration.subtitleDelivery = .sidecarVTT
        configuration.subtitleSelections = [manualSelection]
        configuration = OutputCapabilityMatrix.normalized(configuration)
        return try SubtitleSelectionPlanner.plans(
            configuration: configuration,
            metadata: fixtureMetadata
        )
    }

    private func prepared(
        _ selection: SubtitleTrackSelection,
        kind: SubtitleSidecarKind
    ) -> PreparedSubtitleSidecar {
        PreparedSubtitleSidecar(
            selection: selection,
            kind: kind,
            temporaryURL: URL(filePath: "/tmp/fixture.\(kind.rawValue)")
        )
    }

    private func fixtureJob(
        destination: ExportDestination
    ) -> DownloadJob {
        var configuration = DownloadConfiguration.standard
        configuration.destination = destination
        configuration.subtitleDelivery = .sidecarVTT
        configuration.subtitleSelections = [manualSelection]
        configuration = OutputCapabilityMatrix.normalized(configuration)
        return DownloadJob(
            id: UUID(),
            sourceURL: fixtureMetadata.canonicalURL,
            videoID: fixtureMetadata.videoID,
            title: "Fixture",
            channel: "Fixture",
            thumbnailURL: nil,
            createdAt: .now,
            updatedAt: .now,
            configuration: configuration,
            state: .running,
            stage: .savingFiles,
            progress: .zero,
            priority: 0,
            retryCount: 0,
            maximumRetries: 1,
            errorCode: nil,
            errorMessage: nil,
            outputURL: nil,
            outputProbe: nil,
            selectedFormatIDs: ["18"],
            extractorVersion: "fixture"
        )
    }

    private func temporaryDirectory() -> URL {
        let URL = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-P8-C2-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try? FileManager.default.createDirectory(
            at: URL,
            withIntermediateDirectories: true
        )
        return URL
    }
}
