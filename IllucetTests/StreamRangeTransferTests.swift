import Foundation
import Testing
@testable import Illucet

@Suite("Bounded direct-HTTP ranges", .serialized)
struct StreamRangeTransferTests {
    @Test
    func HTTP3HintIsLimitedToHTTPSMediaCDN() {
        for text in ["https://rr1---sn-test.googlevideo.com/videoplayback", "https://GOOGLEVIDEO.COM/media"] {
            #expect(MediaTransportProtocolPolicy.assumesHTTP3Capable(URL(string: text)))
        }
        for text in ["http://rr1.googlevideo.com/media", "https://googlevideo.com.evil.test/media",
                     "https://notgooglevideo.com/media", "https://example.com/media", "https://user@googlevideo.com/media"] {
            #expect(!MediaTransportProtocolPolicy.assumesHTTP3Capable(URL(string: text)))
        }
        #expect(!MediaTransportProtocolPolicy.assumesHTTP3Capable(nil))
    }

    @Test
    func planIsBoundedContiguousAndExact() throws {
        let chunkBytes = StreamRangePlan.minimumChunkBytes
        let totalBytes = chunkBytes * 2 + 17
        let plan = try #require(
            StreamRangePlan(
                expectedTotalBytes: totalBytes,
                suggestedChunkBytes: chunkBytes
            )
        )

