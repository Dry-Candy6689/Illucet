import Foundation
import Testing
@testable import Illucet

struct LiveExtractionTests {
    @Test
    func extractionHandoffTokenIsDecodedButNeverPersisted() throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(validResponse.utf8)) as? [String: Any])
        var data = try #require(object["data"] as? [String: Any])
        data["reuse_token"] = "opaque-in-process-handoff"
        object["data"] = data
        let response = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let decoded = try YTDLPExtractorEngine.decodeExtractionResponse(response)
        #expect(decoded.reuseToken == "opaque-in-process-handoff")
        let persisted = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!persisted.contains("opaque-in-process-handoff"))
        #expect(!persisted.contains("reuse_token"))
    }

    @Test
    func normalizesSupportedYouTubeURLsToOneCanonicalForm() throws {
        let inputs = [
            "https://youtu.be/AbCdEf123_-?si=sensitive#fragment",
            "http://www.youtube.com/watch?v=AbCdEf123_-"
                + "&list=PL-secret&t=42&utm_source=tracker",
            "https://m.youtube.com/shorts/AbCdEf123_-?feature=share",
            "https://music.youtube.com/watch?list=PL-secret"
                + "&v=AbCdEf123_-&si=sensitive",
            "https://youtube.com/embed/AbCdEf123_-?autoplay=1",
            "https://youtube.com/live/AbCdEf123_-?si=sensitive",
        ]

        for input in inputs {
            let url = try #require(URL(string: input))
            let normalized = try YTDLPExtractorEngine.normalizedYouTubeURL(url)

            #expect(
                normalized.absoluteString ==
                    "https://www.youtube.com/watch?v=AbCdEf123_-",
                "Unexpected canonical form for \(input)"
            )
            #expect(normalized.scheme == "https")
            #expect(normalized.host() == "www.youtube.com")
            #expect(normalized.path == "/watch")
            #expect(
                URLComponents(
                    url: normalized,
                    resolvingAgainstBaseURL: false
                )?.queryItems == [
                    URLQueryItem(name: "v", value: "AbCdEf123_-"),
                ]
            )
        }
    }

    @Test
    func stripsPlaylistAndTrackingParametersWithoutChangingVideoID() throws {
        let url = try #require(
            URL(
                string:
                    "https://www.youtube.com/watch?"
                    + "si=secret&list=PL-secret&index=99"
                    + "&v=dQw4w9WgXcQ&pp=tracking&t=43s"
            )
        )

        let normalized = try YTDLPExtractorEngine.normalizedYouTubeURL(url)

        #expect(
            normalized.absoluteString ==
                "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )
        for removedValue in [
            "secret",
            "PL-secret",
            "99",
            "tracking",
            "43s",
        ] {
            #expect(!normalized.absoluteString.contains(removedValue))
        }
    }

    @Test
    func rejectsUnsupportedHosts() throws {
        let inputs = [
            "https://example.com/watch?v=AbCdEf123_-",
            "https://youtube.com.example.com/watch?v=AbCdEf123_-",
            "https://youtu.be.example.com/AbCdEf123_-",
            "https://www.youtube-nocookie.com/embed/AbCdEf123_-",
        ]

        for input in inputs {
            let url = try #require(URL(string: input))
            #expect(throws: ExtractionError.unsupportedSite) {
                try YTDLPExtractorEngine.normalizedYouTubeURL(url)
            }
        }
    }

    @Test
    func rejectsNonVideoYouTubePaths() throws {
        let inputs = [
            "https://youtube.com/",
            "https://youtube.com/watch",
            "https://youtube.com/watch?list=PL-secret",
            "https://youtube.com/playlist?list=PL-secret",
            "https://youtube.com/channel/UC1234567890",
            "https://youtube.com/@fixture",
            "https://youtu.be/",
            "https://youtube.com/results?search_query=fixture",
        ]

        for input in inputs {
            let url = try #require(URL(string: input))
            #expect(throws: ExtractionError.invalidURL) {
                try YTDLPExtractorEngine.normalizedYouTubeURL(url)
            }
        }
    }

    @Test
    func rejectsMalformedAndNonASCIIVideoIDs() throws {
        let inputs = [
            "https://youtube.com/watch?v=too-short",
            "https://youtube.com/watch?v=AbCdEf123_-x",
            "https://youtube.com/watch?v=AbCdÉf123_-",
            "https://youtube.com/watch?v=AbCdEf123_!",
            "https://youtu.be/AbCdEf123_%2F",
        ]

        for input in inputs {
            let url = try #require(URL(string: input))
            #expect(throws: ExtractionError.invalidURL) {
                try YTDLPExtractorEngine.normalizedYouTubeURL(url)
            }
        }
    }

    @Test
    func typedLiveRequestCannotEnableDownloads() throws {
        let request = LiveExtractionRequest(
            url: "https://www.youtube.com/watch?v=AbCdEf123_-"
        )
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(request)
            ) as? [String: Any]
        )

        #expect(object["action"] as? String == "extract_metadata")
        #expect(object["download"] as? Bool == false)
        #expect(
            object["url"] as? String ==
                "https://www.youtube.com/watch?v=AbCdEf123_-"
        )
    }

    @Test
    func installedGenerationRequiresItsOwnExactVersionAndAssetEvidence() throws {
        let version = "2099.12.30.235959"
        let response = validResponse.replacingOccurrences(of: DependencyVersions.ytDLP, with: version)
        let requested = try #require(URL(string: "https://youtu.be/AbCdEf123_-"))
        let contract = LiveExtractorContract(ytDLP: version, ejs: DependencyVersions.ejs,
            quickJS: DependencyVersions.quickJS,
            ejsCoreSHA3512: LiveExtractionValidator.expectedEJSCoreSHA3512,
            ejsLibrarySHA3512: LiveExtractionValidator.expectedEJSLibrarySHA3512)
        #expect(throws: ExtractionError.self) {
            try YTDLPExtractorEngine.decodeAndValidateExtractionResponse(response, requestedURL: requested)
        }
        _ = try YTDLPExtractorEngine.decodeAndValidateExtractionResponse(response,
            requestedURL: requested, contract: contract)
        let wrongAsset = response.replacingOccurrences(of: LiveExtractionValidator.expectedEJSCoreSHA3512,
                                                       with: String(repeating: "a", count: 128))
        #expect(throws: ExtractionError.self) {
            try YTDLPExtractorEngine.decodeAndValidateExtractionResponse(wrongAsset,
                requestedURL: requested, contract: contract)
        }
    }

    @Test
    func decodesAndValidatesSanitizedLiveMetadata() throws {
        let extraction = try YTDLPExtractorEngine.decodeExtractionResponse(
            validResponse
        )
        let requested = try #require(
            URL(string: "https://youtu.be/AbCdEf123_-?si=redacted")
        )
        let validation = LiveExtractionValidator.validate(
            extraction,
            requestedURL: requested
        )

        #expect(extraction.metadata.title == "Fixture title")
        #expect(extraction.metadata.durationSeconds == 213)
        #expect(extraction.metadata.formats.count == 2)
        #expect(extraction.metadata.formats[0].height == 2160)
        #expect(extraction.metadata.formats[1].fileSize == 3_000_000)
        #expect(extraction.metadata.subtitles.count == 2)
        #expect(extraction.metadata.subtitles[0].language == "en")
        #expect(!extraction.metadata.subtitles[0].automatic)
        #expect(extraction.metadata.subtitles[1].language == "es")
        #expect(extraction.metadata.subtitles[1].automatic)
        #expect(
            extraction.metadata.subtitles[0].trackID !=
                extraction.metadata.subtitles[1].trackID
        )
        #expect(
            extraction.metadata.subtitles[0].formats[0].url ==
                URL(
                    string:
                        "https://captions.example.invalid/manual/en.vtt"
                )
        )
        #expect(validation.identityIsValid)
        #expect(validation.thumbnailIsValid)
        #expect(validation.formatsAreValid)
        #expect(validation.providerPathIsValid)
        #expect(validation.issues.isEmpty)
    }

    @Test
    func subtitleTransportContractRejectsUnsafeAndAmbiguousRecords() throws {
        let cases: [(label: String, response: String)] = [
            (
                "non-HTTPS",
                validResponse.replacingOccurrences(
                    of:
                        "https://captions.example.invalid/manual/en.vtt",
                    with:
                        "http://captions.example.invalid/manual/en.vtt"
                )
            ),
            (
                "credentials",
                validResponse.replacingOccurrences(
                    of:
                        "https://captions.example.invalid/manual/en.vtt",
                    with:
                        "https://user:password@captions.example.invalid/en.vtt"
                )
            ),
            (
                "malformed",
                validResponse.replacingOccurrences(
                    of:
                        "https://captions.example.invalid/manual/en.vtt",
                    with: "not-a-transport-url"
                )
            ),
            (
                "duplicate track identity",
                validResponse.replacingOccurrences(
                    of: "subtitle-222222222222222222222222",
                    with: "subtitle-111111111111111111111111"
                )
            ),
            (
                "duplicate format identity",
                validResponse.replacingOccurrences(
                    of:
                        "subtitle-format-222222222222222222222222",
                    with:
                        "subtitle-format-111111111111111111111111"
                )
            ),
        ]

        for item in cases {
            do {
                _ = try YTDLPExtractorEngine.decodeExtractionResponse(
                    item.response
                )
                Issue.record("\(item.label) unexpectedly decoded.")
            } catch let error as ExtractionError {
                let message = error.localizedDescription
                #expect(message.contains("subtitle"))
                #expect(!message.contains("captions.example.invalid"))
                #expect(!message.contains("user:password"))
            }
        }
    }

    @Test
    func subtitleTransportContractRejectsOversizedAndMissingURLs() {
        let oversized = validResponse.replacingOccurrences(
            of: "https://captions.example.invalid/manual/en.vtt",
            with:
                "https://captions.example.invalid/" +
                String(repeating: "x", count: 4_096)
        )
        let missing = validResponse.replacingOccurrences(
            of:
                #""url": "https://captions.example.invalid/manual/en.vtt","#,
            with: ""
        )
        let typeMismatch = validResponse.replacingOccurrences(
            of:
                #""url": "https://captions.example.invalid/manual/en.vtt","#,
            with:
                #""url": {"value": "https://private.example.invalid/path"},"#
        )

        for response in [oversized, missing, typeMismatch] {
            do {
                _ = try YTDLPExtractorEngine.decodeExtractionResponse(
                    response
                )
                Issue.record("Invalid subtitle URL unexpectedly decoded.")
            } catch let error as ExtractionError {
                let message = error.localizedDescription
                #expect(!message.contains("captions.example.invalid"))
                #expect(!message.contains("private.example.invalid"))
                #expect(!message.contains(String(repeating: "x", count: 32)))
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test
    func typedFormatSchemaDropsSignedMediaTransportFields() throws {
        let response = validResponse.replacingOccurrences(
            of: #""format_id": "video","#,
            with:
                """
                "format_id": "video",
                "url": "https://signed.example/video?token=secret",
                "manifest_url": "https://signed.example/manifest?sig=secret",
                "fragment_base_url": "https://signed.example/fragments/",
                "http_headers": {"Authorization": "Bearer secret"},
                "cookies": "session=secret",
                """
        )

        let extraction = try YTDLPExtractorEngine.decodeExtractionResponse(
            response
        )
        let encoded = try JSONEncoder().encode(extraction)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        let encodedObject = try #require(
            try JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        let metadata = try #require(
            encodedObject["metadata"] as? [String: Any]
        )
        let formats = try #require(metadata["formats"] as? [[String: Any]])
        let forbiddenFormatKeys: Set<String> = [
            "url",
            "manifest_url",
            "fragment_base_url",
            "http_headers",
            "cookies",
            "cookie",
            "headers",
            "fragments",
        ]

        #expect(formats.count == 2)
        for format in formats {
            #expect(
                forbiddenFormatKeys.isDisjoint(with: Set(format.keys)),
                "A transport secret escaped through the typed format schema."
            )
        }
        #expect(!encodedText.contains("signed.example"))
        #expect(!encodedText.contains("Bearer secret"))
        #expect(!encodedText.contains("session=secret"))
        #expect(
            encodedText.contains(
                "https:\\/\\/i.ytimg.com\\/thumbnail.jpg"
            ) ||
                encodedText.contains(
                    "https://i.ytimg.com/thumbnail.jpg"
                ),
            "Public thumbnail URLs remain part of the metadata contract."
        )
    }

    @Test
    func validationFailsForMismatchedIdentityAndUnsafeThumbnail() throws {
        let response = validResponse
            .replacingOccurrences(
                of: #""video_id": "AbCdEf123_-""#,
                with: #""video_id": "ZyXwVu987_-""#
            )
            .replacingOccurrences(
                of: "https://i.ytimg.com/thumbnail.jpg",
                with: "http://i.ytimg.com/thumbnail.jpg"
            )
        let extraction = try YTDLPExtractorEngine.decodeExtractionResponse(
            response
        )
        let requested = try #require(
            URL(string: "https://youtu.be/AbCdEf123_-")
        )

        let validation = LiveExtractionValidator.validate(
            extraction,
            requestedURL: requested
        )

        #expect(!validation.identityIsValid)
        #expect(!validation.thumbnailIsValid)
        #expect(validation.formatsAreValid)
        #expect(validation.issues.count == 2)
    }

    @Test
    func validationRejectsOneUnsafeThumbnailAmongSafeThumbnails() throws {
        let response = try responseByAppendingThumbnail(
            url: "http://i.ytimg.com/unsafe.jpg"
        )
        let extraction = try YTDLPExtractorEngine.decodeExtractionResponse(
            response
        )
        let requested = try #require(
            URL(string: "https://youtu.be/AbCdEf123_-")
        )

        let validation = LiveExtractionValidator.validate(
            extraction,
            requestedURL: requested
        )

        #expect(!validation.thumbnailIsValid)
        #expect(throws: ExtractionError.self) {
            try YTDLPExtractorEngine.decodeAndValidateExtractionResponse(
                response,
                requestedURL: requested
            )
        }
    }

    @Test
    func analysisAcceptsCombinedSourceAndStillVerifiesExactInventory() throws {
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(validResponse.utf8)) as? [String: Any])
        var data = try #require(envelope["data"] as? [String: Any])
        var metadata = try #require(data["metadata"] as? [String: Any])
        let formats = try #require(metadata["formats"] as? [[String: Any]])
        var combined = try #require(formats.first)
        combined["format_id"] = "combined"
        combined["has_audio"] = true
        combined["audio_codec"] = "opus"
        metadata["formats"] = [combined]
        data["metadata"] = metadata
        envelope["data"] = data
        let decoded = try YTDLPExtractorEngine.decodeExtractionResponse(
            String(decoding: JSONSerialization.data(withJSONObject: envelope), as: UTF8.self))
        var evidence = try #require(data["provider_evidence"] as? [String: Any])
        evidence["format_count"] = 1
        evidence["format_inventory_sha256"] = LiveExtractionValidator.formatInventorySHA256(for: decoded.metadata.formats)
        data["provider_evidence"] = evidence
        envelope["data"] = data
        let response = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        let extraction = try YTDLPExtractorEngine.decodeAndValidateExtractionResponse(response,
            requestedURL: #require(URL(string: "https://youtu.be/AbCdEf123_-")))
        var configuration = DownloadConfiguration.standard
        configuration.preset = .best
        FormatSelection.applyAutomaticSelection(to: &configuration, metadata: extraction.metadata)
        #expect(configuration.selectedVideoFormatID == "combined")
        #expect(configuration.selectedAudioFormatID == nil)
    }

    @Test
    func validationFailsForDuplicateOrIncompleteFormats() throws {
        let response = validResponse
            .replacingOccurrences(
                of: #""format_id": "audio""#,
                with: #""format_id": "video""#
            )
            .replacingOccurrences(
                of: #""has_audio": true"#,
                with: #""has_audio": false"#
            )
        let extraction = try YTDLPExtractorEngine.decodeExtractionResponse(
            response
        )
        let requested = try #require(
            URL(string: "https://youtube.com/watch?v=AbCdEf123_-")
        )

        let validation = LiveExtractionValidator.validate(
            extraction,
            requestedURL: requested
        )

        #expect(!validation.formatsAreValid)
        #expect(
            !validation.providerPathIsValid,
            "Changing a typed format must invalidate the inventory digest."
        )
        #expect(
            validation.issues.contains {
                $0.localizedCaseInsensitiveContains("format inventory")
            }
        )
        #expect(throws: ExtractionError.self) {
            try YTDLPExtractorEngine.decodeAndValidateExtractionResponse(
                response,
                requestedURL: requested
            )
        }
    }

    @Test
    func formatInventoryDigestMatchesPythonCanonicalJSON() throws {
        let extraction = try YTDLPExtractorEngine.decodeExtractionResponse(
            validResponse
        )

        #expect(
            LiveExtractionValidator.formatInventorySHA256(
                for: extraction.metadata.formats
            ) ==
                "9167a2d32791cbde263496b24c0b500b1f7c5fc6a78baccc941e04f24e3097f0"
        )
    }

    @Test
    func rankedInventoryMatchesPythonAndRejectsChangedPreference() throws {
        // Golden digest from Python json.dumps(sort_keys=True,
        // ensure_ascii=False, separators=(",", ":")); numeric rates are floats.
        let digest = "dcc95c4c6c8c1a60c2b6718167fdabf44e9974ed2d6ddd8990ea0471c1fdbf46"
        let response = validResponse
            .replacingOccurrences(of: #""format_id": "video""#,
                                  with: #""extractor_preference_rank": 0, "format_id": "video""#)
            .replacingOccurrences(of: #""format_id": "audio""#,
                                  with: #""extractor_preference_rank": 1, "format_id": "audio""#)
            .replacingOccurrences(of: "9167a2d32791cbde263496b24c0b500b1f7c5fc6a78baccc941e04f24e3097f0", with: digest)
        let requested = try #require(URL(string: "https://youtu.be/AbCdEf123_-"))
        let extraction = try YTDLPExtractorEngine.decodeAndValidateExtractionResponse(response, requestedURL: requested)
        #expect(extraction.metadata.formats.map(\.extractorPreferenceRank) == [0, 1])
        #expect(LiveExtractionValidator.formatInventorySHA256(for: extraction.metadata.formats) == digest)
        let changed = response.replacingOccurrences(of: #""extractor_preference_rank": 1"#,
                                                    with: #""extractor_preference_rank": 2"#)
        #expect(throws: ExtractionError.self) {
            try YTDLPExtractorEngine.decodeAndValidateExtractionResponse(changed, requestedURL: requested)
        }
        #expect(!LiveExtractionValidator.validate(
            try YTDLPExtractorEngine.decodeExtractionResponse(response.replacingOccurrences(
                of: #""extractor_preference_rank": 0"#, with: #""extractor_preference_rank": -1"#)),
            requestedURL: requested).formatsAreValid)
    }

    @Test
    func productionValidationRejectsMismatchedFormatInventoryDigest() throws {
        let response = validResponse.replacingOccurrences(
            of:
                "9167a2d32791cbde263496b24c0b500b1f7c5fc6a78baccc941e04f24e3097f0",
            with: String(repeating: "0", count: 64)
        )
        let requested = try #require(
            URL(string: "https://youtu.be/AbCdEf123_-")
        )

        #expect(throws: ExtractionError.self) {
            try YTDLPExtractorEngine.decodeAndValidateExtractionResponse(
                response,
                requestedURL: requested
            )
        }
    }

    @Test
    func productionValidationRejectsExternalJavaScriptRuntime() throws {
        let response = validResponse.replacingOccurrences(
            of: #""external_js_runtimes_enabled": false"#,
            with: #""external_js_runtimes_enabled": true"#
        )
        let requested = try #require(
            URL(string: "https://youtu.be/AbCdEf123_-")
        )

        #expect(throws: ExtractionError.self) {
            try YTDLPExtractorEngine.decodeAndValidateExtractionResponse(
                response,
                requestedURL: requested
            )
        }
    }

    @Test
    func providerProofAllowsConsistentNoChallengeExtraction() throws {
        let response = noChallengeResponse(providerWasConstructed: true)
        let extraction = try YTDLPExtractorEngine.decodeExtractionResponse(
            response
        )
        let requested = try #require(
            URL(string: "https://youtu.be/AbCdEf123_-")
        )

        #expect(
            LiveExtractionValidator.validate(
                extraction,
                requestedURL: requested
            ).providerPathIsValid
        )
    }

    @Test
    func providerProofAllowsTrulyUnusedProviderWithoutAssetHashes() throws {
        let response = noChallengeResponse(providerWasConstructed: false)
        let extraction = try YTDLPExtractorEngine.decodeExtractionResponse(
            response
        )
        let requested = try #require(
            URL(string: "https://youtu.be/AbCdEf123_-")
        )

        #expect(
            LiveExtractionValidator.validate(
                extraction,
                requestedURL: requested
            ).providerPathIsValid
        )
    }

    @Test
    func providerProofAcceptsMatchedObservedNChallengeOnly() throws {
        let response = validResponse
            .replacingOccurrences(
                of: #""challenge_request_count": 2"#,
                with: #""challenge_request_count": 1"#
            )
            .replacingOccurrences(
                of: #""challenge_response_count": 2"#,
                with: #""challenge_response_count": 1"#
            )
            .replacingOccurrences(
                of: #""challenge_types": ["n", "sig"]"#,
                with: #""challenge_types": ["n"]"#
            )
            .replacingOccurrences(
                of: #""challenge_request_counts": {"n": 1, "sig": 1}"#,
                with: #""challenge_request_counts": {"n": 1, "sig": 0}"#
            )
            .replacingOccurrences(
                of: #""challenge_response_counts": {"n": 1, "sig": 1}"#,
                with: #""challenge_response_counts": {"n": 1, "sig": 0}"#
            )
            .replacingOccurrences(
                of: #""runtime_call_count": 2"#,
                with: #""runtime_call_count": 1"#
            )
        let extraction = try YTDLPExtractorEngine.decodeExtractionResponse(
            response
        )
        let requested = try #require(
            URL(string: "https://youtu.be/AbCdEf123_-")
        )

        #expect(
            LiveExtractionValidator.validate(
                extraction,
                requestedURL: requested
            ).providerPathIsValid
        )
    }

    @Test
    func providerProofAllowsRepeatedAvailabilityChecks() throws {
        let response = validResponse.replacingOccurrences(
            of: #""provider_available_count": 1"#,
            with: #""provider_available_count": 2"#
        )
        let extraction = try YTDLPExtractorEngine.decodeExtractionResponse(
            response
        )
        let requested = try #require(
            URL(string: "https://youtu.be/AbCdEf123_-")
        )

        #expect(
            LiveExtractionValidator.validate(
                extraction,
                requestedURL: requested
            ).providerPathIsValid
        )
    }

    @Test
    func sharedRequestIDsRemainUniqueAcrossConcurrentCallers() async {
        let ids = await withTaskGroup(
            of: UInt64.self,
            returning: [UInt64].self
        ) { group in
            for _ in 0..<256 {
                group.addTask {
                    PythonRequestIDAllocator.next()
                }
            }
            var values: [UInt64] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        #expect(ids.count == 256)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0 >= 0x8000_0000_0000_0000 })
    }

    @Test
    func cancellationBeforeEnqueueIsLatched() {
        let state = PythonExecutionCancellationState()

        #expect(state.requestCancellation())
        #expect(!state.requestCancellation())
        #expect(state.shouldSkipEnqueue)
        #expect(state.shouldKeepSignalling)
        state.finish()
        #expect(!state.shouldKeepSignalling)
    }

    @Test
    func providerProofFailsClosedWithoutRuntimeExecution() throws {
        let response = validResponse.replacingOccurrences(
            of: #""runtime_call_count": 2"#,
            with: #""runtime_call_count": 0"#
        )
        let extraction = try YTDLPExtractorEngine.decodeExtractionResponse(
            response
        )
        let requested = try #require(
            URL(string: "https://youtube.com/watch?v=AbCdEf123_-")
        )

        #expect(
            !LiveExtractionValidator.validate(
                extraction,
                requestedURL: requested
            ).providerPathIsValid
        )
    }

    @Test
    func extractorErrorsRemainTypedAndRedacted() {
        let response =
            """
            {
              "ok": false,
              "action": "extract_metadata",
              "error": {
                "code": "network_error",
                "message": "token=secret",
                "retryable": true
              }
            }
            """

        do {
            _ = try YTDLPExtractorEngine.decodeExtractionResponse(response)
            Issue.record("A failure envelope unexpectedly decoded as success.")
        } catch let error as ExtractionError {
            #expect(
                error == .extractorFailure(
                    code: "network_error",
                    message:
                        "The extractor failed. Technical details were redacted.",
                    retryable: true
                )
            )
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func rejectsWrongActionAndMalformedSuccessEnvelopes() {
        let wrongAction = validResponse.replacingOccurrences(
            of: #""action": "extract_metadata""#,
            with: #""action": "download""#
        )
        #expect(throws: ExtractionError.self) {
            try YTDLPExtractorEngine.decodeExtractionResponse(wrongAction)
        }

        let missingData =
            """
            {
              "ok": true,
              "action": "extract_metadata"
            }
            """
        #expect(throws: ExtractionError.self) {
            try YTDLPExtractorEngine.decodeExtractionResponse(missingData)
        }
    }

    @Test
    func liveConfigurationRequiresBothExplicitGates() throws {
        #expect(
            !AuthorizedLiveTestConfigurationLoader.executionWasRequested(
                arguments: ["Illucet"],
                environment: [:]
            )
        )
        #expect(
            AuthorizedLiveTestConfigurationLoader.executionWasRequested(
                arguments: ["Illucet", "--stage0-live"],
                environment: [:]
            )
        )

        let disabled = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0">
            <dict>
              <key>LiveTestsEnabled</key><false/>
              <key>StandardVideoURL</key>
              <string>https://youtu.be/AbCdEf123_-</string>
            </dict>
            </plist>
            """.utf8
        )
        #expect(throws: AuthorizedLiveTestConfigurationError.disabled) {
            try AuthorizedLiveTestConfigurationLoader.decode(
                disabled,
                source: .bundle
            )
        }

        let enabled = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0">
            <dict>
              <key>LiveTestsEnabled</key><true/>
              <key>StandardVideoURL</key>
              <string>https://youtu.be/AbCdEf123_-</string>
            </dict>
            </plist>
            """.utf8
        )
        let configuration =
            try AuthorizedLiveTestConfigurationLoader.decode(
                enabled,
                source: .documents
            )
        #expect(configuration.source == .documents)
        #expect(configuration.standardVideoURL.host() == "youtu.be")
    }

    private func noChallengeResponse(
        providerWasConstructed: Bool
    ) -> String {
        var response = validResponse
            .replacingOccurrences(
                of: #""challenge_provider_used": true"#,
                with: #""challenge_provider_used": false"#
            )
            .replacingOccurrences(
                of: #""challenge_request_count": 2"#,
                with: #""challenge_request_count": 0"#
            )
            .replacingOccurrences(
                of: #""challenge_response_count": 2"#,
                with: #""challenge_response_count": 0"#
            )
            .replacingOccurrences(
                of: #""challenge_types": ["n", "sig"]"#,
                with: #""challenge_types": []"#
            )
            .replacingOccurrences(
                of: #""bulk_solve_call_count": 1"#,
                with: #""bulk_solve_call_count": 0"#
            )
            .replacingOccurrences(
                of: #""challenge_request_counts": {"n": 1, "sig": 1}"#,
                with: #""challenge_request_counts": {"n": 0, "sig": 0}"#
            )
            .replacingOccurrences(
                of: #""challenge_response_counts": {"n": 1, "sig": 1}"#,
                with: #""challenge_response_counts": {"n": 0, "sig": 0}"#
            )
            .replacingOccurrences(
                of: #""runtime_call_count": 2"#,
                with: #""runtime_call_count": 0"#
            )
        if !providerWasConstructed {
            response = response
                .replacingOccurrences(
                    of: #""provider_constructed_count": 1"#,
                    with: #""provider_constructed_count": 0"#
                )
                .replacingOccurrences(
                    of: #""provider_available_count": 1"#,
                    with: #""provider_available_count": 0"#
                )
                .replacingOccurrences(
                    of: #""provider_available": true"#,
                    with: #""provider_available": false"#
                )
                .replacingOccurrences(
                    of:
                        #""ejs_core_sha3_512": "\#(LiveExtractionValidator.expectedEJSCoreSHA3512)""#,
                    with: #""ejs_core_sha3_512": null"#
                )
                .replacingOccurrences(
                    of:
                        #""ejs_library_sha3_512": "\#(LiveExtractionValidator.expectedEJSLibrarySHA3512)""#,
                    with: #""ejs_library_sha3_512": null"#
                )
        }
        return response
    }

    private func responseByAppendingThumbnail(url: String) throws -> String {
        var root = try #require(
            try JSONSerialization.jsonObject(with: Data(validResponse.utf8))
                as? [String: Any]
        )
        var data = try #require(root["data"] as? [String: Any])
        var metadata = try #require(
            data["metadata"] as? [String: Any]
        )
        var thumbnails = try #require(
            metadata["thumbnails"] as? [[String: Any]]
        )
        thumbnails.append(
            [
                "url": url,
                "width": 320,
                "height": 180,
                "id": "unsafe",
            ]
        )
        metadata["thumbnails"] = thumbnails
        data["metadata"] = metadata
        root["data"] = data
        return String(
            decoding: try JSONSerialization.data(withJSONObject: root),
            as: UTF8.self
        )
    }

    private var validResponse: String {
        """
        {
          "ok": true,
          "action": "extract_metadata",
          "data": {
            "metadata": {
              "canonical_url": "https://www.youtube.com/watch?v=AbCdEf123_-",
              "video_id": "AbCdEf123_-",
              "title": "Fixture title",
              "channel": "Fixture channel",
              "uploader": "Fixture uploader",
              "duration_seconds": 213,
              "upload_date": "20250102",
              "description": "Fixture description",
              "is_live": false,
              "live_status": "not_live",
              "thumbnails": [
                {
                  "url": "https://i.ytimg.com/thumbnail.jpg",
                  "width": 1280,
                  "height": 720,
                  "id": "maxres"
                }
              ],
              "chapters": [
                {
                  "title": "Chapter",
                  "start_time_seconds": 0,
                  "end_time_seconds": 213
                }
              ],
              "subtitles": [
                {
                  "track_id": "subtitle-111111111111111111111111",
                  "language": "en",
                  "name": "English",
                  "automatic": false,
                  "formats": [
                    {
                      "format_id": "subtitle-format-111111111111111111111111",
                      "url": "https://captions.example.invalid/manual/en.vtt",
                      "extension": "vtt",
                      "name": "WebVTT"
                    }
                  ]
                },
                {
                  "track_id": "subtitle-222222222222222222222222",
                  "language": "es",
                  "name": "Spanish (automatic)",
                  "automatic": true,
                  "formats": [
                    {
                      "format_id": "subtitle-format-222222222222222222222222",
                      "url": "https://captions.example.invalid/automatic/es.vtt",
                      "extension": "vtt",
                      "name": "WebVTT"
                    }
                  ]
                }
              ],
              "formats": [
                {
                  "format_id": "video",
                  "format_note": "2160p",
                  "extension": "webm",
                  "container": "webm",
                  "video_codec": "vp9",
                  "audio_codec": null,
                  "width": 3840,
                  "height": 2160,
                  "resolution": "3840x2160",
                  "frames_per_second": 30,
                  "dynamic_range": "SDR",
                  "is_hdr": false,
                  "audio_bitrate_kbps": null,
                  "video_bitrate_kbps": 12000,
                  "total_bitrate_kbps": 12000,
                  "exact_file_size_bytes": 12000000,
                  "approximate_file_size_bytes": null,
                  "has_video": true,
                  "has_audio": false,
                  "protocol": "https",
                  "source_type": "direct_http",
                  "language": null
                },
                {
                  "format_id": "audio",
                  "format_note": "medium",
                  "extension": "m4a",
                  "container": "m4a",
                  "video_codec": null,
                  "audio_codec": "aac",
                  "width": null,
                  "height": null,
                  "resolution": "audio only",
                  "frames_per_second": null,
                  "dynamic_range": null,
                  "is_hdr": false,
                  "audio_bitrate_kbps": 128,
                  "video_bitrate_kbps": null,
                  "total_bitrate_kbps": 128,
                  "exact_file_size_bytes": null,
                  "approximate_file_size_bytes": 3000000,
                  "has_video": false,
                  "has_audio": true,
                  "protocol": "https",
                  "source_type": "direct_http",
                  "language": "en"
                }
              ]
            },
            "provider_evidence": {
              "yt_dlp_version": "\(DependencyVersions.ytDLP)",
              "ejs_version": "0.8.0",
              "quickjs_version": "\(DependencyVersions.quickJS)",
              "provider_key": "IllucetQuickJS",
              "provider_registered": true,
              "external_js_runtimes_enabled": false,
              "remote_components_enabled": false,
              "challenge_provider_used": true,
              "challenge_request_count": 2,
              "challenge_response_count": 2,
              "format_count": 2,
              "warning_count": 0,
              "error_count": 0,
              "challenge_types": ["n", "sig"],
              "provider_constructed_count": 1,
              "provider_available_count": 1,
              "provider_available": true,
              "bulk_solve_call_count": 1,
              "challenge_request_counts": {"n": 1, "sig": 1},
              "challenge_response_counts": {"n": 1, "sig": 1},
              "runtime_call_count": 2,
              "runtime_error_count": 0,
              "runtime_cancellation_count": 0,
              "runtime_timeout_count": 0,
              "provider_failure_count": 0,
              "ejs_core_sha3_512": "\(LiveExtractionValidator.expectedEJSCoreSHA3512)",
              "ejs_library_sha3_512": "\(LiveExtractionValidator.expectedEJSLibrarySHA3512)",
              "format_inventory_sha256": "9167a2d32791cbde263496b24c0b500b1f7c5fc6a78baccc941e04f24e3097f0"
            }
          }
        }
        """
    }
}

