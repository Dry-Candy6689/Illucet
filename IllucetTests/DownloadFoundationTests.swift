import Foundation
import Testing
@testable import Illucet

@Suite("scheduling foundations")
struct DownloadFoundationTests {
    @Test
    func postTransferStagesUseTruthfulDistinctLabels() {
        #expect(
            DownloadStage.burningInSubtitles.rawValue
                == "Burning in subtitles"
        )
        #expect(
            DownloadStage.writingChapters.rawValue
                == "Writing chapters"
        )
        #expect(
            DownloadStage.burningInSubtitles
                != DownloadStage.embeddingSubtitles
        )
        #expect(
            DownloadStage.writingChapters
                != DownloadStage.embeddingMetadata
        )
        #expect(!DownloadStage.burningInSubtitles.presentsTransferMetrics)
        #expect(!DownloadStage.writingChapters.presentsTransferMetrics)
    }

    @Test
    func processingWorkClassificationCoversEveryPostTransferWorkStage() {
        let classified = Set(
            DownloadStage.allCases.filter(\.isProcessingWork)
        )
        let expected: Set<DownloadStage> = [
            .verifyingSources,
            .merging,
            .converting,
            .embeddingMetadata,
            .embeddingSubtitles,
            .burningInSubtitles,
            .removingSponsorSegments,
            .trimming,
            .writingChapters,
            .splittingChapters,
            .packaging,
            .zipping,
            .verifyingOutput,
        ]

        #expect(classified == expected)
    }

    @Test
    func processingProgressAdvancesOnlyTheExpectedActiveStage() {
        #expect(
            DownloadStage.merging.applyingProcessingProgress(
                expectedStage: .merging,
                eventStage: .probing
            ) == .verifyingOutput
        )
        #expect(
            DownloadStage.merging.applyingProcessingProgress(
                expectedStage: .merging,
                eventStage: .verifying
            ) == .verifyingOutput
        )
        #expect(
            DownloadStage.verifyingOutput.applyingProcessingProgress(
                expectedStage: .merging,
                eventStage: .verifying
            ) == .verifyingOutput
        )
        #expect(
            DownloadStage.verifyingOutput.applyingProcessingProgress(
                expectedStage: .merging,
                eventStage: .encoding
            ) == nil
        )
        #expect(
            DownloadStage.embeddingMetadata.applyingProcessingProgress(
                expectedStage: .merging,
                eventStage: .verifying
            ) == nil
        )
        #expect(
            DownloadStage.savingFiles.applyingProcessingProgress(
                expectedStage: .merging,
                eventStage: .verifying
            ) == nil
        )
    }

    @Test
    func networkPolicyDistinguishesConnectivityAndUserApproval() {
        let defaultPolicy = NetworkAccessPolicy(
            wifiOnly: false,
            askBeforeCellular: true
        )
        #expect(
            defaultPolicy.decision(for: .unavailable)
                == .waitForConnectivity
        )

        let cellular = NetworkPathSnapshot(
            isSatisfied: true,
            interface: .cellular,
            isExpensive: true,
            isConstrained: false
        )
        #expect(
            defaultPolicy.decision(for: cellular)
                == .requireCellularConfirmation
        )
        #expect(
            defaultPolicy.decision(
                for: cellular,
                cellularApprovalGranted: true
            ) == .allow
        )

        let wifiOnly = NetworkAccessPolicy(
            wifiOnly: true,
            askBeforeCellular: false
        )
        #expect(
            wifiOnly.decision(for: cellular) == .waitForWiFi
        )
        let wifi = NetworkPathSnapshot(
            isSatisfied: true,
            interface: .wifi,
            isExpensive: false,
            isConstrained: false
        )
        #expect(wifiOnly.decision(for: wifi) == .allow)
    }

    @Test
    func networkPolicyRespectsExpensiveAndConstrainedPaths() {
        let policy = NetworkAccessPolicy(
            wifiOnly: false,
            askBeforeCellular: false,
            allowsExpensiveAccess: false,
            allowsConstrainedAccess: false
        )
        let constrained = NetworkPathSnapshot(
            isSatisfied: true,
            interface: .wifi,
            isExpensive: false,
            isConstrained: true
        )
        #expect(
            policy.decision(for: constrained)
                == .waitForUnconstrainedNetwork
        )
        let expensive = NetworkPathSnapshot(
            isSatisfied: true,
            interface: .other,
            isExpensive: true,
            isConstrained: false
        )
        #expect(
            policy.decision(for: expensive)
                == .waitForUnmeteredNetwork
        )
    }

    @Test
    func permitPoolIsFIFOAndCanGrowDynamically() async throws {
        let pool = AsyncPermitPool(limit: 1)
        let first = try await pool.acquire()

        let secondTask = Task { try await pool.acquire() }
        try await waitUntil {
            await pool.snapshot().waitingCount == 1
        }
        let thirdTask = Task { try await pool.acquire() }
        try await waitUntil {
            await pool.snapshot().waitingCount == 2
        }

        await pool.release(first)
        let second = try await secondTask.value
        let beforeResize = await pool.snapshot()
        #expect(beforeResize.activeCount == 1)
        #expect(beforeResize.waitingCount == 1)

        await pool.resize(to: 2)
        let third = try await thirdTask.value
        let afterResize = await pool.snapshot()
        #expect(afterResize.limit == 2)
        #expect(afterResize.activeCount == 2)
        #expect(afterResize.waitingCount == 0)

        await pool.release(second)
        await pool.release(third)
        #expect(await pool.snapshot().activeCount == 0)
    }

    @Test
    func cancelledPermitWaiterDoesNotConsumeCapacity() async throws {
        let pool = AsyncPermitPool(limit: 1)
        let first = try await pool.acquire()
        let waiter = Task { try await pool.acquire() }
        try await waitUntil {
            await pool.snapshot().waitingCount == 1
        }

        waiter.cancel()
        var observedCancellation = false
        do {
            _ = try await waiter.value
        } catch is CancellationError {
            observedCancellation = true
        }
        #expect(observedCancellation)
        try await waitUntil {
            await pool.snapshot().waitingCount == 0
        }

        await pool.release(first)
        let replacement = try await pool.acquire()
        #expect(await pool.snapshot().activeCount == 1)
        await pool.release(replacement)
        #expect(await pool.snapshot().activeCount == 0)
    }

    @Test
    func shrinkingPermitPoolWaitsForExistingWorkToDrain() async throws {
        let pool = AsyncPermitPool(limit: 2)
        let first = try await pool.acquire()
        let second = try await pool.acquire()
        await pool.resize(to: 1)

        let waiter = Task { try await pool.acquire() }
        try await waitUntil {
            await pool.snapshot().waitingCount == 1
        }
        await pool.release(first)
        #expect(await pool.snapshot().waitingCount == 1)
        await pool.release(second)

        let replacement = try await waiter.value
        #expect(await pool.snapshot().activeCount == 1)
        await pool.release(replacement)
    }

    @Test
    func permitIsReleasedWhenOperationThrows() async {
        let pool = AsyncPermitPool(limit: 1)
        do {
            _ = try await pool.withPermit {
                throw FoundationTestError.expected
            } as Void
            Issue.record("Expected the permitted operation to throw.")
        } catch FoundationTestError.expected {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await pool.snapshot().activeCount == 0)
    }

    @Test
    func retryBackoffIsExponentialAndBounded() {
        let policy = DownloadRetryPolicy(
            initialDelaySeconds: 1,
            multiplier: 2,
            maximumDelaySeconds: 10
        )
        #expect(
            (1 ... 6).map(policy.delay(forRetryNumber:))
                == [1, 2, 4, 8, 10, 10]
        )
    }

    @Test
    func HLSFailuresRespectRetryLimitsCancellationAndPermanentValidation() {
        let policy = DownloadRetryPolicy()
        let retryable: [any Error] = [
            HLSResourceStagingError.networkFailure,
            HLSAES128KeyLoadingError.networkFailure,
            HLSPlaylistResolutionError.bridgeUnavailable,
            HLSPlaylistResolutionError.resolverFailure(
                code: "http_503",
                details: StreamResolutionFailureDetails(code: "http_503", message: "Unavailable", retryable: true)
            ),
            StreamDownloadError.HTTPFailure(statusCode: 429),
            StreamDownloadError.HTTPFailure(statusCode: 503),
        ]
        for error in retryable {
            guard case .retry = policy.disposition(for: error, retriesAlreadyUsed: 0, maximumRetries: 2) else {
                Issue.record("Expected bounded HLS retry for \(error)")
                continue
            }
            #expect(policy.disposition(for: error, retriesAlreadyUsed: 2, maximumRetries: 2) == .doNotRetry)
        }
        let permanent: [any Error] = [
            HLSResourceStagingError.unsafeRedirect,
            HLSResourceStagingError.invalidHTTPResponse,
            HLSAES128KeyLoadingError.invalidResponse,
            HLSAES128KeyLoadingError.unsafeRedirect,
            HLSPlaylistTransportError.responseTooLarge,
            HLSPlaylistResolutionError.identityMismatch,
            StreamDownloadError.HTTPFailure(statusCode: 401),
            StreamDownloadError.HTTPFailure(statusCode: 404),
        ]
        for error in permanent { #expect(policy.classify(error) == .permanent) }
        #expect(policy.classify(HLSPlaylistResolutionError.cancelled) == .cancelled)
        #expect(policy.classify(DASHFragmentResolutionError.cancelled) == .cancelled)
        #expect(policy.classify(MediaProcessorError.cancelled) == .cancelled)
        #expect(policy.classify(URLError(.cancelled)) == .cancelled)
        #expect(policy.classify(URLError(.notConnectedToInternet)) == .waitForConnectivity)
    }

    @Test
    func retryPolicyPreservesTypedRetryability() {
        let policy = DownloadRetryPolicy()
        let temporary = ExtractionError.extractorFailure(
            code: "service_unavailable",
            message: "Try again.",
            retryable: true
        )
        #expect(
            policy.disposition(
                for: temporary,
                retriesAlreadyUsed: 0,
                maximumRetries: 2
            ) == .retry(
                reason: .extractorTemporarilyUnavailable,
                delaySeconds: 1,
                reResolveStreams: true
            )
        )

        let permanent = ExtractionError.extractorFailure(
            code: "private_video",
            message: "Unavailable.",
            retryable: false
        )
        #expect(
            policy.disposition(
                for: permanent,
                retriesAlreadyUsed: 0,
                maximumRetries: 2
            ) == .doNotRetry
        )
    }

    @Test
    func retryPolicyDistinguishesHTTPResolutionFailuresAndLimit() {
        let policy = DownloadRetryPolicy()
        let forbidden = StreamResolutionError.resolverFailure(
            code: "http_403",
            details: StreamResolutionFailureDetails(
                code: "http_403",
                message: "Access denied.",
                retryable: true
            )
        )
        #expect(
            policy.disposition(
                for: forbidden,
                retriesAlreadyUsed: 1,
                maximumRetries: 2
            ) == .retry(
                reason: .mediaAccessForbidden,
                delaySeconds: 2,
                reResolveStreams: true
            )
        )
        #expect(
            policy.disposition(
                for: forbidden,
                retriesAlreadyUsed: 2,
                maximumRetries: 2
            ) == .doNotRetry
        )
        #expect(
            policy.classify(
                StreamResolutionError.resolverFailure(
                    code: "http_401",
                    details: StreamResolutionFailureDetails(
                        code: "http_401",
                        message: "Authorization required.",
                        retryable: true
                    )
                )
            ) == .permanent
        )
        #expect(
            policy.classify(
                StreamResolutionError.resolverFailure(
                    code: "http_410",
                    details: StreamResolutionFailureDetails(
                        code: "http_410",
                        message: "Gone.",
                        retryable: true
                    )
                )
            ) == .retryable(
                reason: .mediaURLGone,
                reResolveStreams: true
            )
        )
    }

    @Test
    func retryPolicyWaitsOfflineAndRejectsPermissionFailures() {
        let policy = DownloadRetryPolicy()
        #expect(
            policy.disposition(
                for: URLError(.notConnectedToInternet),
                retriesAlreadyUsed: 20,
                maximumRetries: 0
            ) == .waitForConnectivity
        )
        #expect(
            policy.disposition(
                for: IllucetError.photosPermissionDenied,
                retriesAlreadyUsed: 0,
                maximumRetries: 4
            ) == .doNotRetry
        )
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0 ..< 2_000 {
            if await predicate() {
                return
            }
            await Task.yield()
        }
        throw FoundationTestError.timeout
    }

    @Test
    func storageAdmissionRejectsOverflowAndNegativeBudgets() async throws {
        let storage = StorageManager()
        await #expect(throws: IllucetError.self) {
            try await storage.preflight(requiredBytes: .max, reserveBytes: 1)
        }
        await #expect(throws: IllucetError.self) {
            try await storage.preflight(requiredBytes: 1, reserveBytes: -1)
        }
        try StorageByteArithmetic.validateBudget(requiredBytes: 9, reserveBytes: 1, availableBytes: 10)
        #expect(throws: IllucetError.insufficientStorage(required: 10, available: 9)) {
            try StorageByteArithmetic.validateBudget(requiredBytes: 9, reserveBytes: 1, availableBytes: 9)
        }
        #expect(throws: IllucetError.self) {
            try StorageByteArithmetic.validateBudget(requiredBytes: .max, reserveBytes: 1, availableBytes: .max)
        }
    }

    @Test
    func metadataStorageEstimatesCannotOverflow() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(DeveloperFixtures.media)
        ) as? [String: Any])
        var formats = try #require(object["formats"] as? [[String: Any]])
        for index in formats.indices {
            formats[index]["exact_file_size_bytes"] = Int64.max
        }
        object["formats"] = formats
        let metadata = try JSONDecoder().decode(MediaMetadata.self, from: JSONSerialization.data(withJSONObject: object))
        var configuration = DownloadConfiguration.standard
        configuration.selectedVideoFormatID = "137"
        configuration.selectedAudioFormatID = "140"
        #expect(FormatSelection.estimatedDownloadBytes(configuration: configuration, metadata: metadata) == .max)
        #expect(FormatSelection.estimatedTemporaryBytes(configuration: configuration, metadata: metadata) == .max)

        let preset = try #require(QuickStartPresetLibrary.legacyDefaults.first { $0.name == "MP3 Audio" })
        configuration = try preset.resolvedConfiguration(metadata: DeveloperFixtures.media)
        configuration.destination = .appDocuments
        #expect(throws: IllucetError.self) {
            try QuickStartLaunchPolicy.validate(
                configuration: configuration, metadata: DeveloperFixtures.media,
                hasFilesFolder: true, availableBytes: .max, reserveBytes: .max
            )
        }
        #expect(StorageByteArithmetic.audioEstimate(durationSeconds: .greatestFiniteMagnitude, bitrateKbps: 320) == .max)
        #expect(StorageByteArithmetic.audioEstimate(durationSeconds: Double(Int64.max), bitrateKbps: 8) == .max)
        #expect(StorageByteArithmetic.audioEstimate(durationSeconds: .nan, bitrateKbps: 320) == nil)
        #expect(StorageByteArithmetic.audioEstimate(durationSeconds: .infinity, bitrateKbps: 320) == nil)
        #expect(StorageByteArithmetic.audioEstimate(durationSeconds: -1, bitrateKbps: 320) == nil)
        #expect(StorageByteArithmetic.audioEstimate(durationSeconds: 10, bitrateKbps: 192) == 240_000)
    }

    @Test
    func temporaryCleanupUsesAgeAndProtectsRecoverableJobs()
        async throws
    {
        let fileManager = FileManager.default
        let removableID = UUID()
        let protectedID = UUID()
        let removable = fileManager.temporaryDirectory.appending(
            path: "Illucet-\(removableID.uuidString)",
            directoryHint: .isDirectory
        )
        let protected = fileManager.temporaryDirectory.appending(
            path: "Illucet-\(protectedID.uuidString)",
            directoryHint: .isDirectory
        )
        defer {
            try? fileManager.removeItem(at: removable)
            try? fileManager.removeItem(at: protected)
        }
        try fileManager.createDirectory(
            at: removable,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: protected,
            withIntermediateDirectories: true
        )
        let oldDate = Date(timeIntervalSince1970: 946_684_800)
        try fileManager.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: removable.path
        )
        try fileManager.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: protected.path
        )

        let result = try await StorageManager().clearTemporaryFiles(
            olderThan: oldDate.addingTimeInterval(60),
            excludingJobIDs: [protectedID]
        )

        #expect(!fileManager.fileExists(atPath: removable.path))
        #expect(fileManager.fileExists(atPath: protected.path))
        #expect(result.removedDirectories >= 1)
        #expect(result.protectedDirectories >= 1)
    }
}

private enum FoundationTestError: Error {
    case expected
    case timeout
}