        #expect(
            plan.ranges == [
                StreamByteRange(start: 0, end: chunkBytes - 1),
                StreamByteRange(
                    start: chunkBytes,
                    end: chunkBytes * 2 - 1
                ),
                StreamByteRange(
                    start: chunkBytes * 2,
                    end: totalBytes - 1
                ),
            ]
        )
        try StreamRangePlan.validateCoverage(
            plan.ranges,
            totalBytes: totalBytes
        )
        let singleRangePlan = try #require(
            StreamRangePlan(
                expectedTotalBytes: chunkBytes,
                suggestedChunkBytes: chunkBytes
            )
        )
        #expect(
            singleRangePlan.ranges == [
                StreamByteRange(start: 0, end: chunkBytes - 1),
            ]
        )
        #expect(
            StreamRangePlan(
                expectedTotalBytes: chunkBytes * 2,
                suggestedChunkBytes: chunkBytes - 1
            ) == nil
        )
        let cappedPlan = try #require(
            StreamRangePlan(
                expectedTotalBytes:
                    chunkBytes
                        * Int64(StreamRangePlan.maximumRangeCount + 1),
                suggestedChunkBytes: chunkBytes
            )
        )
        #expect(cappedPlan.ranges.count <= StreamRangePlan.maximumRangeCount)
        #expect(cappedPlan.chunkBytes > chunkBytes)
        try StreamRangePlan.validateCoverage(
            cappedPlan.ranges,
            totalBytes: cappedPlan.totalBytes
        )

        let invalidCoverage: [[StreamByteRange]] = [
            [
                StreamByteRange(start: 0, end: chunkBytes - 1),
                StreamByteRange(
                    start: chunkBytes + 1,
                    end: totalBytes - 1
                ),
            ],
            [
                StreamByteRange(start: 0, end: chunkBytes),
                StreamByteRange(
                    start: chunkBytes,
                    end: totalBytes - 1
                ),
            ],
            [
                StreamByteRange(
                    start: chunkBytes,
                    end: totalBytes - 1
                ),
                StreamByteRange(start: 0, end: chunkBytes - 1),
            ],
            [
                StreamByteRange(start: 0, end: totalBytes - 1),
                StreamByteRange(start: 0, end: totalBytes - 1),
            ],
            [StreamByteRange(start: 0, end: totalBytes)],
        ]
        for ranges in invalidCoverage {
            #expect(throws: StreamRangeTransferError.invalidRangePlan) {
                try StreamRangePlan.validateCoverage(
                    ranges,
                    totalBytes: totalBytes
                )
            }
        }
    }

    @Test
    func contentRangeParserRejectsAmbiguousOrImpossibleValues() throws {
        #expect(
            try StreamContentRange.parse("bytes 5-9/10")
                == StreamContentRange(
                    range: StreamByteRange(start: 5, end: 9),
                    totalBytes: 10
                )
        )
        for value in [
            nil,
            "bytes 5-9/*",
            "items 5-9/10",
            "bytes 9-5/10",
            "bytes 5-10/10",
            "bytes +5-9/10",
            "bytes 5-9/11 extra",
        ] as [String?] {
            #expect(throws: StreamRangeTransferError.invalidContentRange) {
                _ = try StreamContentRange.parse(value)
            }
        }
    }

    @Test
    func rangedDescriptorRoundTripsStableSecretFreeIdentity() throws {
        let fixture = try RangeFixture()
        defer { fixture.cleanup() }
        let destination = fixture.destination
        let range = StreamByteRange(start: 0, end: 65_535)
        let staging = StreamRangeStaging.chunkURL(
            in: StreamRangeStaging.directory(
                for: destination,
                role: .video,
                totalBytes: 131_089
            ),
            range: range
        )
        let descriptor = try StreamTransferDescriptor(
            sessionIdentifier: fixture.sessionIdentifier,
            taskIdentifier: 42,
            jobID: fixture.jobID,
            streamID: "137",
            destination: fixture.roots.identity(for: destination),
            mediaRole: .video,
            expectedTotalBytes: 131_089,
            byteRange: range,
            rangeChunkBytes: StreamRangePlan.minimumChunkBytes,
            stagingDestination: fixture.roots.identity(for: staging)
        )

        let encoded = try descriptor.encodedTaskDescription()
        let decoded = try StreamTransferDescriptor.decodeTaskDescription(
            encoded,
            expectedSessionIdentifier: fixture.sessionIdentifier,
            expectedTaskIdentifier: 42
        )

        #expect(decoded == descriptor)
        #expect(try decoded.destinationURL(in: fixture.roots) == destination)
        #expect(try decoded.transferOutputURL(in: fixture.roots) == staging)
        #expect(!encoded.localizedCaseInsensitiveContains("https"))
        #expect(!encoded.localizedCaseInsensitiveContains("signature"))
        #expect(!encoded.localizedCaseInsensitiveContains("cookie"))
        #expect(!encoded.localizedCaseInsensitiveContains("authorization"))

        #expect(throws: StreamTransferDescriptorError.invalidRange) {
            _ = try StreamTransferDescriptor(
                sessionIdentifier: fixture.sessionIdentifier,
                taskIdentifier: 43,
                jobID: fixture.jobID,
                streamID: "137",
                destination: fixture.roots.identity(for: destination),
                mediaRole: .video,
                expectedTotalBytes: 131_089,
                byteRange: range,
                rangeChunkBytes: StreamRangePlan.minimumChunkBytes,
                stagingDestination: nil
            )
        }
        #expect(throws: StreamTransferDescriptorError.invalidRange) {
            _ = try StreamTransferDescriptor(
                sessionIdentifier: fixture.sessionIdentifier,
                taskIdentifier: 44,
                jobID: fixture.jobID,
                streamID: "137",
                destination: fixture.roots.identity(for: destination),
                mediaRole: .video,
                expectedTotalBytes: 131_089,
                byteRange: range,
                rangeChunkBytes: StreamRangePlan.minimumChunkBytes,
                stagingDestination: fixture.roots.identity(
                    for: fixture.root.appending(
                        path: "Temporary/job/unrelated.part"
                    )
                )
            )
        }
    }

    @Test
    func commitRequiresExact206AndContentRangeBeforeStaging() throws {
        let fixture = try RangeFixture()
        defer { fixture.cleanup() }
        let service = fixture.service()
        let data = Self.fixtureData()
        let chunkBytes = StreamRangePlan.minimumChunkBytes
        let range = StreamByteRange(start: 0, end: chunkBytes - 1)
        let staging = StreamRangeStaging.chunkURL(
            in: StreamRangeStaging.directory(
                for: fixture.destination,
                role: .video,
                totalBytes: Int64(data.count)
            ),
            range: range
        )
        let descriptor = try fixture.descriptor(
            taskIdentifier: 1,
            totalBytes: Int64(data.count),
            range: range,
            stagingURL: staging
        )

        let validSource = fixture.root.appending(path: "valid.tmp")
        try data.prefix(Int(chunkBytes)).write(to: validSource)
        #expect(
            service.commitDownloadedFile(
                descriptor: descriptor,
                HTTPStatusCode: 206,
                HTTPContentRange:
                    "bytes 0-\(chunkBytes - 1)/\(data.count)",
                location: validSource
            ) == .success(staging)
        )
        #expect(
            try Data(contentsOf: staging) == data.prefix(Int(chunkBytes))
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destination.path
            )
        )

        for (index, contentRange, body) in [
            (
                2,
                "bytes 1-\(chunkBytes)/\(data.count)",
                Data(data.prefix(Int(chunkBytes)))
            ),
            (
                3,
                "bytes 0-\(chunkBytes - 1)/\(data.count + 1)",
                Data(data.prefix(Int(chunkBytes)))
            ),
            (
                4,
                "bytes 0-\(chunkBytes - 1)/\(data.count)",
                Data(data.prefix(Int(chunkBytes - 1)))
            ),
            (5, nil, Data(data.prefix(Int(chunkBytes)))),
        ] as [(Int, String?, Data)] {
            let source = fixture.root.appending(path: "invalid-\(index).tmp")
            try body.write(to: source)
            let invalidDescriptor = try fixture.descriptor(
                taskIdentifier: index,
                totalBytes: Int64(data.count),
                range: range,
                stagingURL: StreamRangeStaging.chunkURL(
                    in: StreamRangeStaging.directory(
                        for: fixture.destination,
                        role: .video,
                        totalBytes: Int64(data.count)
                    ),
                    range: range
                )
            )
            #expect(
                service.commitDownloadedFile(
                    descriptor: invalidDescriptor,
                    HTTPStatusCode: 206,
                    HTTPContentRange: contentRange,
                    location: source
                ) == .failure(.invalidPartialContent)
            )
            #expect(!FileManager.default.fileExists(atPath: source.path))
        }

        let forbiddenSource = fixture.root.appending(path: "forbidden.tmp")
        try Data("denied".utf8).write(to: forbiddenSource)
        #expect(
            service.commitDownloadedFile(
                descriptor: try fixture.descriptor(
                    taskIdentifier: 6,
                    totalBytes: Int64(data.count),
                    range: range,
                    stagingURL: StreamRangeStaging.chunkURL(
                        in: StreamRangeStaging.directory(
                            for: fixture.destination,
                            role: .video,
                            totalBytes: Int64(data.count)
                        ),
                        range: range
                    )
                ),
                HTTPStatusCode: 403,
                HTTPContentRange: nil,
                location: forbiddenSource
            ) == .failure(.forbiddenHTTPFailure(statusCode: 403))
        )
    }

    @Test
    func rangeRequestHTTP200IsValidatedAsOneFullResponse() throws {
        let fixture = try RangeFixture()
        defer { fixture.cleanup() }
        let service = fixture.service()
        let data = Self.fixtureData()
        let chunkBytes = StreamRangePlan.minimumChunkBytes
        let range = StreamByteRange(start: 0, end: chunkBytes - 1)
        let staging = StreamRangeStaging.chunkURL(
            in: StreamRangeStaging.directory(
                for: fixture.destination,
                role: .video,
                totalBytes: Int64(data.count)
            ),
            range: range
        )
        let descriptor = try fixture.descriptor(
            taskIdentifier: 1,
            totalBytes: Int64(data.count),
            range: range,
            stagingURL: staging
        )
        let fullSource = fixture.root.appending(path: "full.tmp")
        try data.write(to: fullSource)

        #expect(
            service.commitDownloadedFile(
                descriptor: descriptor,
                HTTPStatusCode: 200,
                location: fullSource
            ) == .success(fixture.destination)
        )
        #expect(
            try Data(contentsOf: fixture.destination) == data
        )
        #expect(!FileManager.default.fileExists(atPath: staging.path))

        try FileManager.default.removeItem(at: fixture.destination)
        let shortSource = fixture.root.appending(path: "short-full.tmp")
        try data.dropLast().write(to: shortSource)
        #expect(
            service.commitDownloadedFile(
                descriptor: descriptor,
                HTTPStatusCode: 200,
                location: shortSource
            ) == .failure(.invalidPartialContent)
        )
    }

    @Test
    func assemblerRequiresOrderedExactCoverageAndFinalLength() throws {
        let fixture = try RangeFixture()
        defer { fixture.cleanup() }
        let data = Self.fixtureData()
        let plan = try #require(
            StreamRangePlan(
                expectedTotalBytes: Int64(data.count),
                suggestedChunkBytes: StreamRangePlan.minimumChunkBytes
            )
        )
        let directory = fixture.root.appending(
            path: "assembly-chunks",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let chunks = try plan.ranges.map { range -> StreamRangeChunk in
            let URL = StreamRangeStaging.chunkURL(
                in: directory,
                range: range
            )
            try data.subdata(
                in: Int(range.start) ..< Int(range.end + 1)
            ).write(to: URL)
            return StreamRangeChunk(range: range, fileURL: URL)
        }
        let destination = fixture.root.appending(path: "assembled.media")

        try StreamRangeAssembler.assemble(
            plan: plan,
            chunks: chunks,
            destinationURL: destination,
            fileManager: .default
        )
        #expect(try Data(contentsOf: destination) == data)

        try FileManager.default.removeItem(at: destination)
        #expect(throws: StreamRangeTransferError.invalidRangePlan) {
            try StreamRangeAssembler.assemble(
                plan: plan,
                chunks: Array(chunks.reversed()),
                destinationURL: destination,
                fileManager: .default
            )
        }
        try Data("bad".utf8).write(to: chunks[0].fileURL)
        #expect(throws: StreamRangeTransferError.invalidChunkLength) {
            try StreamRangeAssembler.assemble(
                plan: plan,
                chunks: chunks,
                destinationURL: destination,
                fileManager: .default
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func boundedRangeDownloadBatchesAfterAValidatedProbe() async throws {
        let fixture = try RangeFixture()
        defer { fixture.cleanup() }
        let data = Self.fixtureData()
        RangeDownloadURLProtocol.configure(data: data, mode: .ranges)
        let service = fixture.service(
            protocolClass: RangeDownloadURLProtocol.self
        )
        let progress = RangeProgressRecorder()
        let corruptChunk = StreamRangeStaging.chunkURL(
            in: StreamRangeStaging.directory(
                for: fixture.destination,
                role: .video,
                totalBytes: Int64(data.count)
            ),
            range: StreamByteRange(
                start: 0,
                end: StreamRangePlan.minimumChunkBytes - 1
            )
        )
        try FileManager.default.createDirectory(
            at: corruptChunk.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("unverified".utf8).write(to: corruptChunk)

        let result = try await service.download(
            fixture.stream(expectedBytes: Int64(data.count)),
            jobID: fixture.jobID,
            destinationURL: fixture.destination,
            verifiedExpectedBytes: Int64(data.count)
        ) { event in
            progress.append(event)
        }

        #expect(result.strategy == .boundedRanges)
        #expect(result.plannedRangeCount == 3)
        #expect(result.requestedRangeCount == 3)
        #expect(result.verifiedReusableBytes == 0)
        #expect(result.networkBytesReceived == Int64(data.count))
        #expect(try Data(contentsOf: result.fileURL) == data)
        #expect(
            Set(RangeDownloadURLProtocol.rangeHeaders) == Set([
                "bytes=0-65535",
                "bytes=65536-131071",
                "bytes=131072-131088",
            ])
        )
        #expect(RangeDownloadURLProtocol.maximumActiveRequestCount <= 2)
        #expect(
            progress.events.last?.verifiedReusableBytes
                == Int64(data.count)
        )
        #expect(
            progress.events.last?.totalBytesWritten == Int64(data.count)
        )
    }

    @Test
    func preparedNativeRangesDoNotNeedAProcessingGrantButAssemblyDoes() async throws {
        let fixture = try RangeFixture()
        defer { fixture.cleanup() }
        let data = Self.fixtureData()
        RangeDownloadURLProtocol.configure(data: data, mode: .ranges)
        let service = fixture.service(protocolClass: RangeDownloadURLProtocol.self)
        service.setExecutionGate { _ in throw BackgroundExecutionUnavailable(status: .init(state: .denied)) }
        service.setNativeRequestGate { _ in }
        let plans = RangePlanRecorder()
        service.setTaskPlanHandler { _, descriptors in plans.append(descriptors.count) }
        await #expect(throws: BackgroundExecutionUnavailable.self) {
            _ = try await service.download(fixture.stream(expectedBytes: Int64(data.count)), jobID: fixture.jobID,
                destinationURL: fixture.destination, verifiedExpectedBytes: Int64(data.count), progress: { _ in })
        }
        #expect(plans.counts == [1, 2])
        #expect(RangeDownloadURLProtocol.rangeHeaders.count == 3)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        let staging = StreamRangeStaging.directory(for: fixture.destination, role: .video, totalBytes: Int64(data.count))
        let files = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.fileSizeKey])
        #expect(files.count == 3)
        #expect(try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) } == data.count)
    }

    @Test
    func preparedResultSurvivesOtherJobsFillingTheTerminalCache() async throws {
        let fixture = try RangeFixture()
        defer { fixture.cleanup() }
        let registry = StreamTransferLifecycleRegistry()
        var pinned: StreamTransferDescriptor?
        var token: UUID?
        for id in 1...200 {
            let destination = fixture.roots.temporaryDirectory.appending(path: "job/\(id).mp4")
            let descriptor = try StreamTransferDescriptor(sessionIdentifier: fixture.sessionIdentifier,
                taskIdentifier: id, jobID: fixture.jobID, streamID: String(id),
                destination: fixture.roots.identity(for: destination))
            if id == 1 {
                pinned = descriptor
                token = registry.retainResult(taskIdentifier: id)
            }
            registry.completeTask(taskIdentifier: id, decodedDescriptor: descriptor,
                transportFailure: id == 1 ? .forbiddenHTTPFailure(statusCode: 403) : .networkFailure,
                fallbackResult: { _ in .failure(.couldNotCommitFile) }).resume()
        }
        let descriptor = try #require(pinned)
        let retention = try #require(token)
        defer { registry.releaseResult(taskIdentifier: 1, token: retention) }
        let waiter = UUID()
        await #expect(throws: StreamDownloadError.forbiddenHTTPFailure(statusCode: 403)) {
            let _: URL = try await withCheckedThrowingContinuation { continuation in
                if let result = registry.registerWaiter(taskIdentifier: 1, descriptor: descriptor,
                    finalURL: fixture.destination, waiterID: waiter, progress: { _ in }, continuation: continuation,
                    progressBaseBytes: 0, verifiedBaseBytes: 0, networkBaseBytes: 0, logicalExpectedBytes: nil) {
                    continuation.resume(with: result.mapError { $0 as Error })
                } else { registry.cancelWaiter(taskIdentifier: 1, waiterID: waiter) }
            }
        }
    }

    @Test
    func ignoredRangePublishesValidatedFullResponseWithoutChunking()
        async throws
    {
        let fixture = try RangeFixture()
        defer { fixture.cleanup() }
        let data = Self.fixtureData()
        RangeDownloadURLProtocol.configure(
            data: data,
            mode: .ignoreRangeWithFullResponse
        )
        let service = fixture.service(
            protocolClass: RangeDownloadURLProtocol.self
        )
        let progress = RangeProgressRecorder()
        let firstRange = StreamByteRange(
            start: 0,
            end: StreamRangePlan.minimumChunkBytes - 1
        )
        let firstChunk = StreamRangeStaging.chunkURL(
            in: StreamRangeStaging.directory(
                for: fixture.destination,
                role: .video,
                totalBytes: Int64(data.count)
            ),
            range: firstRange
        )
        try FileManager.default.createDirectory(
            at: firstChunk.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.prefix(Int(firstRange.length)).write(to: firstChunk)

        let result = try await service.download(
            fixture.stream(expectedBytes: Int64(data.count)),
            jobID: fixture.jobID,
            destinationURL: fixture.destination,
            verifiedExpectedBytes: Int64(data.count)
        ) { event in
            progress.append(event)
        }

        #expect(result.strategy == .rangeIgnoredFullResponse)
        #expect(result.plannedRangeCount == 3)
        #expect(result.requestedRangeCount == 1)
        #expect(result.verifiedReusableBytes == firstRange.length)
        #expect(result.networkBytesReceived == Int64(data.count))
        #expect(
            RangeDownloadURLProtocol.rangeHeaders == ["bytes=65536-131071"]
        )
        #expect(
            progress.events.allSatisfy {
                $0.totalBytesWritten <= Int64(data.count)
                    && $0.networkBytesReceived <= Int64(data.count)
            }
        )
        #expect(try Data(contentsOf: result.fileURL) == data)
    }

    @Test
    func oneGETRequiresUntrustedSizeWhileSingleChunkUsesRange()
        async throws
    {
        let fixture = try RangeFixture()
        defer { fixture.cleanup() }
        let data = Self.fixtureData()
        let service = fixture.service(
            protocolClass: RangeDownloadURLProtocol.self
        )

        RangeDownloadURLProtocol.configure(
            data: data,
            mode: .ignoreRangeWithFullResponse
        )
        let untrustedSize = try await service.download(
            fixture.stream(expectedBytes: Int64(data.count)),
            jobID: fixture.jobID,
            destinationURL: fixture.destination,
            verifiedExpectedBytes: nil
        ) { _ in }

        #expect(untrustedSize.strategy == .oneGET)
        #expect(untrustedSize.plannedRangeCount == 0)
        #expect(untrustedSize.requestedRangeCount == 0)
        #expect(RangeDownloadURLProtocol.rangeHeaders == ["none"])
        #expect(try Data(contentsOf: untrustedSize.fileURL) == data)

        try FileManager.default.removeItem(at: fixture.destination)
        RangeDownloadURLProtocol.configure(
            data: data,
            mode: .ranges
        )
        let singleChunk = try await service.download(
            fixture.stream(
                expectedBytes: Int64(data.count),
                httpChunkSize: Int64(data.count)
            ),
            jobID: fixture.jobID,
            destinationURL: fixture.destination,
            verifiedExpectedBytes: Int64(data.count)
        ) { _ in }

        #expect(singleChunk.strategy == .boundedRanges)
        #expect(singleChunk.plannedRangeCount == 1)
        #expect(singleChunk.requestedRangeCount == 1)
        #expect(
            RangeDownloadURLProtocol.rangeHeaders
                == ["bytes=0-\(data.count - 1)"]
        )
        #expect(try Data(contentsOf: singleChunk.fileURL) == data)
    }

    @Test
    func cancellationPreservesOnlyCompletedRangesForReplacement()
        async throws
    {
        let fixture = try RangeFixture()
        defer { fixture.cleanup() }
        let data = Self.fixtureData()
        let chunkBytes = StreamRangePlan.minimumChunkBytes
        RangeDownloadURLProtocol.configure(
            data: data,
            mode: .holdRangeStartingAt(chunkBytes)
        )
        let service = fixture.service(
            protocolClass: RangeDownloadURLProtocol.self
        )
        let stream = fixture.stream(expectedBytes: Int64(data.count))
        let firstAttempt = Task {
            try await service.download(
                stream,
                jobID: fixture.jobID,
                destinationURL: fixture.destination,
                verifiedExpectedBytes: Int64(data.count)
            ) { _ in }
        }
        defer { firstAttempt.cancel() }
        try await waitUntil {
            RangeDownloadURLProtocol.rangeHeaders.count >= 2
        }
        try await waitUntilAsync {
            await service.nativeTaskSnapshot().contains {
                $0.descriptor.byteRange?.start == chunkBytes
                    && $0.networkBytesReceived == RangeDownloadURLProtocol.heldPartialByteCount
            }
        }

        let tail = StreamRangeStaging.chunkURL(in: StreamRangeStaging.directory(
            for: fixture.destination, role: .video, totalBytes: Int64(data.count)),
            range: StreamByteRange(start: chunkBytes * 2, end: Int64(data.count) - 1))
        try await waitUntil { FileManager.default.fileExists(atPath: tail.path) }
        // Publishing the completed tail precedes URLSession removing its task.
        // Wait for both native and registry teardown before testing one-live-range controls.
        try await waitUntilAsync {
            let tasks = await service.nativeTaskSnapshot()
            let known = service.lifecycle.knownTasks(jobID: fixture.jobID)
            return tasks.count == 1 && known.count == 1
                && known[0].taskIdentifier == tasks[0].descriptor.taskIdentifier
                && tasks[0].descriptor.byteRange?.start == chunkBytes
                && tasks[0].networkBytesReceived == RangeDownloadURLProtocol.heldPartialByteCount
        }
        let pause = await service.pause(jobID: fixture.jobID)
        #expect(pause.matchedTaskCount == 1)
        #expect(pause.affectedTaskCount == 1)
        #expect(pause.fullyAcknowledged)
        let resume = await service.resume(jobID: fixture.jobID)
        #expect(resume.matchedTaskCount == 1)
        #expect(resume.affectedTaskCount == 1)
        #expect(resume.fullyAcknowledged)

        let verifiedBytes = Int64(data.count) - chunkBytes
        let registrations = await service.reconcileBackgroundTasks()
        let registration = try #require(registrations.first)
        #expect(registration.descriptor.byteRange?.start == chunkBytes)
        #expect(registration.verifiedReusableBytes == verifiedBytes)
        #expect(
            registration.bytesReceived
                == verifiedBytes
                    + RangeDownloadURLProtocol.heldPartialByteCount
        )
        #expect(
            registration.networkBytesReceived
                == RangeDownloadURLProtocol.heldPartialByteCount
        )
        #expect(registration.totalBytesExpected == Int64(data.count))

        let cancellation = await service.cancel(jobID: fixture.jobID)
        #expect(cancellation.matchedTaskCount == 1)
        #expect(cancellation.fullyAcknowledged)
        await #expect(throws: StreamDownloadError.cancelled) {
            _ = try await firstAttempt.value
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destination.path
            )
        )
        let firstRange = StreamByteRange(
            start: 0,
            end: chunkBytes - 1
        )
        let firstChunk = StreamRangeStaging.chunkURL(
            in: StreamRangeStaging.directory(
                for: fixture.destination,
                role: .video,
                totalBytes: Int64(data.count)
            ),
            range: firstRange
        )
        #expect(
            try Data(contentsOf: firstChunk)
                == data.prefix(Int(chunkBytes))
        )

        RangeDownloadURLProtocol.setMode(.ranges)
        let restoredService = fixture.service(
            protocolClass: RangeDownloadURLProtocol.self
        )
        let replacement = try await restoredService.download(
            stream,
            jobID: fixture.jobID,
            destinationURL: fixture.destination,
            verifiedExpectedBytes: Int64(data.count)
        ) { _ in }

        #expect(replacement.strategy == .boundedRanges)
        #expect(replacement.verifiedReusableBytes == verifiedBytes)
        #expect(replacement.requestedRangeCount == 1)
        #expect(
            replacement.networkBytesReceived
                == chunkBytes
        )
        #expect(try Data(contentsOf: replacement.fileURL) == data)
        #expect(
            RangeDownloadURLProtocol.rangeHeaders.filter {
                $0 == "bytes=0-65535"
            }.count == 1
        )
    }

    private static func fixtureData() -> Data {
        Data((0 ..< 131_089).map { UInt8($0 % 251) })
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () -> Bool
    ) async throws {
        for _ in 0 ..< 1_000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RangeTransferTestError.timeout
    }

    private func waitUntilAsync(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0 ..< 1_000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RangeTransferTestError.timeout
    }
}

