import Foundation
import Testing
@testable import Illucet

struct SponsorBlockTests {
    @Test func categoryActionsInheritAndIndividualOverridesSurvive() throws {
        var policy = SponsorBlockPolicy(isEnabled: true, selectedCategories: [.sponsor])
        policy.replaceSelection(videoID: "example", queriedCategories: SponsorBlockPolicy.discoveryCategories,
            segments: [testSegment(id: "one", start: 1, end: 2), testSegment(id: "two", start: 3, end: 4)])
        #expect(policy.categoryDefaultAction(for: .filler) == .keep)
        policy.setSegmentOverride(.markAsChapter, segmentID: "two")
        policy.setCategoryOverride(.keep, for: .sponsor)
        var segments = try #require(policy.selectionSnapshot).segments
        #expect(segments[0].isIncluded == false)
        #expect(segments[1].isIncluded && policy.resolvedAction(for: segments[1]) == .markAsChapter)
        policy.setCategoryOverride(nil, for: .sponsor)
        segments = try #require(policy.selectionSnapshot).segments
        #expect(segments[0].isIncluded && policy.resolvedAction(for: segments[0]) == .remove)
        #expect(policy.resolvedAction(for: segments[1]) == .markAsChapter)
        policy.setSegmentOverride(.remove, segmentID: "two")
        #expect(policy.selectionSnapshot?.segments[1].actionOverride == nil)
        policy.setCategoryOverride(.markAsChapter, for: .sponsor)
        let decoded = try JSONDecoder().decode(SponsorBlockPolicy.self, from: JSONEncoder().encode(policy))
        #expect(decoded == policy)
        #expect(decoded.categoryDownloadAction(for: .sponsor) == .markAsChapter)
    }

    @Test func presetPromotesCategoryChoicesToEditableDefaults() throws {
        var policy = SponsorBlockPolicy(isEnabled: true, selectedCategories: [.sponsor])
        policy.setCategoryOverride(.markAsChapter, for: .sponsor)
        policy.setCategoryOverride(.remove, for: .filler)
        let preset = QuickStartPresetLibrary.newPreset(sponsorBlock: policy)
        let saved = try #require(QuickStartPresetLibrary.normalized([preset]).first).configuration.sponsorBlock
        #expect(saved.categoryOverrides == nil)
        #expect(saved.categoryDefaultAction(for: .sponsor) == .markAsChapter)
        #expect(saved.categoryDefaultAction(for: .filler) == .remove)
        var edited = saved
        edited.setDefaultAction(.keep, for: .filler)
        #expect(edited.categoryDownloadAction(for: .filler) == .keep)
    }

    @Test func offDefaultsSurviveMasterToggleAndMenusHaveNoDuplicates() {
        var policy = SponsorBlockPolicy.disabled
        policy.setEnabled(true)
        for category in SponsorBlockCategory.allCases { policy.setDefaultAction(.keep, for: category) }
        policy.setEnabled(false)
        policy.setEnabled(true)
        #expect(policy.selectedCategories.isEmpty)
        for action in SponsorBlockAction.editableActions {
            let choices = SponsorBlockAction.alternatives(to: action)
            #expect(choices.count == 2 && !choices.contains(action) && !choices.contains(.ask))
        }
    }

    @Test func legacyAskAndExplicitExclusionsMigrateSafely() throws {
        var old = SponsorBlockPolicy(isEnabled: true, selectedCategories: [.sponsor, .intro])
        old.setAction(.ask, for: .intro)
        old.replaceSelection(videoID: "example", queriedCategories: SponsorBlockPolicy.discoveryCategories,
            segments: [testSegment(id: "one", start: 1, end: 2)])
        old.selectionSnapshot?.segments[0].isIncluded = false
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "actionInheritance")
        var migrated = try JSONDecoder().decode(SponsorBlockPolicy.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(migrated.categoryDefaultAction(for: .intro) == .keep)
        #expect(migrated.selectionSnapshot?.segments[0].actionOverride == .keep)
        migrated.setCategoryOverride(.markAsChapter, for: .sponsor)
        #expect(migrated.selectionSnapshot?.segments[0].isIncluded == false)
    }