struct StreamResolverTransportHintTests {
    @Test
    func availabilityDeadlinePreservesFractionalAndPastDates() throws {
        for timestamp in [0, Date.now.timeIntervalSince1970 - 1, Date.now.timeIntervalSince1970 + 4.25] {
            let result = try decodeResponse(httpChunkSizeJSON: nil,
                additionalFields: "\"available_at\": \(timestamp),")
            let stream = try #require(result.streams.first)
            #expect(stream.availableAt?.timeIntervalSince1970 == timestamp)
            #expect(stream.formatID == "137")
            #expect(stream.URL.absoluteString == "https://rr1---sn.example.googlevideo.com/media?sig=secret")
        }
        #expect(try decodeResponse(httpChunkSizeJSON: nil).streams.first?.availableAt == nil)
    }

    @Test(arguments: ["true", "-1", "4102444800", "1e309", #""1800000000""#, "{}", "[]"])
    func malformedAvailabilityDeadlineFailsClosed(value: String) {
        #expect(throws: StreamResolutionError.invalidResponse) {
            try decodeResponse(httpChunkSizeJSON: nil, additionalFields: "\"available_at\": \(value),")
        }
    }
    @Test(arguments: [
        Int64(1),
        Int64(10 * 1_024 * 1_024),
        YTDLPStreamResolver.maximumHTTPChunkSize,
    ])
    func validHTTPChunkSizeProjectsThroughTypedStream(
        chunkSize: Int64
    ) throws {
        let streams = try decodeResponse(
            httpChunkSizeJSON: String(chunkSize),
            additionalFields: """
                "downloader_options": {
                  "http_chunk_size": 1,
                  "arbitrary_private_option": "must-not-project"
                },
                "cookies": "session=must-not-project",
                "authorization": "must-not-project",
            """
        )
        let stream = try #require(streams.streams.first)

        #expect(streams.videoID == "AbCdEf123_-")
        #expect(stream.formatID == "137")
        #expect(stream.httpChunkSize == chunkSize)

        let typedFieldNames = Set(
            Mirror(reflecting: stream).children.compactMap(\.label)
        )
        #expect(typedFieldNames.contains("httpChunkSize"))
        #expect(!typedFieldNames.contains("downloaderOptions"))
        #expect(!typedFieldNames.contains("cookies"))
        #expect(!typedFieldNames.contains("authorization"))
    }

    @Test
    func missingHTTPChunkSizeRemainsNil() throws {
        for valueJSON in [String?.none, "null"] {
            let streams = try decodeResponse(httpChunkSizeJSON: valueJSON)
            let stream = try #require(streams.streams.first)

            #expect(stream.formatID == "137")
            #expect(stream.httpChunkSize == nil)
        }
    }

    @Test(arguments: [
        "0",
        "-1",
        "268435457",
        "1.5",
        "1.0",
        "10485760.0",
        "1e0",
        "true",
        #""10485760""#,
        "{}",
        "[]",
    ])
    func malformedHTTPChunkSizeFailsClosed(valueJSON: String) throws {
        #expect(throws: StreamResolutionError.invalidResponse) {
            try decodeResponse(httpChunkSizeJSON: valueJSON)
        }
    }