private final class RangePlanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ count: Int) { lock.withLock { values.append(count) } }
    var counts: [Int] { lock.withLock { values } }
}

private struct RangeFixture {
    let root: URL
    let roots: StreamTransferDestinationRoots
    let sessionIdentifier: String
    let jobID = UUID()

    var destination: URL {
        roots.temporaryDirectory.appending(path: "job/137.mp4")
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-RangeTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        roots = StreamTransferDestinationRoots(
            temporaryDirectory: root.appending(
                path: "Temporary",
                directoryHint: .isDirectory
            ),
            applicationSupportDirectory: root.appending(
                path: "ApplicationSupport",
                directoryHint: .isDirectory
            )
        )
        sessionIdentifier = "tests.illucet.ranges.\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            at: roots.temporaryDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: roots.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
    }

    func service(
        protocolClass: AnyClass? = nil
    ) -> StreamDownloadService {
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClass {
            configuration.protocolClasses = [protocolClass]
        }
        return StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: sessionIdentifier,
            configuration: configuration,
            destinationRoots: roots
        )
    }

    func stream(
        expectedBytes: Int64,
        httpChunkSize: Int64 = StreamRangePlan.minimumChunkBytes
    ) -> ResolvedStream {
        ResolvedStream(
            formatID: "137",
            URL: URL(string: "https://illucet.range.test/media")!,
            HTTPHeaders: ["User-Agent": "Illucet-Range-Test"],
            fileExtension: "mp4",
            protocolName: "https",
            sourceType: "direct_http",
            hasVideo: true,
            hasAudio: false,
            expectedBytes: expectedBytes,
            httpChunkSize: httpChunkSize
        )
    }

    func descriptor(
        taskIdentifier: Int,
        totalBytes: Int64,
        range: StreamByteRange,
        stagingURL: URL
    ) throws -> StreamTransferDescriptor {
        try StreamTransferDescriptor(
            sessionIdentifier: sessionIdentifier,
            taskIdentifier: taskIdentifier,
            jobID: jobID,
            streamID: "137",
            destination: roots.identity(for: destination),
            mediaRole: .video,
            expectedTotalBytes: totalBytes,
            byteRange: range,
            rangeChunkBytes: StreamRangePlan.minimumChunkBytes,
            stagingDestination: roots.identity(for: stagingURL)
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RangeProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [StreamTransferProgress] = []

    var events: [StreamTransferProgress] {
        lock.withLock { stored }
    }

    func append(_ event: StreamTransferProgress) {
        lock.withLock { stored.append(event) }
    }
}

private final class RangeDownloadURLProtocol: URLProtocol {
    static let heldPartialByteCount: Int64 = 4_096

    enum Mode: Equatable, Sendable {
        case ranges
        case ignoreRangeWithFullResponse
        case holdRangeStartingAt(Int64)
    }

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var dataStorage = Data()
    nonisolated(unsafe) private static var modeStorage = Mode.ranges
    nonisolated(unsafe) private static var rangeHeadersStorage: [String] = []
    nonisolated(unsafe) private static var activeRequestCountStorage = 0
    nonisolated(unsafe) private static var maximumActiveRequestCountStorage = 0

    private let instanceLock = NSLock()
    private var stopped = false
    private var finished = false
    private let responseGate = DispatchSemaphore(value: 0)
    private lazy var workBox = RangeURLProtocolWorkBox(self)

    static var rangeHeaders: [String] {
        stateLock.withLock { rangeHeadersStorage }
    }

    static var maximumActiveRequestCount: Int {
        stateLock.withLock { maximumActiveRequestCountStorage }
    }

    static func configure(data: Data, mode: Mode) {
        stateLock.withLock {
            dataStorage = data
            modeStorage = mode
            rangeHeadersStorage = []
            activeRequestCountStorage = 0
            maximumActiveRequestCountStorage = 0
        }
    }

    static func setMode(_ mode: Mode) {
        stateLock.withLock { modeStorage = mode }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "illucet.range.test"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let header = request.value(forHTTPHeaderField: "Range") ?? "none"
        let state = Self.stateLock.withLock { () -> (Data, Mode) in
            Self.rangeHeadersStorage.append(header)
            Self.activeRequestCountStorage += 1
            Self.maximumActiveRequestCountStorage = max(
                Self.maximumActiveRequestCountStorage,
                Self.activeRequestCountStorage
            )
            return (Self.dataStorage, Self.modeStorage)
        }
        let workBox = workBox
        DispatchQueue.global(qos: .utility).async {
            workBox.value?.respond(
                data: state.0,
                mode: state.1,
                rangeHeader: header
            )
        }
    }

    override func stopLoading() {
        instanceLock.withLock { stopped = true }
        finishRequest()
        responseGate.signal()
    }

    private func respond(
        data: Data,
        mode: Mode,
        rangeHeader: String
    ) {
        let requestedRange = Self.requestedRange(rangeHeader)
        guard !instanceLock.withLock({ stopped }) else {
            finishRequest()
            return
        }
        let statusCode: Int
        let responseData: Data
        var headers: [String: String] = [
            "Content-Type": "application/octet-stream",
        ]
        switch mode {
        case .ignoreRangeWithFullResponse:
            statusCode = 200
            responseData = data
        case .ranges, .holdRangeStartingAt:
            guard
                let requestedRange,
                requestedRange.start >= 0,
                requestedRange.end >= requestedRange.start,
                requestedRange.end < Int64(data.count)
            else {
                fail(URLError(.badServerResponse))
                return
            }
            statusCode = 206
            responseData = data.subdata(
                in: Int(requestedRange.start)
                    ..< Int(requestedRange.end + 1)
            )
            headers["Content-Range"] =
                "bytes \(requestedRange.start)-\(requestedRange.end)/\(data.count)"
        }
        headers["Content-Length"] = String(responseData.count)
        guard
            let URL = request.url,
            let response = HTTPURLResponse(
                url: URL,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )
        else {
            fail(URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        if case let .holdRangeStartingAt(start) = mode,
           requestedRange?.start == start {
            let partialCount = min(
                Int(Self.heldPartialByteCount),
                responseData.count
            )
            client?.urlProtocol(
                self,
                didLoad: responseData.prefix(partialCount)
            )
            // The test, rather than a five-second timer, owns cancellation.
            responseGate.wait()
            return
        } else {
            client?.urlProtocol(self, didLoad: responseData)
        }
        finishRequest()
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ error: Error) {
        guard !instanceLock.withLock({ stopped }) else {
            finishRequest()
            return
        }
        finishRequest()
        client?.urlProtocol(self, didFailWithError: error)
    }

    private func finishRequest() {
        let shouldFinish = instanceLock.withLock { () -> Bool in
            guard !finished else { return false }
            finished = true
            return true
        }
        guard shouldFinish else { return }
        Self.stateLock.withLock {
            Self.activeRequestCountStorage = max(
                0,
                Self.activeRequestCountStorage - 1
            )
        }
    }

    private static func requestedRange(
        _ header: String
    ) -> StreamByteRange? {
        guard header.hasPrefix("bytes=") else { return nil }
        let bounds = header.dropFirst("bytes=".count).split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard
            bounds.count == 2,
            let start = Int64(bounds[0]),
            let end = Int64(bounds[1])
        else {
            return nil
        }
        return StreamByteRange(start: start, end: end)
    }
}

private final class RangeURLProtocolWorkBox: @unchecked Sendable {
    weak var value: RangeDownloadURLProtocol?

    init(_ value: RangeDownloadURLProtocol) {
        self.value = value
    }
}

private enum RangeTransferTestError: Error {
    case timeout
}