    @Test func largeHashBucketKeepsExactVideoSegments() async throws {
        let videoID = "z3Lo5QT7nME"
        var bucket = (0..<148).map { candidate(videoID: "unrelated-\($0)", segments: []) }
        bucket.append(candidate(videoID: videoID, segments: [
            segmentObject(id: "reported-sponsor", start: 387.95, end: 448.339, duration: 1115.841)
        ]))
        let data = try candidateData(bucket)
        let transport = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(request: request, statusCode: 200, data: data)
        }
        let result = try await SponsorBlockService(transport: transport).segments(videoID: videoID, categories: [.sponsor])
        #expect(result.map(\.segmentID) == ["reported-sponsor"])
    }

    @Test
    func liveTransportDisablesCredentialsAndFailsClosedOnRedirects() throws {
        let configuration = SponsorBlockURLSessionPolicy.configuration(
            requestTimeout: 12,
            resourceTimeout: 20
        )
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(
            configuration.requestCachePolicy == .reloadIgnoringLocalCacheData
        )
        #expect(configuration.timeoutIntervalForRequest == 12)
        #expect(configuration.timeoutIntervalForResource == 20)
        #expect(!configuration.waitsForConnectivity)

        let approved = URLRequest(
            url: try #require(
                URL(string: "https://sponsor.ajay.app/api/skipSegments/abcd")
            )
        )
        #expect(
            SponsorBlockURLSessionPolicy.redirectRequest(for: approved)?.url
                == approved.url
        )

        for rejectedURL in [
            "https://example.com/api/skipSegments/abcd",
            "http://sponsor.ajay.app/api/skipSegments/abcd",
            "https://sponsor.ajay.app:8443/api/skipSegments/abcd",
            "https://user@sponsor.ajay.app/api/skipSegments/abcd",
        ] {
            let request = URLRequest(
                url: try #require(URL(string: rejectedURL))
            )
            #expect(
                SponsorBlockURLSessionPolicy.redirectRequest(for: request)
                    == nil
            )
        }
    }

    @Test
    func serviceUsesOfficialPrefixQueryAndRejectsPrefixCollisionLocally()
        async throws
    {
        let videoID = "target-video-id"
        let data = try candidateData([
            candidate(
                videoID: "prefix-collision",
                segments: [segmentObject(id: "collision", start: 1, end: 2)]
            ),
            candidate(
                videoID: videoID,
                segments: [
                    segmentObject(
                        id: "later",
                        category: .intro,
                        start: 30,
                        end: 35
                    ),
                    segmentObject(id: "exact", start: 10, end: 20),
                ]
            ),
        ])
        let transport = SponsorBlockHTTPStub { request, maximumBytes in
            #expect(maximumBytes == 512 * 1_024)
            return HTTPResponse(request: request, statusCode: 200, data: data)
        }
        let service = SponsorBlockService(transport: transport)

        let segments = try await service.segments(
            videoID: videoID,
            categories: SponsorBlockPolicy.discoveryCategories
        )

        #expect(segments.map(\.segmentID) == ["exact", "later"])
        let requests = await transport.capturedRequests()
        let request = try #require(requests.first)
        let URL = try #require(request.url)
        #expect(requests.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(
            request.value(forHTTPHeaderField: "Accept")
                == "application/json"
        )
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == nil)
        #expect(URL.scheme == "https")
        #expect(URL.host == "sponsor.ajay.app")
        #expect(URL.port == nil)
        #expect(URL.user == nil)
        #expect(URL.password == nil)
        #expect(request.httpBody == nil)
        #expect(
            URL.path
                == "/api/skipSegments/\(SponsorBlockService.hashPrefix(for: videoID))"
        )
        #expect(URL.lastPathComponent == "ac89")
        #expect(URL.lastPathComponent.count == 4)
        let components = try #require(
            URLComponents(url: URL, resolvingAgainstBaseURL: false)
        )
        #expect(components.queryItems?.map(\.name) == ["categories", "actionTypes"])
        #expect(components.queryItems?.first { $0.name == "actionTypes" }?.value == "[\"skip\",\"poi\"]")
        let JSON = try #require(
            components.queryItems?.first(where: {
                $0.name == "categories"
            })?.value
        )
        let categoryData = try #require(JSON.data(using: .utf8))
        #expect(
            try JSONDecoder().decode([String].self, from: categoryData)
                == SponsorBlockCategory.stableOrder.map(\.rawValue)
        )
    }

    @Test
    func diagnosticLoggingIsPersistedOptInRedactedAndObservational()
        async throws
    {
        var settings = AppSettings.defaults
        #expect(!settings.sponsorBlockDiagnosticLoggingEnabled)
        settings.sponsorBlockDiagnosticLoggingEnabled = true
        let settingsData = try JSONEncoder.illucetEncoder.encode(settings)
        let roundTrip = try JSONDecoder.illucetDecoder.decode(
            AppSettings.self,
            from: settingsData
        )
        #expect(roundTrip.sponsorBlockDiagnosticLoggingEnabled)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: settingsData)
                as? [String: Any]
        )
        legacyObject.removeValue(forKey: "sponsorBlockDiagnosticLogging")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        #expect(
            try !JSONDecoder.illucetDecoder.decode(
                AppSettings.self,
                from: legacyData
            ).sponsorBlockDiagnosticLoggingEnabled
        )

        let videoID = "diagnostic-secret-video-id"
        let responseData = try candidateData([
            candidate(
                videoID: videoID,
                segments: [
                    segmentObject(
                        id: "diagnostic-secret-segment-id",
                        category: .sponsor,
                        start: 1,
                        end: 2
                    ),
                ]
            ),
        ])
        let disabledRoot = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-SponsorBlockDiagnostics-Disabled-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let enabledRoot = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-SponsorBlockDiagnostics-Enabled-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: disabledRoot)
            try? FileManager.default.removeItem(at: enabledRoot)
        }

        let disabledStore = DiagnosticStore(rootURL: disabledRoot)
        let disabledLogger = SponsorBlockDiagnosticLogger(store: disabledStore)
        let disabledTransport = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(request: request, statusCode: 200, data: responseData)
        }
        let disabledResult = try await SponsorBlockService(
            transport: disabledTransport,
            diagnostics: disabledLogger
        ).segments(videoID: videoID, categories: [.sponsor])
        #expect(await disabledStore.allEntries().isEmpty)

        let enabledStore = DiagnosticStore(rootURL: enabledRoot)
        let enabledLogger = SponsorBlockDiagnosticLogger(store: enabledStore)
        await enabledLogger.setEnabled(true)
        let enabledTransport = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(request: request, statusCode: 200, data: responseData)
        }
        let enabledResult = try await SponsorBlockService(
            transport: enabledTransport,
            diagnostics: enabledLogger
        ).segments(videoID: videoID, categories: [.sponsor])
        #expect(enabledResult == disabledResult)

        await enabledLogger.record(
            event: "redaction_probe",
            detail: "url=https://secret.invalid/path?sig=hidden Authorization=BearerSecret token=hidden"
        )
        let entries = await enabledStore.allEntries()
        #expect(
            Set(entries.map(\.event)).isSuperset(
                of: [
                    "lookup_started",
                    "response_classified",
                    "response_validated",
                    "redaction_probe",
                ]
            )
        )
        let encodedEntries = String(
            decoding: try JSONEncoder.illucetEncoder.encode(entries),
            as: UTF8.self
        )
        #expect(!encodedEntries.contains(videoID))
        #expect(!encodedEntries.contains("diagnostic-secret-segment-id"))
        #expect(!encodedEntries.contains("secret.invalid"))
        #expect(!encodedEntries.contains("BearerSecret"))
        #expect(!encodedEntries.contains("token=hidden"))
        #expect(encodedEntries.contains("[URL REDACTED]"))
        #expect(encodedEntries.contains("[REDACTED]"))
    }

    @Test
    func masterEnableDiscoversAllCategoriesWithSafeMutationDefaults() throws {
        var policy = SponsorBlockPolicy.disabled
        policy.setEnabled(true)

        #expect(policy.needsSegmentReview)
        #expect(
            policy.requestedDiscoveryCategories
                == SponsorBlockPolicy.discoveryCategories
        )
        #expect(
            policy.selectedCategories
                == SponsorBlockPolicy.safeDefaultIncludedCategories
        )
        #expect(!policy.selectedCategories.contains(.filler))
        #expect(policy.action(for: .filler) == .keep)
        #expect(!policy.requiresRemoval)

        policy.replaceSelection(
            videoID: "video",
            queriedCategories: policy.requestedDiscoveryCategories,
            segments: [
                testSegment(id: "sponsor", start: 1, end: 2),
                testSegment(
                    id: "filler",
                    category: .filler,
                    start: 3,
                    end: 4
                ),
            ]
        )

        let segments = try #require(policy.selectionSnapshot?.segments)
        #expect(segments.map(\.category) == [.sponsor, .filler])
        #expect(segments.first { $0.category == .sponsor }?.isIncluded == true)
        #expect(segments.first { $0.category == .filler }?.isIncluded == false)
        #expect(policy.requiresRemoval)

        var optedIn = try #require(policy.selectionSnapshot)
        let fillerIndex = try #require(optedIn.segments.firstIndex {
            $0.category == .filler
        })
        for index in optedIn.segments.indices {
            optedIn.segments[index].isIncluded = false
        }
        optedIn.segments[fillerIndex].isIncluded = true
        policy.selectionSnapshot = optedIn
        #expect(!policy.hasSelectedOutputMutation)
        #expect(
            try SponsorBlockPlanner.makePlan(
                policy: policy,
                videoID: "video",
                analyzedDuration: 100
            ).entries.first { $0.categories.contains(.filler) }?.action
                == .keep
        )

        optedIn.segments[fillerIndex].actionOverride = .remove
        policy.selectionSnapshot = optedIn
        #expect(policy.hasSelectedOutputMutation)
        #expect(
            try SponsorBlockPlanner.makePlan(
                policy: policy,
                videoID: "video",
                analyzedDuration: 100
            ).entries.first { $0.categories.contains(.filler) }?.action
                == .remove
        )
    }

    @Test
    func masterEnableWithoutUsableSegmentsAllowsLookupFailureFallback() throws {
        var policy = SponsorBlockPolicy.disabled
        policy.setEnabled(true)
        #expect(
            policy.requestedDiscoveryCategories
                == SponsorBlockPolicy.discoveryCategories
        )
        #expect(!policy.requiresRemoval)
        policy.markLookupUnavailable()

        #expect(policy.lookupUnavailable)
        #expect(!policy.requiresRemoval)
        #expect(
            try SponsorBlockPlanner.makePlan(
                policy: policy,
                videoID: DeveloperFixtures.media.videoID,
                analyzedDuration: DeveloperFixtures.media.durationSeconds
            ).entries.isEmpty
        )
        #expect(
            SponsorBlockReviewState.resolve(
                policy: policy,
                previewState: .failed(.transportFailure),
                metadata: DeveloperFixtures.media,
                configuration: .standard
            ) == .ready
        )
    }

    @Test
    func legacyEnabledEmptyPolicyMigratesAsNoOp() throws {
        let current = SponsorBlockPolicy(
            isEnabled: true,
            selectedCategories: []
        )
        let currentData = try JSONEncoder().encode(current)
        let currentRoundTrip = try JSONDecoder().decode(
            SponsorBlockPolicy.self,
            from: currentData
        )
        #expect(currentRoundTrip.isEnabled)
        #expect(
            currentRoundTrip.requestedDiscoveryCategories
                == SponsorBlockPolicy.discoveryCategories
        )

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: currentData)
                as? [String: Any]
        )
        legacyObject.removeValue(forKey: "automaticDiscovery")
        let legacyData = try JSONSerialization.data(
            withJSONObject: legacyObject
        )
        let migrated = try JSONDecoder().decode(
            SponsorBlockPolicy.self,
            from: legacyData
        )

        #expect(!migrated.isEnabled)
        #expect(!migrated.needsSegmentReview)
        #expect(migrated.requestedDiscoveryCategories.isEmpty)
    }

    @Test
    func disabledOrEmptyCategoryFetchPerformsNoNetworkRequest() async throws {
        let transport = SponsorBlockHTTPStub { request, _ in
            Issue.record("Unexpected request: \(request.httpMethod ?? "nil")")
            return HTTPResponse(request: request, statusCode: 200, data: Data())
        }
        let service = SponsorBlockService(transport: transport)

        let segments = try await service.segments(
            videoID: "unused",
            categories: []
        )

        #expect(segments.isEmpty)
        #expect(await transport.capturedRequests().isEmpty)
        #expect(!SponsorBlockPolicy.disabled.needsSegmentReview)

        await #expect(throws: SponsorBlockServiceError.invalidVideoIdentity) {
            try await service.segments(
                videoID: "invalid identity",
                categories: [.sponsor]
            )
        }
        #expect(await transport.capturedRequests().isEmpty)
    }

    @Test
    func serviceMapsNoSegmentsAndTypedFailureClasses() async throws {
        let notFound = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(request: request, statusCode: 404, data: Data())
        }
        let notFoundService = SponsorBlockService(transport: notFound)
        #expect(
            try await notFoundService.segments(
                videoID: "missing",
                categories: [.sponsor]
            ).isEmpty
        )

        let prefixCollisionData = try candidateData([
            candidate(
                videoID: "different-video",
                segments: [
                    segmentObject(id: "different", start: 1, end: 2),
                ]
            ),
        ])
        let noExactMatch = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(
                request: request,
                statusCode: 200,
                data: prefixCollisionData
            )
        }
        #expect(
            try await SponsorBlockService(
                transport: noExactMatch
            ).segments(
                videoID: "target-video",
                categories: [.sponsor]
            ).isEmpty
        )

        let malformed = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(
                request: request,
                statusCode: 200,
                data: Data("not-json".utf8)
            )
        }
        await #expect(throws: SponsorBlockServiceError.malformedResponse) {
            try await SponsorBlockService(transport: malformed).segments(
                videoID: "malformed",
                categories: [.sponsor]
            )
        }

        let oversized = SponsorBlockHTTPStub { _, maximumBytes in
            throw SponsorBlockTransportError.responseTooLarge(
                maximumBytes: maximumBytes
            )
        }
        await #expect(
            throws: SponsorBlockServiceError.responseTooLarge(
                maximumBytes: 512 * 1_024
            )
        ) {
            try await SponsorBlockService(transport: oversized).segments(
                videoID: "large",
                categories: [.sponsor]
            )
        }

        let timedOut = SponsorBlockHTTPStub { _, _ in
            throw URLError(.timedOut)
        }
        await #expect(throws: SponsorBlockServiceError.timedOut) {
            try await SponsorBlockService(transport: timedOut).segments(
                videoID: "timeout",
                categories: [.sponsor]
            )
        }

        let transportFailure = SponsorBlockHTTPStub { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        await #expect(throws: SponsorBlockServiceError.transportFailure) {
            try await SponsorBlockService(
                transport: transportFailure
            ).segments(
                videoID: "offline",
                categories: [.sponsor]
            )
        }

        let badRequest = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(request: request, statusCode: 400, data: Data())
        }
        await #expect(
            throws: SponsorBlockServiceError.requestRejected(statusCode: 400)
        ) {
            try await SponsorBlockService(transport: badRequest).segments(
                videoID: "bad-request",
                categories: [.sponsor]
            )
        }

        let forbidden = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(request: request, statusCode: 403, data: Data())
        }
        await #expect(throws: SponsorBlockServiceError.forbidden) {
            try await SponsorBlockService(transport: forbidden).segments(
                videoID: "forbidden",
                categories: [.sponsor]
            )
        }

        let rateLimited = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(request: request, statusCode: 429, data: Data())
        }
        await #expect(throws: SponsorBlockServiceError.rateLimited) {
            try await SponsorBlockService(transport: rateLimited).segments(
                videoID: "rate-limited",
                categories: [.sponsor]
            )
        }

        let serverFailure = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(request: request, statusCode: 503, data: Data())
        }
        await #expect(
            throws: SponsorBlockServiceError.serviceUnavailable(
                statusCode: 503
            )
        ) {
            try await SponsorBlockService(transport: serverFailure).segments(
                videoID: "server-error",
                categories: [.sponsor]
            )
        }

        let unexpected = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(request: request, statusCode: 304, data: Data())
        }
        await #expect(
            throws: SponsorBlockServiceError.HTTPFailure(statusCode: 304)
        ) {
            try await SponsorBlockService(transport: unexpected).segments(
                videoID: "unexpected",
                categories: [.sponsor]
            )
        }

        let descriptions = [
            SponsorBlockServiceError.requestRejected(statusCode: 400),
            .forbidden,
            .rateLimited,
            .serviceUnavailable(statusCode: 503),
            .timedOut,
            .transportFailure,
            .malformedResponse,
        ].map(\.localizedDescription)
        #expect(Set(descriptions).count == descriptions.count)
        #expect(
            SponsorBlockServiceError.forbidden.localizedDescription
                .contains("current network")
        )
    }

    @Test
    func serviceKeepsUsableExactSegmentsFromBoundedPartialResponse()
        async throws
    {
        let videoID = "partial-response"
        var malformedSegment = segmentObject(
            id: "malformed",
            start: 1,
            end: 2
        )
        malformedSegment["segment"] = "not-a-range"
        let data = try candidateData([
            ["videoID": 42, "segments": []],
            candidate(
                videoID: videoID,
                segments: [
                    malformedSegment,
                    segmentObject(id: "usable", start: 3, end: 4),
                ]
            ),
        ])
        let transport = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(request: request, statusCode: 200, data: data)
        }

        let segments = try await SponsorBlockService(
            transport: transport
        ).segments(videoID: videoID, categories: [.sponsor])
        #expect(segments.map(\.segmentID) == ["usable"])

        let noUsableData = try candidateData([
            candidate(videoID: videoID, segments: [malformedSegment]),
        ])
        let noUsableTransport = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(
                request: request,
                statusCode: 200,
                data: noUsableData
            )
        }
        #expect(
            try await SponsorBlockService(
                transport: noUsableTransport
            ).segments(videoID: videoID, categories: [.sponsor]).isEmpty
        )
    }

    @Test
    func serviceRejectsInvalidRangesUnknownCategoriesAndDuplicateIdentities()
        async throws
    {
        let invalidRangeData = try candidateData([
            candidate(
                videoID: "invalid-range",
                segments: [segmentObject(id: "invalid", start: 20, end: 20)]
            ),
        ])
        let invalidRange = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(
                request: request,
                statusCode: 200,
                data: invalidRangeData
            )
        }
        await #expect(throws: SponsorBlockServiceError.invalidSegment) {
            try await SponsorBlockService(transport: invalidRange).segments(
                videoID: "invalid-range",
                categories: [.sponsor]
            )
        }

        let duplicateData = try candidateData([
            candidate(
                videoID: "duplicates",
                segments: [
                    segmentObject(id: "same", start: 1, end: 2),
                    segmentObject(id: "same", start: 3, end: 4),
                ]
            ),
        ])
        let duplicates = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(request: request, statusCode: 200, data: duplicateData)
        }
        await #expect(throws: SponsorBlockServiceError.malformedResponse) {
            try await SponsorBlockService(transport: duplicates).segments(
                videoID: "duplicates",
                categories: [.sponsor]
            )
        }
    }

    @Test
    func serviceAcceptsZeroSubmittedDurationAsUnknown() async throws {
        let videoID = "unknown-duration"
        let data = try candidateData([
            candidate(
                videoID: videoID,
                segments: [
                    segmentObject(
                        id: "unknown",
                        start: 10,
                        end: 20,
                        duration: 0
                    ),
                ]
            ),
        ])
        let transport = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(request: request, statusCode: 200, data: data)
        }
        let segments = try await SponsorBlockService(
            transport: transport
        ).segments(videoID: videoID, categories: [.sponsor])

        #expect(segments.count == 1)
        #expect(segments[0].submittedVideoDuration == 0)

        let negativeData = try candidateData([
            candidate(
                videoID: "negative-duration",
                segments: [
                    segmentObject(
                        id: "negative",
                        start: 1,
                        end: 2,
                        duration: -1
                    ),
                ]
            ),
        ])
        let negative = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(
                request: request,
                statusCode: 200,
                data: negativeData
            )
        }
        await #expect(throws: SponsorBlockServiceError.invalidSegment) {
            try await SponsorBlockService(transport: negative).segments(
                videoID: "negative-duration",
                categories: [.sponsor]
            )
        }
    }

    @Test
    func serviceBoundsNearEndRepresentationDifference() async throws {
        let videoID = "near-end"
        let acceptedData = try candidateData([
            candidate(
                videoID: videoID,
                segments: [
                    segmentObject(
                        id: "accepted",
                        start: 90,
                        end: 100.26,
                        duration: 100
                    ),
                ]
            ),
        ])
        let acceptedTransport = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(
                request: request,
                statusCode: 200,
                data: acceptedData
            )
        }
        let accepted = try await SponsorBlockService(
            transport: acceptedTransport
        ).segments(videoID: videoID, categories: [.sponsor])
        #expect(accepted.first?.endSeconds == 100.26)

        let rejectedData = try candidateData([
            candidate(
                videoID: videoID,
                segments: [
                    segmentObject(
                        id: "rejected",
                        start: 90,
                        end: 100.51,
                        duration: 100
                    ),
                ]
            ),
        ])
        let rejectedTransport = SponsorBlockHTTPStub { request, _ in
            HTTPResponse(
                request: request,
                statusCode: 200,
                data: rejectedData
            )
        }
        await #expect(throws: SponsorBlockServiceError.invalidSegment) {
            try await SponsorBlockService(
                transport: rejectedTransport
            ).segments(videoID: videoID, categories: [.sponsor])
        }
    }

    @Test
    func typedCacheHonorsHitExpiryAndEntryLimit() async throws {
        let videos = ["cache-a", "cache-b", "cache-c"]
        let payloads = try Dictionary(
            uniqueKeysWithValues: videos.map { videoID in
                (
                    SponsorBlockService.hashPrefix(for: videoID),
                    try candidateData([
                        candidate(
                            videoID: videoID,
                            segments: [
                                segmentObject(
                                    id: videoID,
                                    start: 1,
                                    end: 2
                                ),
                            ]
                        ),
                    ])
                )
            }
        )
        let transport = SponsorBlockHTTPStub { request, _ in
            let key = try #require(request.url?.lastPathComponent)
            return HTTPResponse(
                request: request,
                statusCode: 200,
                data: try #require(payloads[key])
            )
        }
        let clock = SponsorBlockTestClock(
            Date(timeIntervalSince1970: 1_000)
        )
        var configuration = SponsorBlockServiceConfiguration()
        configuration.maximumCacheEntries = 2
        configuration.cacheTTL = 10
        let service = SponsorBlockService(
            transport: transport,
            configuration: configuration,
            now: { clock.now() }
        )

        _ = try await service.segments(
            videoID: "cache-a",
            categories: [.sponsor]
        )
        _ = try await service.segments(
            videoID: "cache-a",
            categories: [.sponsor]
        )
        #expect(await transport.capturedRequests().count == 1)

        clock.advance(by: 11)
        _ = try await service.segments(
            videoID: "cache-a",
            categories: [.sponsor]
        )
        _ = try await service.segments(
            videoID: "cache-b",
            categories: [.sponsor]
        )
        _ = try await service.segments(
            videoID: "cache-c",
            categories: [.sponsor]
        )
        _ = try await service.segments(
            videoID: "cache-a",
            categories: [.sponsor]
        )
        #expect(await transport.capturedRequests().count == 5)
    }

    @Test
    func legacySnapshotAndDisabledOnlyPresetDecodeAsOff() throws {
        let encoded = try JSONEncoder.illucetEncoder.encode(IllucetSnapshot.empty)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var settings = try #require(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "sponsorBlockPolicy")
        object["settings"] = settings
        var presets = try #require(
            object["quickStartPresets"] as? [[String: Any]]
        )
        for index in presets.indices {
            var configuration = try #require(
                presets[index]["configuration"] as? [String: Any]
            )
            configuration.removeValue(forKey: "sponsorBlockPolicy")
            presets[index]["configuration"] = configuration
            presets[index]["sponsorBlockBehavior"] = "Off"
        }
        object["quickStartPresets"] = presets
        let legacy = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        let decoded = try JSONDecoder.illucetDecoder.decode(
            IllucetSnapshot.self,
            from: legacy
        )

        #expect(decoded.settings.sponsorBlock == .disabled)
        #expect(
            decoded.quickStartPresets.allSatisfy {
                $0.configuration.sponsorBlock == .disabled
            }
        )
    }

    @Test
    func globalPresetAndPerDownloadPoliciesAreIndependentAndRoundTrip()
        throws
    {
        var global = SponsorBlockPolicy(
            isEnabled: true,
            selectedCategories: [.sponsor, .intro]
        )
        global.setAction(.markAsChapter, for: .intro)
        var settings = AppSettings.defaults
        settings.sponsorBlock = global
        let seeded = settings.configuration()
        var preset = QuickStartPresetLibrary.newPreset(
            sponsorBlock: seeded.sponsorBlock
        )
        var download = seeded
        var downloadPolicy = download.sponsorBlock
        downloadPolicy.setAction(.keep, for: .intro)
        download.sponsorBlock = downloadPolicy

        #expect(settings.sponsorBlock.action(for: .intro) == .markAsChapter)
        #expect(preset.configuration.sponsorBlock.action(for: .intro) == .markAsChapter)
        #expect(download.sponsorBlock.action(for: .intro) == .keep)

        preset.configuration.sponsorBlock.replaceSelection(
            videoID: "preset-should-not-store-selection",
            queriedCategories: [.sponsor, .intro],
            segments: [testSegment(id: "selection", start: 1, end: 2)]
        )
        let normalized = try #require(
            QuickStartPresetLibrary.normalized([preset]).first
        )
        #expect(normalized.configuration.sponsorBlock.selectionSnapshot == nil)
        #expect(normalized.configuration.sponsorBlock.isEnabled)

        var snapshot = IllucetSnapshot.empty
        snapshot.settings = settings
        snapshot.quickStartPresets = [normalized]
        let data = try JSONEncoder.illucetEncoder.encode(snapshot)
        let roundTrip = try JSONDecoder.illucetDecoder.decode(
            IllucetSnapshot.self,
            from: data
        )
        #expect(roundTrip.settings.sponsorBlock == global)
        #expect(
            roundTrip.quickStartPresets[0].configuration.sponsorBlock
                == normalized.configuration.sponsorBlock
        )
    }

    @Test
    func selectionRefreshPreservesExplicitDecisionsByServerIdentity() throws {
        var policy = SponsorBlockPolicy(
            isEnabled: true,
            selectedCategories: [.sponsor]
        )
        policy.replaceSelection(
            videoID: "video",
            queriedCategories: [.sponsor],
            segments: [testSegment(id: "stable", start: 1, end: 2)]
        )
        var snapshot = try #require(policy.selectionSnapshot)
        snapshot.segments[0].isIncluded = false
        snapshot.segments[0].actionOverride = .keep
        policy.selectionSnapshot = snapshot

        policy.replaceSelection(
            videoID: "video",
            queriedCategories: [.sponsor],
            segments: [
                testSegment(id: "new", start: 3, end: 4),
                testSegment(id: "stable", start: 1.25, end: 2.5),
            ]
        )

        let stable = try #require(
            policy.selectionSnapshot?.segments.first(where: {
                $0.segmentID == "stable"
            })
        )
        #expect(!stable.isIncluded)
        #expect(stable.actionOverride == .keep)
        #expect(stable.startSeconds == 1.25)
    }

    @Test
    func legacyNarrowSnapshotRoundTripsAndStillPlansWithoutRefetch() throws {
        var legacy = SponsorBlockPolicy(
            isEnabled: true,
            selectedCategories: [.sponsor]
        )
        legacy.replaceSelection(
            videoID: "video",
            queriedCategories: [.sponsor],
            segments: [testSegment(id: "legacy", start: 1, end: 2)]
        )
        let data = try JSONEncoder().encode(legacy)
        let restored = try JSONDecoder().decode(
            SponsorBlockPolicy.self,
            from: data
        )

        #expect(
            restored.selectionSnapshot?.queriedCategories == [.sponsor]
        )
        #expect(
            try SponsorBlockPlanner.makePlan(
                policy: restored,
                videoID: "video",
                analyzedDuration: 100
            ).entries.count == 1
        )
    }

    @Test
    func typedReviewBlockerRecoversWhenInvalidSegmentIsExcluded() throws {
        let metadata = DeveloperFixtures.media
        var configuration = DownloadConfiguration.standard
        configuration.thumbnailBehavior = .none
        FormatSelection.applyAutomaticSelection(
            to: &configuration,
            metadata: metadata
        )
        configuration.videoCodec = .h264
        configuration.audioCodec = .aac
        configuration.container = .mp4
        configuration = OutputCapabilityMatrix.normalized(configuration)
        var policy = SponsorBlockPolicy(
            isEnabled: true,
            selectedCategories: [.sponsor]
        )
        policy.replaceSelection(
            videoID: metadata.videoID,
            queriedCategories: policy.requestedDiscoveryCategories,
            segments: [
                testSegment(id: "valid", start: 1, end: 2),
                testSegment(
                    id: "outside",
                    start: metadata.durationSeconds ?? 100,
                    end: (metadata.durationSeconds ?? 100) + 10
                ),
            ]
        )
        configuration.sponsorBlock = policy

        #expect(
            SponsorBlockReviewState.resolve(
                policy: policy,
                previewState: .loaded(count: 2),
                metadata: metadata,
                configuration: configuration
            ) == .blocked(.planning(.segmentOutsideDuration))
        )

        var snapshot = try #require(policy.selectionSnapshot)
        let outsideIndex = try #require(snapshot.segments.firstIndex {
            $0.segmentID == "outside"
        })
        snapshot.segments[outsideIndex].isIncluded = false
        policy.selectionSnapshot = snapshot
        configuration.sponsorBlock = policy

        #expect(
            SponsorBlockReviewState.resolve(
                policy: policy,
                previewState: .loaded(count: 2),
                metadata: metadata,
                configuration: configuration
            ) == .ready
        )
    }

    @Test
    func typedReviewPreservesStaleAskAndUnsupportedReasons() throws {
        let metadata = DeveloperFixtures.media
        var configuration = DownloadConfiguration.standard
        configuration.thumbnailBehavior = .none
        FormatSelection.applyAutomaticSelection(
            to: &configuration,
            metadata: metadata
        )
        var policy = SponsorBlockPolicy(
            isEnabled: true,
            selectedCategories: [.sponsor]
        )
        policy.setAction(.ask, for: .sponsor)
        policy.replaceSelection(
            videoID: metadata.videoID,
            queriedCategories: policy.requestedDiscoveryCategories,
            segments: [testSegment(id: "ask", start: 1, end: 2)]
        )
        configuration.sponsorBlock = policy
        #expect(
            SponsorBlockReviewState.resolve(
                policy: policy,
                previewState: .loaded(count: 1),
                metadata: metadata,
                configuration: configuration
            ) == .blocked(.planning(.unresolvedAsk))
        )

        policy.setAction(.remove, for: .sponsor)
        configuration.sponsorBlock = policy
        configuration.subtitleDelivery = .sidecarVTT
        configuration = OutputCapabilityMatrix.normalized(configuration)
        configuration.sponsorBlock = policy
        #expect(
            SponsorBlockReviewState.resolve(
                policy: policy,
                previewState: .loaded(count: 1),
                metadata: metadata,
                configuration: configuration
            ) == .blocked(.planning(.unsupportedExecutionPath))
        )

        var staleSnapshot = try #require(policy.selectionSnapshot)
        staleSnapshot = SponsorBlockSelectionSnapshot(
            videoID: "different-video",
            queriedCategories: staleSnapshot.queriedCategories,
            segments: staleSnapshot.segments
        )
        policy.selectionSnapshot = staleSnapshot
        configuration.sponsorBlock = policy
        #expect(
            SponsorBlockReviewState.resolve(
                policy: policy,
                previewState: .loaded(count: 1),
                metadata: metadata,
                configuration: configuration
            ) == .blocked(.planning(.videoIdentityMismatch))
        )

        policy.selectionSnapshot = SponsorBlockSelectionSnapshot(
            videoID: metadata.videoID,
            queriedCategories: [.intro],
            segments: staleSnapshot.segments
        )
        configuration.sponsorBlock = policy
        #expect(
            SponsorBlockReviewState.resolve(
                policy: policy,
                previewState: .loaded(count: 1),
                metadata: metadata,
                configuration: configuration
            ) == .blocked(.planning(.categoryScopeMismatch))
        )

        policy.selectionSnapshot = SponsorBlockSelectionSnapshot(
            videoID: metadata.videoID,
            queriedCategories: policy.requestedDiscoveryCategories,
            segments: [storedSegment(id: "invalid", start: 2, end: 2)]
        )
        configuration.sponsorBlock = policy
        #expect(
            SponsorBlockReviewState.resolve(
                policy: policy,
                previewState: .loaded(count: 1),
                metadata: metadata,
                configuration: configuration
            ) == .blocked(.planning(.invalidSegmentRange))
        )
    }

    @Test
    func plannerIsOrderIndependentAndMergesOnlyOverlappingRemoveRanges()
        throws
    {
        let source = [
            testSegment(
                id: "chapter",
                category: .outro,
                start: 12,
                end: 18
            ),
            testSegment(
                id: "remove-b",
                category: .intro,
                start: 15,
                end: 25
            ),
            testSegment(id: "remove-a", start: 10, end: 20),
            testSegment(
                id: "keep",
                category: .hook,
                start: 40,
                end: 45
            ),
        ]
        var policy = SponsorBlockPolicy(
            isEnabled: true,
            selectedCategories: [.sponsor, .intro, .outro, .hook]
        )
        policy.setAction(.remove, for: .sponsor)
        policy.setAction(.remove, for: .intro)
        policy.setAction(.markAsChapter, for: .outro)
        policy.setAction(.keep, for: .hook)
        policy.replaceSelection(
            videoID: "video",
            queriedCategories: policy.selectedCategories,
            segments: source
        )
        let forward = try SponsorBlockPlanner.makePlan(
            policy: policy,
            videoID: "video",
            analyzedDuration: 100
        )
        policy.replaceSelection(
            videoID: "video",
            queriedCategories: policy.selectedCategories,
            segments: source.reversed()
        )
        let reversed = try SponsorBlockPlanner.makePlan(
            policy: policy,
            videoID: "video",
            analyzedDuration: 100
        )

        #expect(forward == reversed)
        let removal = try #require(
            forward.entries.first(where: { $0.action == .remove })
        )
        #expect(removal.startSeconds == 10)
        #expect(removal.endSeconds == 25)
        #expect(removal.sourceSegmentIDs == ["remove-a", "remove-b"])
        let chapter = try #require(
            forward.entries.first(where: {
                $0.action == .markAsChapter
            })
        )
        #expect(chapter.startSeconds == 12)
        #expect(chapter.endSeconds == 18)
        #expect(forward.entries.count == 3)
    }

    @Test
    func askMustResolveAndExecutionActionsLaunchAfterPart9Execution() throws {
        var policy = SponsorBlockPolicy(
            isEnabled: true,
            selectedCategories: [.sponsor]
        )
        policy.setAction(.ask, for: .sponsor)
        policy.replaceSelection(
            videoID: "video",
            queriedCategories: [.sponsor],
            segments: [testSegment(id: "ask", start: 1, end: 2)]
        )
        #expect(throws: SponsorBlockPlanningError.unresolvedAsk) {
            try SponsorBlockPlanner.makePlan(
                policy: policy,
                videoID: "video",
                analyzedDuration: 100
            )
        }
        var snapshot = try #require(policy.selectionSnapshot)
        snapshot.segments[0].actionOverride = .remove
        policy.selectionSnapshot = snapshot
        let removalPlan = try SponsorBlockPlanner.validateLaunch(
            policy: policy,
            videoID: "video",
            analyzedDuration: 100
        )
        #expect(removalPlan.hasOutputMutation)
        snapshot.segments[0].actionOverride = .keep
        policy.selectionSnapshot = snapshot
        let plan = try SponsorBlockPlanner.validateLaunch(
            policy: policy,
            videoID: "video",
            analyzedDuration: 100
        )
        #expect(!plan.hasOutputMutation)
    }

    @Test
    func plannerRejectsNonFiniteReversedAndOutOfDurationSelections() throws {
        let invalidSegments: [SponsorBlockSegmentSelection] = [
            storedSegment(id: "negative", start: -1, end: 2),
            storedSegment(id: "zero", start: 2, end: 2),
            storedSegment(id: "reversed", start: 4, end: 3),
            storedSegment(id: "nan", start: .nan, end: 2),
        ]
        for segment in invalidSegments {
            let policy = policy(containing: segment)
            #expect(throws: SponsorBlockPlanningError.invalidSegmentRange) {
                try SponsorBlockPlanner.makePlan(
                    policy: policy,
                    videoID: "video",
                    analyzedDuration: 100
                )
            }
        }

        let outside = policy(
            containing: storedSegment(
                id: "outside",
                start: 90,
                end: 101,
                submittedDuration: 120
            )
        )
        #expect(throws: SponsorBlockPlanningError.segmentOutsideDuration) {
            try SponsorBlockPlanner.makePlan(
                policy: outside,
                videoID: "video",
                analyzedDuration: 100
            )
        }
    }

    @Test
    func plannerClampsOnlyNarrowNearEndRepresentationDifference() throws {
        let nearEnd = policy(
            containing: storedSegment(
                id: "near-end",
                start: 90,
                end: 100.26,
                submittedDuration: 100.26
            )
        )
        let plan = try SponsorBlockPlanner.makePlan(
            policy: nearEnd,
            videoID: "video",
            analyzedDuration: 100
        )
        #expect(plan.entries.first?.endSeconds == 100)
        #expect(
            nearEnd.selectionSnapshot?.segments.first?.endSeconds == 100.26
        )

        let materiallyOutside = policy(
            containing: storedSegment(
                id: "materially-outside",
                start: 90,
                end: 100.51,
                submittedDuration: 100.51
            )
        )
        #expect(throws: SponsorBlockPlanningError.segmentOutsideDuration) {
            try SponsorBlockPlanner.makePlan(
                policy: materiallyOutside,
                videoID: "video",
                analyzedDuration: 100
            )
        }
    }

    @Test
    func plannerUsesAnalyzedBoundaryWithUnknownSubmittedDuration() throws {
        let unknown = policy(
            containing: storedSegment(
                id: "unknown-duration",
                start: 10,
                end: 20,
                submittedDuration: 0
            )
        )
        let analyzedPlan = try SponsorBlockPlanner.makePlan(
            policy: unknown,
            videoID: "video",
            analyzedDuration: 30
        )
        #expect(analyzedPlan.entries.count == 1)

        let unavailablePlan = try SponsorBlockPlanner.makePlan(
            policy: unknown,
            videoID: "video",
            analyzedDuration: nil
        )
        #expect(unavailablePlan.entries.count == 1)

        #expect(throws: SponsorBlockPlanningError.segmentOutsideDuration) {
            try SponsorBlockPlanner.makePlan(
                policy: unknown,
                videoID: "video",
                analyzedDuration: 15
            )
        }

        let positiveSubmittedBoundary = policy(
            containing: storedSegment(
                id: "submitted-boundary",
                start: 10,
                end: 20,
                submittedDuration: 15
            )
        )
        #expect(throws: SponsorBlockPlanningError.invalidSegmentRange) {
            try SponsorBlockPlanner.makePlan(
                policy: positiveSubmittedBoundary,
                videoID: "video",
                analyzedDuration: nil
            )
        }
        let authoritativePlan = try SponsorBlockPlanner.makePlan(
            policy: positiveSubmittedBoundary,
            videoID: "video",
            analyzedDuration: 30
        )
        #expect(authoritativePlan.entries.count == 1)
    }
}