    private func decodeResponse(
        httpChunkSizeJSON: String?,
        additionalFields: String = ""
    ) throws -> ResolvedStreamSet {
        let hintField = httpChunkSizeJSON.map {
            #""http_chunk_size": \#($0),"#
        } ?? ""
        let response = """
            {
              "ok": true,
              "action": "resolve_streams",
              "data": {
                "video_id": "AbCdEf123_-",
                "streams": [
                  {
                    "format_id": "137",
                    "url": "https://rr1---sn.example.googlevideo.com/media?sig=secret",
                    "http_headers": {"User-Agent": "Illucet-Test"},
                    "extension": "mp4",
                    "protocol": "https",
                    "source_type": "direct_http",
                    "has_video": true,
                    "has_audio": false,
                    "expected_bytes": 1048576,
                    \(hintField)
                    \(additionalFields)
                    "fixture_marker": "ignored"
                  }
                ]
              },
              "error": null
            }
            """
        return try YTDLPStreamResolver.decodeResolutionResponse(
            response,
            normalizedURL: URL(
                string: "https://www.youtube.com/watch?v=AbCdEf123_-"
            )!,
            formatIDs: ["137"]
        )
    }
}

@Suite("P10.1 exact DASH fragment resolution")
struct DASHFragmentResolverTests {
    @Test
    func availabilityDeadlineIsAnOptionalStrictPlanField() throws {
        let timestamp = Date.now.timeIntervalSince1970 + 4
        let response = validResponse.replacingOccurrences(of: #""fragment_count": 3"#,
            with: "\"available_at\": \(timestamp), \"fragment_count\": 3")
        #expect(try decode(response).availableAt?.timeIntervalSince1970 == timestamp)
        for value in ["true", "-1", "4102444800", #""1800000000""#] {
            let malformed = validResponse.replacingOccurrences(of: #""fragment_count": 3"#,
                with: "\"available_at\": \(value), \"fragment_count\": 3")
            #expect(throws: DASHFragmentResolutionError.invalidResponse) { try decode(malformed) }
        }
    }
    @Test
    func exactOrderedPlanPreservesRepeatedEntries() throws {
        let plan = try decode(validResponse)

        #expect(plan.videoID == "AbCdEf123_-")
        #expect(plan.formatID == "137-dashy")
        #expect(plan.protocolName == "http_dash_segments")
        #expect(plan.sourceType == "dash")
        #expect(plan.fileExtension == "mp4")
        #expect(plan.hasVideo)
        #expect(!plan.hasAudio)
        #expect(plan.expectedBytes == 12)
        #expect(plan.HTTPHeaders == ["User-Agent": "Illucet-DASH-Test"])
        #expect(plan.fragments.map(\.position) == [0, 1, 2])
        #expect(plan.fragments.map(\.expectedBytes) == [4, 4, 4])
        #expect(plan.fragments[0].URL == plan.fragments[2].URL)
        #expect(
            plan.fragments.map(\.URL.absoluteString) == [
                "https://rr1---sn.example.googlevideo.com/init?sig=one",
                "https://rr1---sn.example.googlevideo.com/media-1?sig=two",
                "https://rr1---sn.example.googlevideo.com/init?sig=one",
            ]
        )
    }

    @Test
    func malformedUnsafeAndContradictoryPlansFailClosed() {
        let cases: [(String, String)] = [
            (
                "contradictory order",
                validResponse.replacingOccurrences(
                    of: #""position": 1"#,
                    with: #""position": 2"#
                )
            ),
            (
                "floating position",
                validResponse.replacingOccurrences(
                    of: #""position": 0"#,
                    with: #""position": 0.0"#
                )
            ),
            (
                "floating aggregate bytes",
                validResponse.replacingOccurrences(
                    of: #""expected_bytes": 12"#,
                    with: #""expected_bytes": 12.0"#
                )
            ),
            (
                "negative fragment bytes",
                validResponse.replacingOccurrences(
                    of: #""expected_bytes": 4"#,
                    with: #""expected_bytes": -1"#
                )
            ),
            (
                "count mismatch",
                validResponse.replacingOccurrences(
                    of: #""fragment_count": 3"#,
                    with: #""fragment_count": 2"#
                )
            ),
            (
                "non HTTPS",
                validResponse.replacingOccurrences(
                    of: "https://rr1---sn.example.googlevideo.com/init",
                    with: "http://rr1---sn.example.googlevideo.com/init"
                )
            ),
            (
                "unsupported host",
                validResponse.replacingOccurrences(
                    of: "rr1---sn.example.googlevideo.com",
                    with: "media.example.invalid"
                )
            ),
            (
                "credentials",
                validResponse.replacingOccurrences(
                    of: "https://rr1---sn.example.googlevideo.com/init",
                    with:
                        "https://user:password@rr1---sn.example.googlevideo.com/init"
                )
            ),
            (
                "secret header",
                validResponse.replacingOccurrences(
                    of: #""User-Agent": "Illucet-DASH-Test""#,
                    with: #""Authorization": "Bearer secret""#
                )
            ),
            (
                "case-duplicate headers",
                validResponse.replacingOccurrences(
                    of: #"{"User-Agent": "Illucet-DASH-Test"}"#,
                    with:
                        #"{"User-Agent": "first", "user-agent": "second"}"#
                )
            ),
            (
                "direct protocol",
                validResponse.replacingOccurrences(
                    of: #""protocol": "http_dash_segments""#,
                    with: #""protocol": "https""#
                )
            ),
            (
                "unsupported extension",
                validResponse.replacingOccurrences(
                    of: #""extension": "mp4""#,
                    with: #""extension": "bin""#
                )
            ),
            (
                "missing extension",
                validResponse.replacingOccurrences(
                    of: #""extension": "mp4","#,
                    with: ""
                )
            ),
            (
                "unexpected transport field",
                validResponse.replacingOccurrences(
                    of: #""position": 0,"#,
                    with: #""position": 0, "cookies": "secret","#
                )
            ),
            (
                "undocumented digest field",
                validResponse.replacingOccurrences(
                    of: #""position": 0,"#,
                    with: #""position": 0, "sha256": "not-trusted","#
                )
            ),
        ]

        for (label, response) in cases {
            #expect(throws: DASHFragmentResolutionError.invalidResponse) {
                _ = try decode(response)
            }
            _ = label
        }
    }

    private func decode(_ response: String) throws
        -> ResolvedDASHFragmentPlan
    {
        try YTDLPStreamResolver.decodeDASHFragmentPlanResponse(
            response,
            normalizedURL: URL(
                string: "https://www.youtube.com/watch?v=AbCdEf123_-"
            )!,
            formatID: "137-dashy"
        )
    }

    private var validResponse: String {
        """
        {
          "ok": true,
          "action": "resolve_dash_fragment_plan",
          "data": {
            "video_id": "AbCdEf123_-",
            "format_id": "137-dashy",
            "protocol": "http_dash_segments",
            "source_type": "dash",
            "extension": "mp4",
            "has_video": true,
            "has_audio": false,
            "expected_bytes": 12,
            "http_headers": {"User-Agent": "Illucet-DASH-Test"},
            "fragment_count": 3,
            "fragments": [
              {
                "position": 0,
                "url": "https://rr1---sn.example.googlevideo.com/init?sig=one",
                "expected_bytes": 4
              },
              {
                "position": 1,
                "url": "https://rr1---sn.example.googlevideo.com/media-1?sig=two",
                "expected_bytes": 4
              },
              {
                "position": 2,
                "url": "https://rr1---sn.example.googlevideo.com/init?sig=one",
                "expected_bytes": 4
              }
            ]
          }
        }
        """
    }
}