private actor SponsorBlockHTTPStub: SponsorBlockHTTPTransport {
    typealias Handler = @Sendable (
        URLRequest,
        Int
    ) async throws -> SponsorBlockHTTPResponse

    private let handler: Handler
    private var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func response(
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> SponsorBlockHTTPResponse {
        requests.append(request)
        return try await handler(request, maximumResponseBytes)
    }

    func capturedRequests() -> [URLRequest] { requests }
}

private final class SponsorBlockTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value.addTimeInterval(interval) }
    }
}

private func HTTPResponse(
    request: URLRequest,
    statusCode: Int,
    data: Data
) -> SponsorBlockHTTPResponse {
    SponsorBlockHTTPResponse(
        data: data,
        response: HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    )
}

private func candidateData(_ candidates: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: candidates, options: [.sortedKeys])
}

private func candidate(
    videoID: String,
    segments: [[String: Any]]
) -> [String: Any] {
    ["videoID": videoID, "segments": segments]
}

private func segmentObject(
    id: String,
    category: SponsorBlockCategory = .sponsor,
    start: Double,
    end: Double,
    duration: Double = 100
) -> [String: Any] {
    [
        "segment": [start, end],
        "UUID": id,
        "category": category.rawValue,
        "videoDuration": duration,
        "actionType": "skip",
        "locked": 0,
        "votes": 1,
        "description": "fixture \(id)",
    ]
}

private func testSegment(
    id: String,
    category: SponsorBlockCategory = .sponsor,
    start: Double,
    end: Double,
    duration: Double = 100
) -> SponsorBlockSegment {
    SponsorBlockSegment(
        segmentID: id,
        category: category,
        startSeconds: start,
        endSeconds: end,
        description: "fixture \(id)",
        submittedVideoDuration: duration,
        serverAction: .skip,
        votes: 1,
        isLocked: false
    )
}

private func storedSegment(
    id: String,
    start: Double,
    end: Double,
    submittedDuration: Double = 100
) -> SponsorBlockSegmentSelection {
    SponsorBlockSegmentSelection(
        segmentID: id,
        category: .sponsor,
        startSeconds: start,
        endSeconds: end,
        description: nil,
        submittedVideoDuration: submittedDuration,
        isIncluded: true,
        actionOverride: .keep
    )
}

private func policy(
    containing segment: SponsorBlockSegmentSelection
) -> SponsorBlockPolicy {
    SponsorBlockPolicy(
        isEnabled: true,
        selectedCategories: [.sponsor],
        selectionSnapshot: SponsorBlockSelectionSnapshot(
            videoID: "video",
            queriedCategories: [.sponsor],
            segments: [segment]
        )
    )
}
