import Foundation
import Testing
@testable import Illucet

@Suite("Background transfer restoration", .serialized)
struct BackgroundTransferTests {
    @Test(arguments: [false, true])
    func preCancelledBoundedRequestDoesNotStartNetwork(subtitles: Bool) async throws {
        PrecancelledRequestURLProtocol.reset()
        let gate = BoundedRequestStartGate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrecancelledRequestURLProtocol.self]
        let request = URLRequest(url: URL(string: "https://cancel.test/fixture")!)
        let task = Task {
            await gate.waitForRelease()
            if subtitles {
                return try await BoundedSubtitleRequest.perform(
                    request: request, configuration: configuration, maximumBytes: 32
                ).body
            }
            return try await BoundedHLSPlaylistRequest.perform(
                request: request, configuration: configuration, maximumBytes: 32
            ).body
        }
        try await waitUntil { await gate.isWaiting }
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(PrecancelledRequestURLProtocol.requestCount == 0)
    }

    @Test
    func taskDescriptionRoundTripsWithoutMediaURLOrHeaders() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let destination = fixture.roots.temporaryDirectory
            .appending(path: "Illucet-job/137.webm")
        let identity = try fixture.roots.identity(for: destination)
        let descriptor = try StreamTransferDescriptor(
            sessionIdentifier: fixture.sessionIdentifier,
            taskIdentifier: 42,
            jobID: fixture.jobID,
            streamID: "137",
            destination: identity
        )

        let encoded = try descriptor.encodedTaskDescription()
        let decoded = try StreamTransferDescriptor.decodeTaskDescription(
            encoded,
            expectedSessionIdentifier: fixture.sessionIdentifier,
            expectedTaskIdentifier: 42
        )

        #expect(decoded == descriptor)
        #expect(
            try decoded.destinationURL(in: fixture.roots)
                == destination.standardizedFileURL
        )
        #expect(!encoded.localizedCaseInsensitiveContains("https"))
        #expect(!encoded.localizedCaseInsensitiveContains("signature"))
        #expect(!encoded.localizedCaseInsensitiveContains("cookie"))
        #expect(!encoded.localizedCaseInsensitiveContains("authorization"))
    }

    @Test
    func HLSActiveTaskDescriptionRoundTripsWithoutTransportSecrets()
        throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let descriptor = try HLSPlanFixture.activeDescriptor(
            fixture: fixture,
            taskIdentifier: 42,
            resourcePosition: 7,
            resourceKind: .media
        )

        let encoded = try descriptor.encodedTaskDescription()
        let decoded = try HLSResourceTransferDescriptor
            .decodeTaskDescription(
                encoded,
                expectedSessionIdentifier: fixture.sessionIdentifier,
                expectedTaskIdentifier: 42
            )

        #expect(decoded == descriptor)
        let restoredStaging = try decoded.stagingDirectoryURL(
            in: fixture.roots
        )
        let expectedStaging = HLSPlanFixture.stagingDirectory(
            fixture: fixture,
            descriptor: descriptor
        )
        #expect(restoredStaging.path == expectedStaging.path)
        #expect(!encoded.localizedCaseInsensitiveContains("https"))
        #expect(!encoded.localizedCaseInsensitiveContains("signature"))
        #expect(!encoded.localizedCaseInsensitiveContains("header"))
        #expect(!encoded.localizedCaseInsensitiveContains("cookie"))
        #expect(!encoded.localizedCaseInsensitiveContains("authorization"))
        #expect(!encoded.localizedCaseInsensitiveContains("playlist"))
        #expect(!encoded.localizedCaseInsensitiveContains("token"))
        #expect(!encoded.localizedCaseInsensitiveContains("bearer"))
        #expect(!encoded.localizedCaseInsensitiveContains("key.bin"))
        #expect(!encoded.contains("000102030405060708090a0b0c0d0e0f"))
        #expect(!encoded.contains("202122232425262728292a2b2c2d2e2f"))

    }

    @Test
    func HLSActiveTaskDescriptionRejectsMalformedAndForgedIdentity()
        throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let descriptor = try HLSPlanFixture.activeDescriptor(
            fixture: fixture,
            taskIdentifier: 42
        )
        let encoded = try descriptor.encodedTaskDescription()

        #expect(throws: HLSResourceTransferDescriptorError.taskMismatch) {
            _ = try HLSResourceTransferDescriptor.decodeTaskDescription(
                encoded,
                expectedSessionIdentifier: fixture.sessionIdentifier,
                expectedTaskIdentifier: 43
            )
        }

        var object = try #require(
            JSONSerialization.jsonObject(with: Data(encoded.utf8))
                as? [String: Any]
        )
        object["schemaVersion"] = 2
        let unsupported = String(
            decoding: try JSONSerialization.data(withJSONObject: object),
            as: UTF8.self
        )
        #expect(
            throws: HLSResourceTransferDescriptorError.unsupportedSchema
        ) {
            _ = try HLSResourceTransferDescriptor.decodeTaskDescription(
                unsupported,
                expectedSessionIdentifier: fixture.sessionIdentifier,
                expectedTaskIdentifier: 42
            )
        }

        object["schemaVersion"] = 1
        var staging = try #require(
            object["stagingDirectory"] as? [String: Any]
        )
        staging["relativePath"] = "HLS-Staging/unrelated-task"
        object["stagingDirectory"] = staging
        let forged = String(
            decoding: try JSONSerialization.data(withJSONObject: object),
            as: UTF8.self
        )
        #expect(throws: HLSResourceTransferDescriptorError.invalidIdentity) {
            _ = try HLSResourceTransferDescriptor.decodeTaskDescription(
                forged,
                expectedSessionIdentifier: fixture.sessionIdentifier,
                expectedTaskIdentifier: 42
            )
        }

        object = try #require(
            JSONSerialization.jsonObject(with: Data(encoded.utf8))
                as? [String: Any]
        )
        object["url"] = "https://media.googlevideo.com/segment?sig=secret"
        let injectedSecret = String(
            decoding: try JSONSerialization.data(withJSONObject: object),
            as: UTF8.self
        )
        #expect(
            throws: HLSResourceTransferDescriptorError.invalidDescription
        ) {
            _ = try HLSResourceTransferDescriptor.decodeTaskDescription(
                injectedSecret,
                expectedSessionIdentifier: fixture.sessionIdentifier,
                expectedTaskIdentifier: 42
            )
        }

        object = try #require(
            JSONSerialization.jsonObject(with: Data(encoded.utf8))
                as? [String: Any]
        )
        var inFlight = try #require(
            object["inFlightDestination"] as? [String: Any]
        )
        inFlight["headers"] = ["Cookie": "secret"]
        object["inFlightDestination"] = inFlight
        let nestedSecret = String(
            decoding: try JSONSerialization.data(withJSONObject: object),
            as: UTF8.self
        )
        #expect(
            throws: HLSResourceTransferDescriptorError.invalidDescription
        ) {
            _ = try HLSResourceTransferDescriptor.decodeTaskDescription(
                nestedSecret,
                expectedSessionIdentifier: fixture.sessionIdentifier,
                expectedTaskIdentifier: 42
            )
        }
    }

    @Test
    func HLSAndStreamTaskDescriptionsRemainUnambiguouslyDistinct()
        throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let externalSession = URLSession(configuration: .ephemeral)
        defer { externalSession.invalidateAndCancel() }
        let directTask = externalSession.downloadTask(
            with: URL(string: "https://illucet.test/direct")!
        )
        let HLSTask = externalSession.downloadTask(
            with: URL(
                string: "https://media.googlevideo.com/hls/resource"
            )!
        )
        let directDescriptor = try StreamTransferDescriptor(
            sessionIdentifier: fixture.sessionIdentifier,
            taskIdentifier: directTask.taskIdentifier,
            jobID: fixture.jobID,
            streamID: "137",
            destination: fixture.roots.identity(
                for: fixture.roots.temporaryDirectory.appending(
                    path: "Direct/137.mp4"
                )
            )
        )
        let HLSDescriptor = try HLSPlanFixture.activeDescriptor(
            fixture: fixture,
            taskIdentifier: HLSTask.taskIdentifier
        )
        directTask.taskDescription = try directDescriptor
            .encodedTaskDescription()
        HLSTask.taskDescription = try HLSDescriptor
            .encodedTaskDescription()
        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: .ephemeral,
            destinationRoots: fixture.roots
        )

        #expect(
            service.backgroundTransferIdentity(for: directTask)
                == .stream(directDescriptor)
        )
        #expect(
            service.backgroundTransferIdentity(for: HLSTask)
                == .hlsResource(HLSDescriptor)
        )

        var directObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(
                    try directDescriptor.encodedTaskDescription().utf8
                )
            ) as? [String: Any]
        )
        let HLSObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(
                    try HLSDescriptor.encodedTaskDescription().utf8
                )
            ) as? [String: Any]
        )
        directObject.merge(HLSObject) { _, HLSValue in HLSValue }
        HLSTask.taskDescription = String(
            decoding: try JSONSerialization.data(
                withJSONObject: directObject
            ),
            as: UTF8.self
        )
        #expect(
            service.backgroundTransferIdentity(for: HLSTask)
                == .invalidHLSResource
        )

        HLSTask.taskDescription = HLSResourceTransferDescriptor
            .legacyUndurableTaskDescription
        #expect(
            service.backgroundTransferIdentity(for: HLSTask)
                == .invalidHLSResource
        )
    }

    @Test
    func reconstructedHLSOperationWaitsForTerminalThenCleansWithoutResume()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let externalSession = URLSession(configuration: .ephemeral)
        defer { externalSession.invalidateAndCancel() }
        let task = externalSession.downloadTask(
            with: URL(
                string: "https://media.googlevideo.com/hls/lost-resource"
            )!
        )
        let descriptor = try HLSPlanFixture.activeDescriptor(
            fixture: fixture,
            taskIdentifier: task.taskIdentifier
        )
        task.taskDescription = try descriptor.encodedTaskDescription()
        let stagingDirectory = HLSPlanFixture.stagingDirectory(
            fixture: fixture,
            descriptor: descriptor
        )
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        try Data("completed-but-not-reusable".utf8).write(
            to: stagingDirectory.appending(path: "resource-000000-init.part")
        )
        try Data("inflight".utf8).write(
            to: try descriptor.inFlightURL(in: fixture.roots)
        )
        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: .ephemeral,
            destinationRoots: fixture.roots
        )
        let completion = CompletionFlag()
        let reconciliation = Task {
            let registrations = await service.reconcileBackgroundTasks([task])
            completion.markComplete()
            return registrations
        }
        try await waitUntil {
            task.state == .canceling || task.state == .completed
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(!completion.isComplete)
        #expect(FileManager.default.fileExists(atPath: stagingDirectory.path))

        service.urlSession(
            externalSession,
            task: task,
            didCompleteWithError: URLError(.cancelled)
        )
        let registrations = await reconciliation.value

        #expect(registrations.isEmpty)
        #expect(completion.isComplete)
        #expect(!FileManager.default.fileExists(atPath: stagingDirectory.path))
        #expect(await service.reconcileBackgroundTasks().isEmpty)
    }

    @Test(arguments: [false, true])
    func reconciliationRemovesOnlyAbandonedOwnedHLSDirectories(assembly: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fm = FileManager.default
        let root = assembly
            ? fixture.roots.temporaryDirectory.appending(path: "HLS-Assembly")
            : fixture.roots.applicationSupportDirectory.appending(path: "HLS-Staging")
        func ownedDirectory() -> URL {
            root.appending(path: assembly
                ? "assembly-\(UUID().uuidString.lowercased())"
                : "task-\(UUID().uuidString.lowercased())-\(UUID().uuidString.lowercased())")
        }
        let abandoned = ownedDirectory()
        let unrelated = root.appending(path: "unrelated-folder")
        let external = fixture.root.appending(path: "External")
        for URL in [abandoned, unrelated, external] {
            try fm.createDirectory(at: URL, withIntermediateDirectories: true)
            try Data("retained-bytes".utf8).write(to: URL.appending(path: "resource.part"))
        }
        let link = ownedDirectory()
        try fm.createSymbolicLink(at: link, withDestinationURL: external)
        let service = StreamDownloadService(
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: .ephemeral,
            destinationRoots: fixture.roots
        )
        // A current operation between URLSession tasks (or already assembling)
        // has no task descriptor. It must survive every reconciliation.
        let current = ownedDirectory()
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        #expect(await service.reconcileBackgroundTasks([]).isEmpty)
        #expect(!fm.fileExists(atPath: abandoned.path))
        #expect(fm.fileExists(atPath: current.path))
        #expect(fm.fileExists(atPath: unrelated.path))
        #expect(fm.fileExists(atPath: external.appending(path: "resource.part").path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(await service.reconcileBackgroundTasks([]).isEmpty)
        #expect(fm.fileExists(atPath: current.path))
    }

    @Test
    func reconciliationDoesNotDeleteReplacedHLSDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fm = FileManager.default
        let directory = fixture.roots.applicationSupportDirectory.appending(
            path: "HLS-Staging/task-\(UUID().uuidString.lowercased())-\(UUID().uuidString.lowercased())"
        )
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = StreamDownloadService(
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: .ephemeral,
            destinationRoots: fixture.roots
        )
        try fm.moveItem(at: directory, to: fixture.root.appending(path: "Original"))
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(await service.reconcileBackgroundTasks([]).isEmpty)
        #expect(fm.fileExists(atPath: directory.path))
    }

    @Test
    func servicePreservesSuppliedDirectSessionConfiguration() {
        let fixture = try? Fixture()
        guard let fixture else {
            Issue.record("Could not create the background test fixture.")
            return
        }
        defer { fixture.cleanup() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = .shared
        configuration.urlCredentialStorage = .shared
        configuration.urlCache = .shared

        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: configuration,
            destinationRoots: fixture.roots
        )

        #expect(configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .always)
        #expect(configuration.httpCookieStorage === HTTPCookieStorage.shared)
        #expect(
            configuration.urlCredentialStorage === URLCredentialStorage.shared
        )
        #expect(configuration.urlCache === URLCache.shared)
        withExtendedLifetime(service) {}
    }

    @Test
    func schemaOneTaskDescriptionRemainsRestorable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let destination = fixture.roots.temporaryDirectory
            .appending(path: "Illucet-job/137.webm")
        let descriptor = try StreamTransferDescriptor(
            sessionIdentifier: fixture.sessionIdentifier,
            taskIdentifier: 42,
            jobID: fixture.jobID,
            streamID: "137",
            destination: fixture.roots.identity(for: destination)
        )
        let encoded = try #require(
            descriptor.encodedTaskDescription().data(using: .utf8)
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object["schemaVersion"] = 1
        let legacy = String(
            decoding: try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ),
            as: UTF8.self
        )

        let decoded = try StreamTransferDescriptor.decodeTaskDescription(
            legacy,
            expectedSessionIdentifier: fixture.sessionIdentifier,
            expectedTaskIdentifier: 42
        )

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.destination == descriptor.destination)
        #expect(decoded.byteRange == nil)
        #expect(decoded.rangeChunkBytes == nil)
    }

    @Test
    func taskDescriptionRejectsSessionTaskAndPathTraversal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let identity = StreamTransferDestinationIdentity(
            root: .temporary,
            relativePath: "Illucet-job/137.webm"
        )
        let descriptor = try StreamTransferDescriptor(
            sessionIdentifier: fixture.sessionIdentifier,
            taskIdentifier: 9,
            jobID: fixture.jobID,
            streamID: "137",
            destination: identity
        )
        let encoded = try descriptor.encodedTaskDescription()

        #expect(throws: StreamTransferDescriptorError.sessionMismatch) {
            _ = try StreamTransferDescriptor.decodeTaskDescription(
                encoded,
                expectedSessionIdentifier: "another.session",
                expectedTaskIdentifier: 9
            )
        }
        #expect(throws: StreamTransferDescriptorError.taskMismatch) {
            _ = try StreamTransferDescriptor.decodeTaskDescription(
                encoded,
                expectedSessionIdentifier: fixture.sessionIdentifier,
                expectedTaskIdentifier: 10
            )
        }

        let escaped = encoded.replacingOccurrences(
            of: "Illucet-job/137.webm",
            with: "../escape.webm"
        )
        #expect(throws: StreamTransferDescriptorError.invalidDestination) {
            _ = try StreamTransferDescriptor.decodeTaskDescription(
                escaped,
                expectedSessionIdentifier: fixture.sessionIdentifier,
                expectedTaskIdentifier: 9
            )
        }
    }

    @Test
    func destinationIdentityAcceptsCanonicalAliasIntoAllowedRoot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let alias = fixture.root.appending(
            path: "TemporaryAlias",
            directoryHint: .isDirectory
        )
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: fixture.roots.temporaryDirectory
        )
        let destination = alias.appending(path: "Illucet-job/137.webm")

        let identity = try fixture.roots.identity(for: destination)

        #expect(identity.root == .temporary)
        #expect(identity.relativePath == "Illucet-job/137.webm")
        #expect(
            try fixture.roots.URL(for: identity)
                == fixture.roots.temporaryDirectory
                    .appending(path: identity.relativePath)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
        )
    }

    @Test
    func destinationIdentityAndReconstructionRejectSymlinkEscape() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let outside = fixture.root.appending(
            path: "Outside",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let escape = fixture.roots.temporaryDirectory.appending(
            path: "Escape",
            directoryHint: .isDirectory
        )
        try FileManager.default.createSymbolicLink(
            at: escape,
            withDestinationURL: outside
        )
        let destination = escape.appending(path: "137.webm")

        #expect(
            throws:
                StreamTransferDescriptorError
                    .destinationOutsideAllowedRoots
        ) {
            _ = try fixture.roots.identity(for: destination)
        }
        #expect(throws: StreamTransferDescriptorError.invalidDestination) {
            _ = try fixture.roots.URL(
                for: StreamTransferDestinationIdentity(
                    root: .temporary,
                    relativePath: "Escape/137.webm"
                )
            )
        }
    }

    @Test
    func destinationIdentityRejectsUnrelatedSiblingRoot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sibling = fixture.root.appending(
            path: "Temporary-Sibling/137.webm"
        )

        #expect(
            throws:
                StreamTransferDescriptorError
                    .destinationOutsideAllowedRoots
        ) {
            _ = try fixture.roots.identity(for: sibling)
        }
    }

    @Test
    func concurrentCallersAttachToOneRegisteredTask() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        DelayedDownloadURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedDownloadURLProtocol.self]
        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: configuration,
            destinationRoots: fixture.roots
        )
        let destination = fixture.roots.temporaryDirectory
            .appending(path: "Illucet-job/137.webm")
        let stream = ResolvedStream(
            formatID: "137",
            URL: URL(string: "https://illucet.test/media")!,
            HTTPHeaders: ["User-Agent": "Illucet-Test"],
            fileExtension: "webm",
            protocolName: "https",
            sourceType: "direct_http",
            hasVideo: true,
            hasAudio: false,
            expectedBytes: 5,
            httpChunkSize: 10 * 1_024 * 1_024
        )

        let first = Task {
            try await service.download(
                stream,
                jobID: fixture.jobID,
                destinationURL: destination
            ) { _ in }
        }
        try await waitUntil {
            await service.reconcileBackgroundTasks().count == 1
        }
        let second = Task {
            let result = try await service.download(
                stream,
                jobID: fixture.jobID,
                destinationURL: destination,
                verifiedExpectedBytes: 5
            ) { _ in }
            return result.fileURL
        }

        let firstURL = try await first.value
        let secondURL = try await second.value
        #expect(firstURL == destination)
        #expect(secondURL == destination)
        #expect(try Data(contentsOf: destination) == Data("media".utf8))
        #expect(DelayedDownloadURLProtocol.requestCount == 1)
        #expect(DelayedDownloadURLProtocol.lastHTTPMethod == "GET")
        #expect(DelayedDownloadURLProtocol.lastRangeHeader == nil)
    }

    @Test
    func cancellingAttachedWaiterLeavesSharedTaskRunning() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        DelayedDownloadURLProtocol.reset()
        DelayedDownloadURLProtocol.holdResponses()
        defer { DelayedDownloadURLProtocol.releaseResponses() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedDownloadURLProtocol.self]
        let gate = WaiterRegistrationGate()
        defer { gate.releaseSecondInvocation() }
        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: configuration,
            destinationRoots: fixture.roots,
            hooks: StreamDownloadServiceHooks { _, _ in
                gate.pauseSecondInvocation()
            }
        )
        let destination = fixture.roots.temporaryDirectory
            .appending(path: "Illucet-waiter/137.webm")
        let stream = ResolvedStream(
            formatID: "137",
            URL: URL(string: "https://illucet.test/waiter")!,
            HTTPHeaders: [:],
            fileExtension: "webm",
            protocolName: "https",
            sourceType: "direct_http",
            hasVideo: true,
            hasAudio: false,
            expectedBytes: 5
        )

        let survivingWaiter = Task {
            try await service.download(
                stream,
                jobID: fixture.jobID,
                destinationURL: destination
            ) { _ in }
        }
        try await waitUntil {
            await service.reconcileBackgroundTasks().count == 1
        }
        let cancelledWaiter = Task {
            try await service.download(
                stream,
                jobID: fixture.jobID,
                destinationURL: destination
            ) { _ in }
        }
        try await waitUntil {
            gate.secondInvocationReached
        }

        cancelledWaiter.cancel()
        gate.releaseSecondInvocation()

        await #expect(throws: CancellationError.self) {
            _ = try await cancelledWaiter.value
        }
        DelayedDownloadURLProtocol.releaseResponses()
        let result = try await survivingWaiter.value
        #expect(result == destination)
        #expect(try Data(contentsOf: destination) == Data("media".utf8))
        #expect(DelayedDownloadURLProtocol.requestCount == 1)
        #expect(DelayedDownloadURLProtocol.lastHTTPMethod == "GET")
        #expect(DelayedDownloadURLProtocol.lastRangeHeader == nil)
    }

    @Test
    func orphanCompletionMovesFileUsingOnlyTaskDescription() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fileManager = ProtectionRecordingFileManager()
        let configuration = URLSessionConfiguration.ephemeral
        let service = StreamDownloadService(
            fileManager: fileManager,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: configuration,
            destinationRoots: fixture.roots
        )
        let externalSession = URLSession(configuration: .ephemeral)
        defer { externalSession.invalidateAndCancel() }
        let task = externalSession.downloadTask(
            with: URL(string: "https://illucet.test/orphan")!
        )
        let destination = fixture.roots.applicationSupportDirectory
            .appending(path: "job/140.m4a")
        let identity = try fixture.roots.identity(for: destination)
        let descriptor = try StreamTransferDescriptor(
            sessionIdentifier: fixture.sessionIdentifier,
            taskIdentifier: task.taskIdentifier,
            jobID: fixture.jobID,
            streamID: "140",
            destination: identity
        )
        task.taskDescription = try descriptor.encodedTaskDescription()
        let source = fixture.root.appending(path: "system-download.tmp")
        try Data("orphan".utf8).write(to: source)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: source.path)

        let result = service.commitDownloadedFile(
            taskDescription: task.taskDescription,
            taskIdentifier: task.taskIdentifier,
            HTTPStatusCode: 200,
            location: source
        )

        #expect(result == .success(destination))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: destination) == Data("orphan".utf8))
        #expect(fileManager.appliedProtection(to: destination) == .completeUntilFirstUserAuthentication)
        try verifyProtectionWhenAvailable(destination, expected: .completeUntilFirstUserAuthentication)
    }

    @Test
    func HTTPStatusIsValidatedBeforePublishing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: .ephemeral,
            destinationRoots: fixture.roots
        )
        let destination = fixture.roots.applicationSupportDirectory
            .appending(path: "job/140.m4a")
        let identity = try fixture.roots.identity(for: destination)

        for (index, expectation) in [
            (
                401,
                StreamDownloadError.unauthorizedHTTPFailure(statusCode: 401)
            ),
            (
                403,
                StreamDownloadError.forbiddenHTTPFailure(statusCode: 403)
            ),
            (
                410,
                StreamDownloadError.goneHTTPFailure(statusCode: 410)
            ),
            (
                429,
                StreamDownloadError.transientHTTPFailure(statusCode: 429)
            ),
            (
                503,
                StreamDownloadError.transientHTTPFailure(statusCode: 503)
            ),
            (
                404,
                StreamDownloadError.permanentHTTPFailure(statusCode: 404)
            ),
        ].enumerated() {
            let descriptor = try StreamTransferDescriptor(
                sessionIdentifier: fixture.sessionIdentifier,
                taskIdentifier: index + 1,
                jobID: fixture.jobID,
                streamID: "140",
                destination: identity
            )
            let source = fixture.root.appending(
                path: "HTTP-\(expectation.0).tmp"
            )
            try Data("error body".utf8).write(to: source)

            let result = service.commitDownloadedFile(
                descriptor: descriptor,
                HTTPStatusCode: expectation.0,
                location: source
            )

            #expect(result == .failure(expectation.1))
            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(
                !FileManager.default.fileExists(atPath: destination.path)
            )
        }

        let missingStatusDescriptor = try StreamTransferDescriptor(
            sessionIdentifier: fixture.sessionIdentifier,
            taskIdentifier: 99,
            jobID: fixture.jobID,
            streamID: "140",
            destination: identity
        )
        let missingStatusSource = fixture.root.appending(
            path: "HTTP-missing.tmp"
        )
        try Data("unvalidated body".utf8).write(
            to: missingStatusSource
        )
        let missingStatusResult = service.commitDownloadedFile(
            descriptor: missingStatusDescriptor,
            HTTPStatusCode: nil,
            location: missingStatusSource
        )
        #expect(
            missingStatusResult == .failure(
                .permanentHTTPFailure(statusCode: 0)
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: missingStatusSource.path
            )
        )
    }

    @Test
    func HTTPFailuresHaveCorrectRetryClassification() {
        let policy = DownloadRetryPolicy()
        let unauthorized = StreamDownloadError.unauthorizedHTTPFailure(
            statusCode: 401
        )
        let forbidden = StreamDownloadError.forbiddenHTTPFailure(
            statusCode: 403
        )
        let gone = StreamDownloadError.goneHTTPFailure(statusCode: 410)

        #expect(
            policy.classify(unauthorized) == .permanent
        )
        #expect(
            policy.classify(forbidden) == .retryable(
                reason: .mediaAccessForbidden,
                reResolveStreams: true
            )
        )
        #expect(
            policy.classify(gone) == .retryable(
                reason: .mediaURLGone,
                reResolveStreams: true
            )
        )
        #expect(unauthorized.diagnosticCode == "http_401_unauthorized")
        #expect(forbidden.diagnosticCode == "http_403_forbidden")
        #expect(gone.diagnosticCode == "http_410_gone")
        #expect(
            policy.classify(
                StreamDownloadError.transientHTTPFailure(statusCode: 503)
            ) == .retryable(
                reason: .serverFailure,
                reResolveStreams: true
            )
        )
        #expect(
            policy.classify(
                StreamDownloadError.permanentHTTPFailure(statusCode: 404)
            ) == .permanent
        )
        #expect(
            policy.classify(
                StreamDownloadError.invalidPartialContent
            ) == .permanent
        )
        #expect(
            policy.classify(
                StreamDownloadError.rangeAssemblyFailure
            ) == .permanent
        )
    }

    @Test
    func terminalTombstoneClosesRestoredTaskAttachmentRace()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        DelayedDownloadURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedDownloadURLProtocol.self]
        let destination = fixture.roots.temporaryDirectory
            .appending(path: "Illucet-race/137.webm")
        let source = fixture.root.appending(path: "race-system.tmp")
        try Data("media".utf8).write(to: source)
        let box = StreamDownloadServiceBox()
        let hooks = StreamDownloadServiceHooks {
            task,
            descriptor in
            guard let service = box.service else { return }
            _ = service.commitDownloadedFile(
                descriptor: descriptor,
                HTTPStatusCode: 200,
                location: source
            )
            service.urlSession(
                URLSession.shared,
                task: task,
                didCompleteWithError: nil
            )
        }
        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: configuration,
            destinationRoots: fixture.roots,
            hooks: hooks
        )
        box.service = service
        let stream = ResolvedStream(
            formatID: "137",
            URL: URL(string: "https://illucet.test/race")!,
            HTTPHeaders: [:],
            fileExtension: "webm",
            protocolName: "https",
            sourceType: "direct_http",
            hasVideo: true,
            hasAudio: false,
            expectedBytes: 5
        )

        let result = try await service.download(
            stream,
            jobID: fixture.jobID,
            destinationURL: destination
        ) { _ in }

        #expect(result == destination)
        #expect(try Data(contentsOf: destination) == Data("media".utf8))
        #expect(DelayedDownloadURLProtocol.requestCount == 0)
    }

    @Test
    func transferRequestCarriesExpensiveAndConstrainedPolicy()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        DelayedDownloadURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedDownloadURLProtocol.self]
        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: configuration,
            destinationRoots: fixture.roots
        )
        await service.setNetworkPolicy(
            StreamTransferNetworkPolicy(
                allowsExpensiveAccess: false,
                allowsConstrainedAccess: false
            ),
            jobID: fixture.jobID
        )
        let destination = fixture.roots.temporaryDirectory
            .appending(path: "Illucet-policy/137.webm")
        let stream = ResolvedStream(
            formatID: "137",
            URL: URL(string: "https://illucet.test/policy")!,
            HTTPHeaders: [:],
            fileExtension: "webm",
            protocolName: "https",
            sourceType: "direct_http",
            hasVideo: true,
            hasAudio: false,
            expectedBytes: 5
        )

        _ = try await service.download(
            stream,
            jobID: fixture.jobID,
            destinationURL: destination
        ) { _ in }

        #expect(
            DelayedDownloadURLProtocol.lastRequestPolicy
                == StreamTransferNetworkPolicy(
                    allowsExpensiveAccess: false,
                    allowsConstrainedAccess: false
                )
        )
    }

    @Test
    func taskControlsReportAcknowledgedCounts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        DelayedDownloadURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedDownloadURLProtocol.self]
        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: configuration,
            destinationRoots: fixture.roots
        )
        let destination = fixture.roots.temporaryDirectory
            .appending(path: "Illucet-controls/137.webm")
        let stream = ResolvedStream(
            formatID: "137",
            URL: URL(string: "https://illucet.test/controls")!,
            HTTPHeaders: [:],
            fileExtension: "webm",
            protocolName: "https",
            sourceType: "direct_http",
            hasVideo: true,
            hasAudio: false,
            expectedBytes: 5
        )
        let transfer = Task {
            try await service.download(
                stream,
                jobID: fixture.jobID,
                destinationURL: destination
            ) { _ in }
        }
        try await waitUntil {
            await service.reconcileBackgroundTasks().count == 1
        }

        let pause = await service.pause(jobID: fixture.jobID)
        #expect(pause.action == .pause)
        #expect(pause.matchedTaskCount == 1)
        #expect(pause.affectedTaskCount == 1)
        #expect(pause.fullyAcknowledged)

        let resume = await service.resume(jobID: fixture.jobID)
        #expect(resume.action == .resume)
        #expect(resume.matchedTaskCount == 1)
        #expect(resume.affectedTaskCount == 1)
        #expect(resume.fullyAcknowledged)

        let cancel = await service.cancel(jobID: fixture.jobID)
        #expect(cancel.action == .cancel)
        #expect(cancel.matchedTaskCount == 1)
        #expect(cancel.affectedTaskCount == 1)
        #expect(cancel.fullyAcknowledged)
        await #expect(throws: StreamDownloadError.cancelled) {
            _ = try await transfer.value
        }
    }

    @Test
    func DASHFragmentRetryPolicyIsBoundedAndRejectsReResolutionFailures() {
        let policy = DASHFragmentRetryPolicy(
            maximumRetries: 99,
            initialDelaySeconds: 1,
            multiplier: 2,
            maximumDelaySeconds: 3
        )

        #expect(
            policy.maximumRetries
                == DASHFragmentRetryPolicy.absoluteMaximumRetries
        )
        #expect(
            (1 ... 5).map(policy.delay(forRetryNumber:))
                == [1, 2, 3, 3, 3]
        )
        #expect(
            policy.permitsRetry(
                of: StreamDownloadError.transientHTTPFailure(statusCode: 503)
            )
        )
        #expect(
            policy.permitsRetry(
                of: DASHFragmentDownloadError.fragmentByteCountMismatch(
                    position: 0,
                    expected: 4,
                    actual: 3
                )
            )
        )
        #expect(
            !policy.permitsRetry(
                of: StreamDownloadError.forbiddenHTTPFailure(statusCode: 403)
            )
        )
        #expect(
            !policy.permitsRetry(
                of: StreamDownloadError.goneHTTPFailure(statusCode: 410)
            )
        )
        #expect(!policy.permitsRetry(of: CancellationError()))
    }

    @Test
    func DASHFragmentsStageSequentiallyInExactOrderWithoutAssembly()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        OrderedFragmentURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OrderedFragmentURLProtocol.self]
        let descriptorRecorder = TransferDescriptorRecorder()
        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: configuration,
            destinationRoots: fixture.roots,
            hooks: StreamDownloadServiceHooks { _, descriptor in
                descriptorRecorder.record(descriptor)
            }
        )
        let stagingDirectory = fixture.roots.applicationSupportDirectory
            .appending(
                path: "DASH-Staging",
                directoryHint: .isDirectory
            )
        let plan = DASHPlanFixture.plan()

        let result = try await service.downloadDASHFragments(
            plan,
            jobID: fixture.jobID,
            stagingDirectoryURL: stagingDirectory
        ) { _ in }

        #expect(result.videoID == plan.videoID)
        #expect(result.formatID == plan.formatID)
        #expect(result.fragments.map(\.position) == [0, 1, 2])
        #expect(
            OrderedFragmentURLProtocol.requestedURLs
                == plan.fragments.map(\.URL.absoluteString)
        )
        #expect(OrderedFragmentURLProtocol.maximumActiveRequestCount == 1)
        #expect(
            OrderedFragmentURLProtocol.userAgents
                == Array(repeating: "Illucet-DASH-Test", count: 3)
        )
        #expect(
            try result.fragments.map { fragment in
                String(decoding: try Data(contentsOf: fragment.fileURL), as: UTF8.self)
            } == ["init", "media-1", "init"]
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: stagingDirectory.path
            ).sorted() == [
                "fragment-000000.part",
                "fragment-000001.part",
                "fragment-000002.part",
            ]
        )
        let descriptions = descriptorRecorder.encodedDescriptions
        #expect(descriptions.count == 3)
        for description in descriptions {
            #expect(!description.localizedCaseInsensitiveContains("https"))
            #expect(!description.localizedCaseInsensitiveContains("sig="))
            #expect(!description.localizedCaseInsensitiveContains("user-agent"))
            #expect(!description.localizedCaseInsensitiveContains("cookie"))
            #expect(!description.localizedCaseInsensitiveContains("authorization"))
        }
    }

    @Test
    func DASHFragmentTransientFailureRetriesOnlyCurrentFragmentThenContinues()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        OrderedFragmentURLProtocol.reset(
            scriptedResponses: [
                "/media-1": [
                    OrderedFragmentResponse(statusCode: 503, body: "failure"),
                    OrderedFragmentResponse(statusCode: 200, body: "media-1"),
                ]
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OrderedFragmentURLProtocol.self]
        let sleeper = DASHRetrySleeperRecorder()
        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: configuration,
            destinationRoots: fixture.roots,
            dashFragmentRetryPolicy: DASHFragmentRetryPolicy(
                maximumRetries: 2,
                initialDelaySeconds: 0.25
            ),
            dashFragmentRetrySleeper: sleeper.sleep
        )
        let stagingDirectory = fixture.roots.applicationSupportDirectory
            .appending(
                path: "DASH-Failure",
                directoryHint: .isDirectory
            )
        let plan = DASHPlanFixture.plan()

        let result = try await service.downloadDASHFragments(
            plan,
            jobID: fixture.jobID,
            stagingDirectoryURL: stagingDirectory
        ) { _ in }

        #expect(
            OrderedFragmentURLProtocol.requestedURLs == [
                plan.fragments[0].URL.absoluteString,
                plan.fragments[1].URL.absoluteString,
                plan.fragments[1].URL.absoluteString,
                plan.fragments[2].URL.absoluteString,
            ]
        )
        #expect(OrderedFragmentURLProtocol.maximumActiveRequestCount == 1)
        #expect(OrderedFragmentURLProtocol.currentActiveRequestCount == 0)
        #expect(sleeper.delays == [0.25])
        #expect(result.fragments.map(\.position) == [0, 1, 2])
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: stagingDirectory.path
            ).sorted() == [
                "fragment-000000.part",
                "fragment-000001.part",
                "fragment-000002.part",
            ]
        )
    }

    @Test
    func DASHFragmentRetryExhaustionStopsBeforeLaterFragments() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        OrderedFragmentURLProtocol.reset(
            scriptedResponses: [
                "/media-1": [
                    OrderedFragmentResponse(statusCode: 503, body: "failure")
                ]
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OrderedFragmentURLProtocol.self]
        let sleeper = DASHRetrySleeperRecorder()
        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: configuration,
            destinationRoots: fixture.roots,
            dashFragmentRetryPolicy: DASHFragmentRetryPolicy(
                maximumRetries: 2,
                initialDelaySeconds: 1,
                multiplier: 2,
                maximumDelaySeconds: 8
            ),
            dashFragmentRetrySleeper: sleeper.sleep
        )
        let stagingDirectory = fixture.roots.applicationSupportDirectory
            .appending(path: "DASH-Exhausted", directoryHint: .isDirectory)
        let plan = DASHPlanFixture.plan()

        await #expect(
            throws: StreamDownloadError.transientHTTPFailure(
                statusCode: 503
            )
        ) {
            _ = try await service.downloadDASHFragments(
                plan,
                jobID: fixture.jobID,
                stagingDirectoryURL: stagingDirectory
            ) { _ in }
        }

        #expect(
            OrderedFragmentURLProtocol.requestedURLs == [
                plan.fragments[0].URL.absoluteString,
                plan.fragments[1].URL.absoluteString,
                plan.fragments[1].URL.absoluteString,
                plan.fragments[1].URL.absoluteString,
            ]
        )
        #expect(sleeper.delays == [1, 2])
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: stagingDirectory.path
            ) == ["fragment-000000.part"]
        )
    }

    @Test
    func DASHFragmentForbiddenAndGoneFailuresDoNotRetry() async throws {
        for statusCode in [403, 410] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            OrderedFragmentURLProtocol.reset(
                scriptedResponses: [
                    "/media-1": [
                        OrderedFragmentResponse(
                            statusCode: statusCode,
                            body: "expired"
                        )
                    ]
                ]
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OrderedFragmentURLProtocol.self]
            let sleeper = DASHRetrySleeperRecorder()
            let service = StreamDownloadService(
                fileManager: .default,
                sessionIdentifier: fixture.sessionIdentifier,
                configuration: configuration,
                destinationRoots: fixture.roots,
                dashFragmentRetryPolicy: DASHFragmentRetryPolicy(
                    maximumRetries: 5
                ),
                dashFragmentRetrySleeper: sleeper.sleep
            )
            let plan = DASHPlanFixture.plan()

            do {
                _ = try await service.downloadDASHFragments(
                    plan,
                    jobID: fixture.jobID,
                    stagingDirectoryURL: fixture.roots.applicationSupportDirectory
                        .appending(path: "DASH-\(statusCode)")
                ) { _ in }
                Issue.record("Expected HTTP \(statusCode) to fail.")
            } catch let error as StreamDownloadError {
                if statusCode == 403 {
                    #expect(
                        error == .forbiddenHTTPFailure(statusCode: 403)
                    )
                } else {
                    #expect(error == .goneHTTPFailure(statusCode: 410))
                }
            }
            #expect(
                OrderedFragmentURLProtocol.requestedURLs == [
                    plan.fragments[0].URL.absoluteString,
                    plan.fragments[1].URL.absoluteString,
                ]
            )
            #expect(sleeper.delays.isEmpty)
        }
    }

    @Test
    func DASHFragmentByteMismatchIsDeletedAndRetried() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        OrderedFragmentURLProtocol.reset(
            scriptedResponses: [
                "/media-1": [
                    OrderedFragmentResponse(statusCode: 200, body: "bad"),
                    OrderedFragmentResponse(statusCode: 200, body: "media-1"),
                ]
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OrderedFragmentURLProtocol.self]
        let sleeper = DASHRetrySleeperRecorder()
        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: configuration,
            destinationRoots: fixture.roots,
            dashFragmentRetryPolicy: DASHFragmentRetryPolicy(
                maximumRetries: 1,
                initialDelaySeconds: 0
            ),
            dashFragmentRetrySleeper: sleeper.sleep
        )
        let plan = DASHPlanFixture.plan()

        let result = try await service.downloadDASHFragments(
            plan,
            jobID: fixture.jobID,
            stagingDirectoryURL: fixture.roots.applicationSupportDirectory
                .appending(path: "DASH-Integrity")
        ) { _ in }

        #expect(
            OrderedFragmentURLProtocol.requestedURLs == [
                plan.fragments[0].URL.absoluteString,
                plan.fragments[1].URL.absoluteString,
                plan.fragments[1].URL.absoluteString,
                plan.fragments[2].URL.absoluteString,
            ]
        )
        #expect(sleeper.delays == [0])
        #expect(
            String(
                decoding: try Data(contentsOf: result.fragments[1].fileURL),
                as: UTF8.self
            ) == "media-1"
        )
    }

    @Test
    func DASHFragmentByteMismatchExhaustionRejectsBytesAndStops() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        OrderedFragmentURLProtocol.reset(
            scriptedResponses: [
                "/media-1": [
                    OrderedFragmentResponse(statusCode: 200, body: "bad")
                ]
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OrderedFragmentURLProtocol.self]
        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: configuration,
            destinationRoots: fixture.roots,
            dashFragmentRetryPolicy: DASHFragmentRetryPolicy(
                maximumRetries: 1,
                initialDelaySeconds: 0
            ),
            dashFragmentRetrySleeper: { _ in }
        )
        let stagingDirectory = fixture.roots.applicationSupportDirectory
            .appending(path: "DASH-Integrity-Exhausted")
        let plan = DASHPlanFixture.plan()

        await #expect(
            throws: DASHFragmentDownloadError.fragmentByteCountMismatch(
                position: 1,
                expected: 7,
                actual: 3
            )
        ) {
            _ = try await service.downloadDASHFragments(
                plan,
                jobID: fixture.jobID,
                stagingDirectoryURL: stagingDirectory
            ) { _ in }
        }

        #expect(
            OrderedFragmentURLProtocol.requestedURLs == [
                plan.fragments[0].URL.absoluteString,
                plan.fragments[1].URL.absoluteString,
                plan.fragments[1].URL.absoluteString,
            ]
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: stagingDirectory.path
            ) == ["fragment-000000.part"]
        )
    }

    @Test
    func DASHAggregateByteMismatchDeletesEveryStagedFragment() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        OrderedFragmentURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OrderedFragmentURLProtocol.self]
        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: configuration,
            destinationRoots: fixture.roots
        )
        let stagingDirectory = fixture.roots.applicationSupportDirectory
            .appending(path: "DASH-Aggregate-Mismatch")
        let plan = DASHPlanFixture.plan(expectedBytes: 16)

        await #expect(
            throws: DASHFragmentDownloadError.aggregateByteCountMismatch(
                expected: 16,
                actual: 15
            )
        ) {
            _ = try await service.downloadDASHFragments(
                plan,
                jobID: fixture.jobID,
                stagingDirectoryURL: stagingDirectory
            ) { _ in }
        }

        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: stagingDirectory.path
            ).isEmpty
        )
    }

    @Test
    func DASHFragmentCancellationStopsTransferAndBackoff() async throws {
        do {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            OrderedFragmentURLProtocol.reset(holdResponsesUntilCancelled: true)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OrderedFragmentURLProtocol.self]
            let service = StreamDownloadService(
                fileManager: .default,
                sessionIdentifier: fixture.sessionIdentifier,
                configuration: configuration,
                destinationRoots: fixture.roots
            )
            let plan = DASHPlanFixture.plan()
            let operation = Task {
                try await service.downloadDASHFragments(
                    plan,
                    jobID: fixture.jobID,
                    stagingDirectoryURL: fixture.roots.applicationSupportDirectory
                        .appending(path: "DASH-Cancel-Transfer")
                ) { _ in }
            }
            defer { operation.cancel() }
            try await waitUntil(maximumAttempts: 1_000) {
                OrderedFragmentURLProtocol.requestedURLs.count == 1
            }
            operation.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await operation.value
            }
            #expect(OrderedFragmentURLProtocol.requestedURLs.count == 1)
            _ = await service.cancel(jobID: fixture.jobID)
        }

        do {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            OrderedFragmentURLProtocol.reset(
                scriptedResponses: [
                    "/media-1": [
                        OrderedFragmentResponse(statusCode: 503, body: "failure")
                    ]
                ]
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OrderedFragmentURLProtocol.self]
            let sleeper = DASHRetrySleeperRecorder(blockUntilCancelled: true)
            let service = StreamDownloadService(
                fileManager: .default,
                sessionIdentifier: fixture.sessionIdentifier,
                configuration: configuration,
                destinationRoots: fixture.roots,
                dashFragmentRetryPolicy: DASHFragmentRetryPolicy(
                    maximumRetries: 2
                ),
                dashFragmentRetrySleeper: sleeper.sleep
            )
            let plan = DASHPlanFixture.plan()
            let operation = Task {
                try await service.downloadDASHFragments(
                    plan,
                    jobID: fixture.jobID,
                    stagingDirectoryURL: fixture.roots.applicationSupportDirectory
                        .appending(path: "DASH-Cancel-Backoff")
                ) { _ in }
            }
            defer { operation.cancel() }
            try await waitUntil(maximumAttempts: 1_000) { sleeper.delays.count == 1 }
            operation.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await operation.value
            }
            #expect(
                OrderedFragmentURLProtocol.requestedURLs == [
                    plan.fragments[0].URL.absoluteString,
                    plan.fragments[1].URL.absoluteString,
                ]
            )
        }
    }

    @Test
    func DASHFragmentTransferRejectsForgedOrderAndOutsideStagingBeforeNetwork()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        OrderedFragmentURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OrderedFragmentURLProtocol.self]
        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: configuration,
            destinationRoots: fixture.roots
        )
        let valid = DASHPlanFixture.plan()
        let forged = ResolvedDASHFragmentPlan(
            videoID: valid.videoID,
            formatID: valid.formatID,
            protocolName: valid.protocolName,
            sourceType: valid.sourceType,
            fileExtension: valid.fileExtension,
            hasVideo: valid.hasVideo,
            hasAudio: valid.hasAudio,
            HTTPHeaders: valid.HTTPHeaders,
            fragments: [
                valid.fragments[0],
                ResolvedDASHFragment(
                    position: 9,
                    URL: valid.fragments[1].URL
                ),
            ],
            resolvedAt: .now
        )

        await #expect(throws: DASHFragmentDownloadError.invalidPlan) {
            _ = try await service.downloadDASHFragments(
                forged,
                jobID: fixture.jobID,
                stagingDirectoryURL: fixture.roots.temporaryDirectory
                    .appending(path: "Forged")
            ) { _ in }
        }
        await #expect(
            throws: DASHFragmentDownloadError.invalidStagingDestination
        ) {
            _ = try await service.downloadDASHFragments(
                valid,
                jobID: fixture.jobID,
                stagingDirectoryURL: fixture.root
                    .appending(path: "Outside-Roots")
            ) { _ in }
        }
        #expect(OrderedFragmentURLProtocol.requestedURLs.isEmpty)
    }

    @Test
    func HLSResourcesStageSequentiallyWithHeadersRangesAndEventMapping()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        HLSResourceURLProtocol.reset(
            scriptedResponses: [
                "/hls/init.mp4": [
                    .init(statusCode: 200, body: "init"),
                ],
                "/hls/one.ts": [
                    .init(statusCode: 200, body: "segment-one"),
                ],
                "/hls/shared.mp4": [
                    .init(
                        statusCode: 206,
                        body: "aaaa",
                        headers: ["Content-Range": "bytes 0-3/8"]
                    ),
                    .init(
                        statusCode: 206,
                        body: "bbbb",
                        headers: ["Content-Range": "bytes 4-7/8"]
                    ),
                ],
            ]
        )
        let service = HLSPlanFixture.service(fixture: fixture)
        let selection = try HLSPlanFixture.selection()
        let progress = HLSProgressRecorder()

        let result = try await service.downloadHLSResources(
            selection,
            jobID: fixture.jobID,
            progress: progress.record
        )

        #expect(result.videoID == selection.videoID)
        #expect(result.formatID == selection.formatID)
        #expect(
            result.stagingDirectoryURL.deletingLastPathComponent()
                == fixture.roots.applicationSupportDirectory.appending(
                    path: "HLS-Staging",
                    directoryHint: .isDirectory
                )
        )
        #expect(result.events.count == selection.resourcePlan.events.count)
        #expect(
            result.events[2] == .discontinuity(eventPosition: 2)
        )
        let staged = result.events.compactMap(\.resource)
        #expect(staged.map(\.position) == [0, 1, 2, 3])
        #expect(staged.map(\.kind) == [
            .initialization, .media, .media, .media,
        ])
        #expect(staged.map(\.byteRange) == [
            nil,
            nil,
            HLSMediaByteRange(offset: 0, length: 4),
            HLSMediaByteRange(offset: 4, length: 4),
        ])
        #expect(
            try staged.map {
                String(decoding: try Data(contentsOf: $0.fileURL), as: UTF8.self)
            } == ["init", "segment-one", "aaaa", "bbbb"]
        )
        #expect(HLSResourceURLProtocol.requestedPaths == [
            "/hls/init.mp4", "/hls/one.ts", "/hls/shared.mp4",
            "/hls/shared.mp4",
        ])
        #expect(HLSResourceURLProtocol.rangeHeaders == [
            nil, nil, "bytes=0-3", "bytes=4-7",
        ])
        #expect(
            HLSResourceURLProtocol.userAgents
                == Array(repeating: "Illucet-HLS-Test", count: 4)
        )
        #expect(
            HLSResourceURLProtocol.cookieHandling
                == Array(repeating: false, count: 4)
        )
        #expect(
            HLSResourceURLProtocol.acceptEncodings
                == Array(repeating: "identity", count: 4)
        )
        #expect(HLSResourceURLProtocol.maximumActiveRequestCount == 1)
        #expect(HLSResourceURLProtocol.currentActiveRequestCount == 0)
        #expect(progress.completedCounts == [1, 2, 3, 4])
        #expect(progress.completedBytes == [4, 15, 19, 23])
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: result.stagingDirectoryURL.path
            ).sorted() == [
                "resource-000000-init.part",
                "resource-000001-media.part",
                "resource-000002-media.part",
                "resource-000003-media.part",
            ]
        )
    }

    @Test
    func HLSRangeRequiresExact206ContentRangeAndLength() async throws {
        let cases: [HLSResourceResponse] = [
            .init(statusCode: 200, body: "aaaa"),
            .init(
                statusCode: 206,
                body: "aaaa",
                headers: ["Content-Range": "bytes 1-4/8"]
            ),
            .init(
                statusCode: 206,
                body: "aaa",
                headers: ["Content-Range": "bytes 0-3/8"]
            ),
            .init(
                statusCode: 206,
                body: "aaaaa",
                headers: ["Content-Range": "bytes 0-3/8"]
            ),
        ]
        for response in cases {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            HLSResourceURLProtocol.reset(
                scriptedResponses: ["/hls/shared.mp4": [response]]
            )
            let service = HLSPlanFixture.service(fixture: fixture)
            let selection = try HLSPlanFixture.selection(
                playlist: HLSPlanFixture.singleRangePlaylist
            )

            await #expect(throws: HLSResourceStagingError.self) {
                _ = try await service.downloadHLSResources(
                    selection,
                    jobID: fixture.jobID
                ) { _ in }
            }
            #expect(HLSResourceURLProtocol.requestedPaths == [
                "/hls/shared.mp4",
            ])
            #expect(try HLSPlanFixture.stagingChildren(fixture).isEmpty)
        }
    }

    @Test
    func HLSFullResourcesRequire200NonemptyAndMatchingContentLength()
        async throws
    {
        let cases: [HLSResourceResponse] = [
            .init(
                statusCode: 206,
                body: "data",
                headers: ["Content-Range": "bytes 0-3/4"]
            ),
            .init(statusCode: 200, body: ""),
            .init(
                statusCode: 200,
                body: "data",
                headers: ["Content-Length": "3"]
            ),
            .init(
                statusCode: 200,
                body: "data",
                headers: ["Content-Length": "invalid"]
            ),
        ]
        for response in cases {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            HLSResourceURLProtocol.reset(
                scriptedResponses: ["/hls/one.ts": [response]]
            )
            let service = HLSPlanFixture.service(fixture: fixture)
            let selection = try HLSPlanFixture.selection(
                playlist: HLSPlanFixture.singleFullPlaylist
            )

            await #expect(throws: HLSResourceStagingError.self) {
                _ = try await service.downloadHLSResources(
                    selection,
                    jobID: fixture.jobID
                ) { _ in }
            }
            #expect(HLSResourceURLProtocol.requestedPaths == ["/hls/one.ts"])
            #expect(try HLSPlanFixture.stagingChildren(fixture).isEmpty)
        }
    }

    @Test
    func HLSRedirectsRevalidateDestinationsAndReapplyExactHeaders()
        throws
    {
        let initial = HLSPlanFixture.mediaURL
        let destination = URL(
            string:
                "https://redirected.googlevideo.com/hls/shared.mp4?sig=redirected"
        )!
        var visited: Set<String> = [initial.absoluteString]
        var redirectCount = 0
        let request = try HLSResourceRedirectValidation.redirectedRequest(
            destinationURL: destination,
            HTTPHeaders: ["User-Agent": "Illucet-HLS-Test"],
            byteRange: HLSMediaByteRange(offset: 4, length: 4),
            timeoutInterval: 60,
            allowsExpensiveAccess: false,
            allowsConstrainedAccess: false,
            visitedURLs: &visited,
            redirectCount: &redirectCount,
            maximumRedirects: 4
        )

        #expect(request.url == destination)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent")
            == "Illucet-HLS-Test")
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=4-7")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding")
            == "identity")
        #expect(!request.allowsExpensiveNetworkAccess)
        #expect(!request.allowsConstrainedNetworkAccess)
        #expect(!request.httpShouldHandleCookies)
        #expect(redirectCount == 1)

        #expect(throws: HLSResourceStagingError.unsafeRedirect) {
            _ = try HLSResourceRedirectValidation.redirectedRequest(
                destinationURL: URL(string: "https://example.invalid/bad")!,
                HTTPHeaders: ["User-Agent": "Illucet-HLS-Test"],
                byteRange: nil,
                timeoutInterval: 60,
                allowsExpensiveAccess: true,
                allowsConstrainedAccess: true,
                visitedURLs: &visited,
                redirectCount: &redirectCount,
                maximumRedirects: 4
            )
        }
        #expect(throws: HLSResourceStagingError.unsafeRedirect) {
            _ = try HLSResourceRedirectValidation.redirectedRequest(
                destinationURL: destination,
                HTTPHeaders: ["User-Agent": "Illucet-HLS-Test"],
                byteRange: nil,
                timeoutInterval: 60,
                allowsExpensiveAccess: true,
                allowsConstrainedAccess: true,
                visitedURLs: &visited,
                redirectCount: &redirectCount,
                maximumRedirects: 4
            )
        }
        redirectCount = 4
        #expect(throws: HLSResourceStagingError.tooManyRedirects) {
            _ = try HLSResourceRedirectValidation.redirectedRequest(
                destinationURL: URL(
                    string: "https://another.googlevideo.com/hls/next"
                )!,
                HTTPHeaders: ["User-Agent": "Illucet-HLS-Test"],
                byteRange: nil,
                timeoutInterval: 60,
                allowsExpensiveAccess: true,
                allowsConstrainedAccess: true,
                visitedURLs: &visited,
                redirectCount: &redirectCount,
                maximumRedirects: 4
            )
        }
    }

    @Test
    func HLSFailureStopsBeforeLaterResourcesAndRemovesTaskStaging()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        HLSResourceURLProtocol.reset(
            scriptedResponses: [
                "/hls/init.mp4": [
                    .init(statusCode: 200, body: "init"),
                ],
                "/hls/one.ts": [
                    .init(statusCode: 503, body: "failure"),
                ],
            ]
        )
        let service = HLSPlanFixture.service(fixture: fixture)
        let selection = try HLSPlanFixture.selection()

        await #expect(throws: StreamDownloadError.transientHTTPFailure(statusCode: 503)) {
            _ = try await service.downloadHLSResources(
                selection,
                jobID: fixture.jobID
            ) { _ in }
        }

        #expect(HLSResourceURLProtocol.requestedPaths == [
            "/hls/init.mp4", "/hls/one.ts",
        ])
        #expect(try HLSPlanFixture.stagingChildren(fixture).isEmpty)
    }

    @Test
    func HLSCancellationStopsCurrentResourceAndRemovesTaskStaging()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        HLSResourceURLProtocol.reset(responseDelaySeconds: 0.5)
        let service = HLSPlanFixture.service(fixture: fixture)
        let selection = try HLSPlanFixture.selection()
        let operation = Task {
            try await service.downloadHLSResources(
                selection,
                jobID: fixture.jobID
            ) { _ in }
        }
        try await waitUntil {
            HLSResourceURLProtocol.requestedPaths.count == 1
        }

        operation.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await operation.value
        }

        #expect(HLSResourceURLProtocol.requestedPaths.count == 1)
        #expect(try HLSPlanFixture.stagingChildren(fixture).isEmpty)
    }

    @Test
    func HLSCancelWaitsForTerminalAcknowledgementAndCleansStaging()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        HLSResourceURLProtocol.reset(responseDelaySeconds: 0.5)
        let service = HLSPlanFixture.service(fixture: fixture)
        let operation = Task {
            try await service.downloadHLSResources(
                HLSPlanFixture.selection(),
                jobID: fixture.jobID
            ) { _ in }
        }
        try await waitUntil {
            HLSResourceURLProtocol.requestedPaths.count == 1
        }

        let control = await service.cancel(jobID: fixture.jobID)

        #expect(control.matchedTaskCount == 1)
        #expect(control.affectedTaskCount == 1)
        #expect(control.acknowledgedTaskCount == 1)
        await #expect(throws: CancellationError.self) {
            _ = try await operation.value
        }
        #expect(HLSResourceURLProtocol.requestedPaths.count == 1)
        #expect(try HLSPlanFixture.stagingChildren(fixture).isEmpty)
    }

    @Test
    func HLSForgedHeadersPlansAndSymlinkStagingFailBeforeNetwork()
        async throws
    {
        do {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            HLSResourceURLProtocol.reset()
            let service = HLSPlanFixture.service(fixture: fixture)
            let valid = try HLSPlanFixture.selection()
            let forged = HLSPlanFixture.replacing(
                valid,
                HTTPHeaders: ["Authorization": "Bearer secret"]
            )

            await #expect(throws: HLSResourceStagingError.invalidPlan) {
                _ = try await service.downloadHLSResources(
                    forged,
                    jobID: fixture.jobID
                ) { _ in }
            }
            #expect(HLSResourceURLProtocol.requestedPaths.isEmpty)
        }

        do {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            HLSResourceURLProtocol.reset()
            let service = HLSPlanFixture.service(fixture: fixture)
            let valid = try HLSPlanFixture.selection()
            var events = valid.resourcePlan.events
            guard case let .media(eventPosition, resource, _) = events[1]
            else {
                Issue.record("Expected the fixture's first media event.")
                return
            }
            events[1] = .media(
                eventPosition: eventPosition,
                resource: resource,
                initializationEventPosition: nil
            )
            let forgedPlan = HLSMediaResourcePlan(
                events: events,
                mediaSegmentCount: valid.resourcePlan.mediaSegmentCount,
                initializationCount: valid.resourcePlan.initializationCount,
                projectedByteCount: valid.resourcePlan.projectedByteCount
            )
            let forged = HLSPlanFixture.replacing(
                valid,
                resourcePlan: forgedPlan
            )

            await #expect(throws: HLSResourceStagingError.invalidPlan) {
                _ = try await service.downloadHLSResources(
                    forged,
                    jobID: fixture.jobID
                ) { _ in }
            }
            #expect(HLSResourceURLProtocol.requestedPaths.isEmpty)
        }

        do {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            HLSResourceURLProtocol.reset()
            let outside = fixture.root.appending(
                path: "Outside-HLS",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: fixture.roots.applicationSupportDirectory.appending(
                    path: "HLS-Staging",
                    directoryHint: .isDirectory
                ),
                withDestinationURL: outside
            )
            let service = HLSPlanFixture.service(fixture: fixture)

            await #expect(
                throws: HLSResourceStagingError.invalidStagingDestination
            ) {
                _ = try await service.downloadHLSResources(
                    HLSPlanFixture.selection(),
                    jobID: fixture.jobID
                ) { _ in }
            }
            #expect(HLSResourceURLProtocol.requestedPaths.isEmpty)
            #expect(
                try FileManager.default.contentsOfDirectory(
                    atPath: outside.path
                ).isEmpty
            )
        }
    }

    @Test @MainActor
    func completionBrokerFinishesEveryHandlerExactlyOnce() {
        let identifier = "tests.illucet.events.\(UUID().uuidString)"
        var firstCount = 0
        var secondCount = 0
        BackgroundSessionEventBroker.shared.register(
            sessionIdentifier: identifier
        ) {
            firstCount += 1
        }
        BackgroundSessionEventBroker.shared.register(
            sessionIdentifier: identifier
        ) {
            secondCount += 1
        }

        #expect(
            BackgroundSessionEventBroker.shared.pendingCompletionCount(
                sessionIdentifier: identifier
            ) == 2
        )
        #expect(
            BackgroundSessionEventBroker.shared.finishEvents(
                sessionIdentifier: identifier
            ) == 2
        )
        #expect(firstCount == 1)
        #expect(secondCount == 1)
        #expect(firstCount == 1)
        #expect(secondCount == 1)
    }

    @Test @MainActor
    func completionBrokerConsumesAnEarlyFinishExactlyOnce() {
        let identifier = "tests.illucet.early.\(UUID().uuidString)"
        var completionCount = 0

        #expect(
            BackgroundSessionEventBroker.shared.finishEvents(
                sessionIdentifier: identifier
            ) == 0
        )
        #expect(
            BackgroundSessionEventBroker.shared.pendingEarlyFinishCount(
                sessionIdentifier: identifier
            ) == 1
        )
        BackgroundSessionEventBroker.shared.register(
            sessionIdentifier: identifier
        ) {
            completionCount += 1
        }

        #expect(completionCount == 1)
        #expect(
            BackgroundSessionEventBroker.shared.pendingEarlyFinishCount(
                sessionIdentifier: identifier
            ) == 0
        )
        #expect(
            BackgroundSessionEventBroker.shared.pendingCompletionCount(
                sessionIdentifier: identifier
            ) == 0
        )
    }

    @Test
    func HLSAESResourcesPublishOnlyPlaintextWithRotationAndKeyReuse()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let keyAURL = URL(
            string: "https://manifest.googlevideo.com/hls/key-a.bin"
        )!
        let keyBURL = URL(
            string: "https://manifest.googlevideo.com/hls/key-b.bin"
        )!
        let keyA = HLSAESFixture.data(
            hex: "000102030405060708090a0b0c0d0e0f"
        )
        let keyB = HLSAESFixture.data(
            hex: "101112131415161718191a1b1c1d1e1f"
        )
        let keyLoader = FixtureHLSAES128KeyLoader(keys: [
            keyAURL.absoluteString: keyA,
            keyBURL.absoluteString: keyB,
        ])
        HLSResourceURLProtocol.reset(scriptedResponses: [
            "/hls/init.mp4": [
                .init(
                    statusCode: 200,
                    body: HLSAESFixture.data(
                        hex: "1a69db5e42eded43b8d28ca09d0b3418"
                    )
                ),
            ],
            "/hls/one.ts": [
                .init(
                    statusCode: 200,
                    body: HLSAESFixture.data(
                        hex: "64e0d6c0909db44df7dbca1c5eefcecc"
                    )
                ),
            ],
            "/hls/two.ts": [
                .init(
                    statusCode: 200,
                    body: HLSAESFixture.data(
                        hex: "15341e6ba6838ba7b54aae25357a817f"
                            + "cf43316f5fccceee065842af8f8b28d5"
                    )
                ),
            ],
            "/hls/three.ts": [
                .init(
                    statusCode: 200,
                    body: HLSAESFixture.data(
                        hex: "518bbb0512d4f677b669ca48ceb107b1"
                    )
                ),
            ],
        ])
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:2
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:7
        #EXT-X-KEY:METHOD=AES-128,URI="key-a.bin",IV=0x202122232425262728292A2B2C2D2E2F
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6,
        one.ts
        #EXT-X-DISCONTINUITY
        #EXT-X-KEY:METHOD=AES-128,URI="key-b.bin"
        #EXTINF:6,
        two.ts
        #EXT-X-KEY:METHOD=AES-128,URI="key-a.bin"
        #EXTINF:6,
        three.ts
        #EXT-X-ENDLIST
        """
        let selection = try HLSPlanFixture.selection(playlist: playlist)
        let service = HLSPlanFixture.service(
            fixture: fixture,
            hlsAES128KeyLoader: keyLoader
        )
        let progress = HLSProgressRecorder()

        let result = try await service.downloadHLSResources(
            selection,
            jobID: fixture.jobID,
            progress: progress.record
        )

        let resources = result.events.compactMap(\.resource)
        #expect(resources.map(\.position) == [0, 1, 2, 3])
        #expect(resources.map(\.kind) == [
            .initialization, .media, .media, .media,
        ])
        #expect(result.events[2] == .discontinuity(eventPosition: 2))
        #expect(
            try resources.map {
                String(decoding: try Data(contentsOf: $0.fileURL), as: UTF8.self)
            } == ["plain-init", "plain-one", "plain-two-longer", "plain-three"]
        )
        #expect(resources.map(\.byteCount) == [10, 9, 16, 11])
        #expect(progress.completedCounts == [1, 2, 3, 4])
        #expect(progress.completedBytes == [10, 19, 35, 46])
        #expect(
            await keyLoader.requestedURLs() == [keyAURL, keyBURL]
        )
        #expect(HLSResourceURLProtocol.requestedPaths == [
            "/hls/init.mp4", "/hls/one.ts", "/hls/two.ts", "/hls/three.ts",
        ])
        let filenames = try FileManager.default.contentsOfDirectory(
            atPath: result.stagingDirectoryURL.path
        ).sorted()
        #expect(filenames == [
            "resource-000000-init.part",
            "resource-000001-media.part",
            "resource-000002-media.part",
            "resource-000003-media.part",
        ])
        #expect(
            filenames.allSatisfy {
                !$0.localizedCaseInsensitiveContains("key")
                    && !$0.localizedCaseInsensitiveContains("cipher")
                    && !$0.localizedCaseInsensitiveContains("plaintext")
                    && !$0.localizedCaseInsensitiveContains("inflight")
            }
        )
        #expect(
            try resources.allSatisfy {
                let data = try Data(contentsOf: $0.fileURL)
                return data != keyA && data != keyB
            }
        )
    }

    @Test
    func HLSAESPaddingFailureRemovesCiphertextAndPartialPlaintext()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let keyURL = URL(
            string: "https://manifest.googlevideo.com/hls/key.bin"
        )!
        let keyLoader = FixtureHLSAES128KeyLoader(keys: [
            keyURL.absoluteString: HLSAESFixture.data(
                hex: "000102030405060708090a0b0c0d0e0f"
            ),
        ])
        var tampered = HLSAESFixture.data(
            hex: "64e0d6c0909db44df7dbca1c5eefcecc"
        )
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        HLSResourceURLProtocol.reset(scriptedResponses: [
            "/hls/one.ts": [
                .init(statusCode: 200, body: tampered),
            ],
        ])
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:2
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x202122232425262728292A2B2C2D2E2F
        #EXTINF:6,
        one.ts
        #EXT-X-ENDLIST
        """
        let service = HLSPlanFixture.service(
            fixture: fixture,
            hlsAES128KeyLoader: keyLoader
        )
        let progress = HLSProgressRecorder()

        await #expect(throws: HLSAES128CBCDecryptionError.invalidPadding) {
            _ = try await service.downloadHLSResources(
                HLSPlanFixture.selection(playlist: playlist),
                jobID: fixture.jobID,
                progress: progress.record
            )
        }

        #expect(HLSResourceURLProtocol.requestedPaths == ["/hls/one.ts"])
        #expect(progress.completedCounts.isEmpty)
        #expect(try HLSPlanFixture.stagingChildren(fixture).isEmpty)
    }

    @Test
    func HLSAESKeyFailureStopsBeforeResourceTransferAndCleansStaging()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let keyLoader = FixtureHLSAES128KeyLoader(keys: [:])
        HLSResourceURLProtocol.reset()
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=AES-128,URI="missing-key.bin"
        #EXTINF:6,
        one.ts
        #EXT-X-ENDLIST
        """
        let service = HLSPlanFixture.service(
            fixture: fixture,
            hlsAES128KeyLoader: keyLoader
        )

        await #expect(throws: HLSAES128KeyLoadingError.invalidResponse) {
            _ = try await service.downloadHLSResources(
                HLSPlanFixture.selection(playlist: playlist),
                jobID: fixture.jobID
            ) { _ in }
        }

        #expect(HLSResourceURLProtocol.requestedPaths.isEmpty)
        #expect(try HLSPlanFixture.stagingChildren(fixture).isEmpty)
    }

    @Test
    func HLSCompletedResourceSurvivesInterruptionAndServiceRelaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:7
        #EXTINF:4,
        one.ts?sig=one
        #EXTINF:4,
        two.ts?sig=two
        #EXT-X-ENDLIST
        """
        let selection = try HLSPlanFixture.selection(playlist: playlist)
        HLSResourceURLProtocol.reset(scriptedResponses: [
            "/hls/one.ts": [.init(statusCode: 200, body: "data", headers: ["ETag": "\"object-one\""])],
            "/hls/two.ts": [.init(statusCode: 503, body: "retry")],
        ])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HLSResourceURLProtocol.self]
        let first = StreamDownloadService(sessionIdentifier: fixture.sessionIdentifier,
            configuration: config, destinationRoots: fixture.roots)
        await #expect(throws: StreamDownloadError.transientHTTPFailure(statusCode: 503)) {
            _ = try await first.downloadHLSResources(selection, jobID: fixture.jobID) { _ in }
        }
        first.session.invalidateAndCancel()
        #expect(try HLSPlanFixture.stagingChildren(fixture).isEmpty)
        HLSResourceURLProtocol.reset(scriptedResponses: [
            "/hls/two.ts": [.init(statusCode: 200, body: "tail", headers: ["ETag": "\"object-two\""])],
        ])
        let validator = BackgroundFragmentValidatorFixture()
        let second = StreamDownloadService(sessionIdentifier: fixture.sessionIdentifier + ".relaunch",
            configuration: config, destinationRoots: fixture.roots, fragmentValidatorNetworking: validator)
        defer { second.session.invalidateAndCancel() }
        let progress = HLSProgressRecorder()
        let staged = try await second.downloadHLSResources(selection, jobID: fixture.jobID, progress: progress.record)
        #expect(HLSResourceURLProtocol.requestedPaths == ["/hls/two.ts"])
        #expect(await validator.requestCount == 1)
        #expect(staged.events.compactMap(\.resource).map(\.byteCount) == [4, 4])
        #expect(progress.completedBytes == [4, 8])
        #expect(progress.reusedBytes == [4, 4])
    }

    @Test
    func DASHCompletedFragmentSurvivesInterruptionAndServiceRelaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let plan = DASHPlanFixture.plan()
        OrderedFragmentURLProtocol.reset(scriptedResponses: [
            "/init": [.init(statusCode: 200, body: "init", headers: ["ETag": "\"object-one\""])],
            "/media-1": [.init(statusCode: 503, body: "retry")],
        ])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OrderedFragmentURLProtocol.self]
        let first = StreamDownloadService(sessionIdentifier: fixture.sessionIdentifier,
            configuration: config, destinationRoots: fixture.roots,
            dashFragmentRetryPolicy: DASHFragmentRetryPolicy(maximumRetries: 0))
        let firstProgress = DASHResumeProgressRecorder()
        await #expect(throws: StreamDownloadError.transientHTTPFailure(statusCode: 503)) {
            _ = try await first.downloadDASHFragments(plan, jobID: fixture.jobID,
                stagingDirectoryURL: fixture.roots.temporaryDirectory.appending(path: "first"), progress: firstProgress.record)
        }
        first.session.invalidateAndCancel()
        #expect(firstProgress.reusedTotals.allSatisfy { $0 == 0 })
        OrderedFragmentURLProtocol.reset()
        let validator = BackgroundFragmentValidatorFixture()
        let second = StreamDownloadService(sessionIdentifier: fixture.sessionIdentifier + ".relaunch",
            configuration: config, destinationRoots: fixture.roots, fragmentValidatorNetworking: validator)
        defer { second.session.invalidateAndCancel() }
        let directory = fixture.roots.temporaryDirectory.appending(path: "second")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resumedProgress = DASHResumeProgressRecorder()
        let staged = try await second.downloadDASHFragments(plan, jobID: fixture.jobID,
            stagingDirectoryURL: directory, progress: resumedProgress.record)
        #expect(!resumedProgress.reusedTotals.isEmpty)
        #expect(resumedProgress.reusedTotals.allSatisfy { $0 == 4 })
        #expect(OrderedFragmentURLProtocol.requestedURLs == [plan.fragments[1].URL.absoluteString, plan.fragments[2].URL.absoluteString])
        #expect(await validator.requestCount == 1)
        #expect(staged.fragments.map(\.byteCount) == [4, 7, 4])
        #expect(OrderedFragmentURLProtocol.maximumActiveRequestCount == 1)
    }

    private func waitUntil(
        maximumAttempts: Int = 300,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0 ..< maximumAttempts {
            if await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BackgroundTransferTestError.timeout
    }
}

private struct Fixture {
    let root: URL
    let roots: StreamTransferDestinationRoots
    let sessionIdentifier: String
    let jobID = UUID()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-BackgroundTests-\(UUID().uuidString)",
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
        sessionIdentifier = "tests.illucet.background.\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            at: roots.temporaryDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: roots.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class DelayedDownloadURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    private static let requestLock = NSLock()
    private static let responseCondition = NSCondition()
    nonisolated(unsafe) private static var requestCountStorage = 0
    nonisolated(unsafe) private static var requestPolicyStorage:
        StreamTransferNetworkPolicy?
    nonisolated(unsafe) private static var lastHTTPMethodStorage: String?
    nonisolated(unsafe) private static var lastRangeHeaderStorage: String?
    nonisolated(unsafe) private static var responsesHeld = false
    private lazy var workBox = DelayedURLProtocolWorkBox(self)

    static var requestCount: Int {
        requestLock.withLock { requestCountStorage }
    }

    static var lastRequestPolicy: StreamTransferNetworkPolicy? {
        requestLock.withLock { requestPolicyStorage }
    }

    static var lastHTTPMethod: String? {
        requestLock.withLock { lastHTTPMethodStorage }
    }

    static var lastRangeHeader: String? {
        requestLock.withLock { lastRangeHeaderStorage }
    }

    static func reset() {
        releaseResponses()
        requestLock.withLock {
            requestCountStorage = 0
            requestPolicyStorage = nil
            lastHTTPMethodStorage = nil
            lastRangeHeaderStorage = nil
        }
    }

    static func holdResponses() {
        responseCondition.lock()
        responsesHeld = true
        responseCondition.unlock()
    }

    static func releaseResponses() {
        responseCondition.lock()
        responsesHeld = false
        responseCondition.broadcast()
        responseCondition.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "illucet.test"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestLock.withLock {
            Self.requestCountStorage += 1
            Self.requestPolicyStorage = StreamTransferNetworkPolicy(
                allowsExpensiveAccess: request.allowsExpensiveNetworkAccess,
                allowsConstrainedAccess:
                    request.allowsConstrainedNetworkAccess
            )
            Self.lastHTTPMethodStorage = request.httpMethod
            Self.lastRangeHeaderStorage = request.value(
                forHTTPHeaderField: "Range"
            )
        }
        let workBox = workBox
        DispatchQueue.global(qos: .utility).async {
            workBox.value?.respond()
        }
    }

    override func stopLoading() {}

    private func respond() {
        Self.responseCondition.lock()
        while Self.responsesHeld {
            Self.responseCondition.wait()
        }
        Self.responseCondition.unlock()
        Thread.sleep(forTimeInterval: 0.2)
        guard
            let URL = request.url,
            let response = HTTPURLResponse(
                url: URL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "5",
                    "Content-Type": "application/octet-stream",
                ]
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data("media".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class DelayedURLProtocolWorkBox: @unchecked Sendable {
    weak var value: DelayedDownloadURLProtocol?

    init(_ value: DelayedDownloadURLProtocol) {
        self.value = value
    }
}

private enum HLSPlanFixture {
    static let mediaURL = URL(
        string: "https://manifest.googlevideo.com/hls/media.m3u8?sig=playlist"
    )!

    static let playlist = """
    #EXTM3U
    #EXT-X-TARGETDURATION:6
    #EXT-X-MAP:URI="init.mp4?sig=init"
    #EXTINF:6,
    one.ts?sig=one
    #EXT-X-DISCONTINUITY
    #EXTINF:6,
    #EXT-X-BYTERANGE:4@0
    shared.mp4?sig=shared
    #EXTINF:6,
    #EXT-X-BYTERANGE:4
    shared.mp4?sig=shared
    #EXT-X-ENDLIST
    """

    static let singleRangePlaylist = """
    #EXTM3U
    #EXT-X-TARGETDURATION:6
    #EXTINF:6,
    #EXT-X-BYTERANGE:4@0
    shared.mp4?sig=shared
    #EXT-X-ENDLIST
    """

    static let singleFullPlaylist = """
    #EXTM3U
    #EXT-X-TARGETDURATION:6
    #EXTINF:6,
    one.ts?sig=one
    #EXT-X-ENDLIST
    """

    static func service(
        fixture: Fixture,
        hlsAES128KeyLoader: any HLSAES128KeyLoading =
            URLSessionHLSAES128KeyLoader()
    ) -> StreamDownloadService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSResourceURLProtocol.self]
        return StreamDownloadService(
            fileManager: .default,
            sessionIdentifier: fixture.sessionIdentifier,
            configuration: configuration,
            destinationRoots: fixture.roots,
            hlsAES128KeyLoader: hlsAES128KeyLoader
        )
    }

    static func activeDescriptor(
        fixture: Fixture,
        taskIdentifier: Int,
        resourcePosition: Int = 0,
        resourceKind: HLSBackgroundResourceKind = .initialization,
        uniqueID: UUID = UUID()
    ) throws -> HLSResourceTransferDescriptor {
        let stagingDirectory = fixture.roots.applicationSupportDirectory
            .appending(
                path:
                    "HLS-Staging/task-\(fixture.jobID.uuidString.lowercased())-\(uniqueID.uuidString.lowercased())",
                directoryHint: .isDirectory
            )
        let filename = String(
            format: ".resource-%06d-%@.part.inflight",
            resourcePosition,
            resourceKind.rawValue
        )
        return try HLSResourceTransferDescriptor(
            sessionIdentifier: fixture.sessionIdentifier,
            taskIdentifier: taskIdentifier,
            jobID: fixture.jobID,
            resourcePosition: resourcePosition,
            resourceKind: resourceKind,
            stagingDirectory: fixture.roots.identity(for: stagingDirectory),
            inFlightDestination: fixture.roots.identity(
                for: stagingDirectory.appending(path: filename)
            )
        )
    }

    static func stagingDirectory(
        fixture: Fixture,
        descriptor: HLSResourceTransferDescriptor
    ) -> URL {
        fixture.roots.applicationSupportDirectory.appending(
            path: descriptor.stagingDirectory.relativePath,
            directoryHint: .isDirectory
        )
    }

    static func selection(
        playlist: String = playlist
    ) throws -> ResolvedHLSPlaylistSelection {
        let document = try HLSPlaylistParser.parse(
            Data(playlist.utf8),
            finalPlaylistURL: mediaURL
        )
        guard case let .media(plan) = document else {
            throw HLSResourceStagingError.invalidPlan
        }
        return ResolvedHLSPlaylistSelection(
            videoID: "AbCdEf123_-",
            formatID: "hls-720",
            protocolName: "m3u8_native",
            sourceType: "hls",
            fileExtension: "mp4",
            hasVideo: true,
            hasAudio: true,
            HTTPHeaders: ["User-Agent": "Illucet-HLS-Test"],
            mediaPlaylistURL: mediaURL,
            route: .directMedia,
            playlistRequestCount: 1,
            redirectCount: 0,
            masterVariantCount: 0,
            mediaSegmentCount: plan.mediaSegmentCount,
            resourcePlan: plan,
            resolvedAt: .now
        )
    }

    static func replacing(
        _ selection: ResolvedHLSPlaylistSelection,
        HTTPHeaders: [String: String]? = nil,
        resourcePlan: HLSMediaResourcePlan? = nil
    ) -> ResolvedHLSPlaylistSelection {
        let plan = resourcePlan ?? selection.resourcePlan
        return ResolvedHLSPlaylistSelection(
            videoID: selection.videoID,
            formatID: selection.formatID,
            protocolName: selection.protocolName,
            sourceType: selection.sourceType,
            fileExtension: selection.fileExtension,
            hasVideo: selection.hasVideo,
            hasAudio: selection.hasAudio,
            HTTPHeaders: HTTPHeaders ?? selection.HTTPHeaders,
            mediaPlaylistURL: selection.mediaPlaylistURL,
            route: selection.route,
            playlistRequestCount: selection.playlistRequestCount,
            redirectCount: selection.redirectCount,
            masterVariantCount: selection.masterVariantCount,
            mediaSegmentCount: plan.mediaSegmentCount,
            resourcePlan: plan,
            resolvedAt: selection.resolvedAt
        )
    }

    static func stagingChildren(_ fixture: Fixture) throws -> [String] {
        let directory = fixture.roots.applicationSupportDirectory.appending(
            path: "HLS-Staging",
            directoryHint: .isDirectory
        )
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
    }
}

private struct HLSResourceResponse: Sendable {
    let statusCode: Int
    let body: Data
    let headers: [String: String]

    init(
        statusCode: Int,
        body: String,
        headers: [String: String] = [:]
    ) {
        self.init(
            statusCode: statusCode,
            body: Data(body.utf8),
            headers: headers
        )
    }

    init(
        statusCode: Int,
        body: Data,
        headers: [String: String] = [:]
    ) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }
}

private final class HLSProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var countStorage: [Int] = []
    private var byteStorage: [Int64] = []
    private var reusedStorage: [Int64] = []
    var reusedBytes: [Int64] { lock.withLock { reusedStorage } }

    var completedCounts: [Int] {
        lock.withLock { countStorage }
    }

    var completedBytes: [Int64] {
        lock.withLock { byteStorage }
    }

    func record(_ progress: HLSResourceTransferProgress) {
        lock.withLock {
            countStorage.append(progress.completedResourceCount)
            byteStorage.append(progress.completedBytes)
            reusedStorage.append(progress.verifiedReusableBytes)
        }
    }
}

private enum HLSAESFixture {
    static func data(hex: String) -> Data {
        precondition(hex.utf8.count.isMultiple(of: 2))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.utf8.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index ..< nextIndex], radix: 16)!)
            index = nextIndex
        }
        return Data(bytes)
    }
}

private actor FixtureHLSAES128KeyLoader: HLSAES128KeyLoading {
    private let keys: [String: Data]
    private var requestedURLStorage: [URL] = []

    init(keys: [String: Data]) {
        self.keys = keys
    }

    func loadKey(
        from initialURL: URL,
        HTTPHeaders: [String: String],
        networkPolicy: StreamTransferNetworkPolicy,
        maximumRedirects: Int
    ) async throws -> HLSAES128KeyLoadResult {
        try Task.checkCancellation()
        guard
            HLSPlaylistSecurity.isAllowedPlaylistURL(initialURL),
            HLSPlaylistSecurity.areAllowedHeaders(HTTPHeaders),
            maximumRedirects >= 0,
            let key = keys[initialURL.absoluteString],
            key.count == URLSessionHLSAES128KeyLoader.keyByteCount
        else {
            throw HLSAES128KeyLoadingError.invalidResponse
        }
        _ = networkPolicy
        requestedURLStorage.append(initialURL)
        return HLSAES128KeyLoadResult(key: key, redirectCount: 0)
    }

    func requestedURLs() -> [URL] {
        requestedURLStorage
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var complete = false

    var isComplete: Bool {
        lock.withLock { complete }
    }

    func markComplete() {
        lock.withLock { complete = true }
    }
}

private final class HLSResourceURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestedPathStorage: [String] = []
    nonisolated(unsafe) private static var rangeHeaderStorage: [String?] = []
    nonisolated(unsafe) private static var userAgentStorage: [String] = []
    nonisolated(unsafe) private static var cookieHandlingStorage: [Bool] = []
    nonisolated(unsafe) private static var acceptEncodingStorage: [String] = []
    nonisolated(unsafe) private static var activeRequestCount = 0
    nonisolated(unsafe) private static var maximumActiveStorage = 0
    nonisolated(unsafe) private static var scriptedResponsesStorage:
        [String: [HLSResourceResponse]] = [:]
    nonisolated(unsafe) private static var responseIndicesStorage:
        [String: Int] = [:]
    nonisolated(unsafe) private static var responseDelaySecondsStorage = 0.01

    private let stateLock = NSLock()
    private var stopped = false
    private var countedActive = false

    static var requestedPaths: [String] {
        lock.withLock { requestedPathStorage }
    }

    static var rangeHeaders: [String?] {
        lock.withLock { rangeHeaderStorage }
    }

    static var userAgents: [String] {
        lock.withLock { userAgentStorage }
    }

    static var cookieHandling: [Bool] {
        lock.withLock { cookieHandlingStorage }
    }

    static var acceptEncodings: [String] {
        lock.withLock { acceptEncodingStorage }
    }

    static var maximumActiveRequestCount: Int {
        lock.withLock { maximumActiveStorage }
    }

    static var currentActiveRequestCount: Int {
        lock.withLock { activeRequestCount }
    }

    static func reset(
        scriptedResponses: [String: [HLSResourceResponse]] = [:],
        responseDelaySeconds: Double = 0.01
    ) {
        lock.withLock {
            requestedPathStorage = []
            rangeHeaderStorage = []
            userAgentStorage = []
            cookieHandlingStorage = []
            acceptEncodingStorage = []
            activeRequestCount = 0
            maximumActiveStorage = 0
            scriptedResponsesStorage = scriptedResponses
            responseIndicesStorage = [:]
            responseDelaySecondsStorage = max(0, responseDelaySeconds)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".googlevideo.com") == true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let URL = request.url else { return }
        let started = stateLock.withLock {
            guard !stopped else { return false }
            countedActive = true
            Self.lock.withLock {
                Self.requestedPathStorage.append(URL.path)
                Self.rangeHeaderStorage.append(
                    request.value(forHTTPHeaderField: "Range")
                )
                Self.userAgentStorage.append(
                    request.value(forHTTPHeaderField: "User-Agent") ?? ""
                )
                Self.cookieHandlingStorage.append(request.httpShouldHandleCookies)
                Self.acceptEncodingStorage.append(
                    request.value(forHTTPHeaderField: "Accept-Encoding") ?? ""
                )
                Self.activeRequestCount += 1
                Self.maximumActiveStorage = max(
                    Self.maximumActiveStorage,
                    Self.activeRequestCount
                )
            }
            return true
        }
        guard started else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.respond(to: URL)
        }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
        finishCountingRequest()
    }

    private func finishCountingRequest() {
        let wasActive = stateLock.withLock {
            let result = countedActive
            countedActive = false
            return result
        }
        if wasActive { Self.lock.withLock { Self.activeRequestCount -= 1 } }
    }

    private func respond(to URL: URL) {
        let selection = Self.lock.withLock {
            () -> (HLSResourceResponse, Double) in
            let index = Self.responseIndicesStorage[URL.path, default: 0]
            Self.responseIndicesStorage[URL.path] = index + 1
            let script = Self.scriptedResponsesStorage[URL.path] ?? []
            let response = script.isEmpty
                ? HLSResourceResponse(
                    statusCode: 200,
                    body: URL.lastPathComponent
                )
                : script[min(index, script.count - 1)]
            return (response, Self.responseDelaySecondsStorage)
        }
        Thread.sleep(forTimeInterval: selection.1)
        defer { finishCountingRequest() }
        guard !stateLock.withLock({ stopped }) else { return }
        let response = selection.0
        let body = response.body
        var headers = response.headers
        if headers.keys.allSatisfy({
            $0.caseInsensitiveCompare("Content-Length") != .orderedSame
        }) {
            headers["Content-Length"] = String(body.count)
        }
        guard let HTTPResponse = HTTPURLResponse(
            url: URL,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            return
        }
        client?.urlProtocol(
            self,
            didReceive: HTTPResponse,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: body)
        // URLSession may start the next resource as soon as this callback is
        // delivered. A completed response is no longer an active request.
        finishCountingRequest()
        client?.urlProtocolDidFinishLoading(self)
    }
}

private enum DASHPlanFixture {
    static func plan(expectedBytes: Int64? = 15) -> ResolvedDASHFragmentPlan {
        let repeated = URL(
            string:
                "https://rr1---sn.example.googlevideo.com/init?sig=repeated"
        )!
        return ResolvedDASHFragmentPlan(
            videoID: "AbCdEf123_-",
            formatID: "137-dashy",
            protocolName: "http_dash_segments",
            sourceType: "dash",
            fileExtension: "mp4",
            hasVideo: true,
            hasAudio: false,
            HTTPHeaders: ["User-Agent": "Illucet-DASH-Test"],
            expectedBytes: expectedBytes,
            fragments: [
                ResolvedDASHFragment(
                    position: 0,
                    URL: repeated,
                    expectedBytes: 4
                ),
                ResolvedDASHFragment(
                    position: 1,
                    URL: URL(
                        string:
                            "https://rr1---sn.example.googlevideo.com/media-1?sig=second"
                    )!,
                    expectedBytes: 7
                ),
                ResolvedDASHFragment(
                    position: 2,
                    URL: repeated,
                    expectedBytes: 4
                ),
            ],
            resolvedAt: .now
        )
    }
}

private struct OrderedFragmentResponse: Sendable {
    let statusCode: Int
    let body: String
    var headers: [String: String] = [:]
}

private final class DASHRetrySleeperRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let blockUntilCancelled: Bool
    private var delayStorage: [Double] = []

    init(blockUntilCancelled: Bool = false) {
        self.blockUntilCancelled = blockUntilCancelled
    }

    var delays: [Double] {
        lock.withLock { delayStorage }
    }

    func sleep(_ delay: Double) async throws {
        lock.withLock {
            delayStorage.append(delay)
        }
        if blockUntilCancelled {
            try await Task.sleep(for: .seconds(30))
        }
    }
}

private final class TransferDescriptorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptions: [String] = []

    var encodedDescriptions: [String] {
        lock.withLock { descriptions }
    }

    func record(_ descriptor: StreamTransferDescriptor) {
        guard let encoded = try? descriptor.encodedTaskDescription() else {
            return
        }
        lock.withLock {
            descriptions.append(encoded)
        }
    }
}

private final class OrderedFragmentURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestedURLStorage: [String] = []
    nonisolated(unsafe) private static var userAgentStorage: [String] = []
    nonisolated(unsafe) private static var activeRequestCount = 0
    nonisolated(unsafe) private static var maximumActiveRequestCountStorage = 0
    nonisolated(unsafe) private static var scriptedResponsesStorage:
        [String: [OrderedFragmentResponse]] = [:]
    nonisolated(unsafe) private static var responseIndicesStorage:
        [String: Int] = [:]
    nonisolated(unsafe) private static var responseDelaySecondsStorage = 0.03
    nonisolated(unsafe) private static var holdResponsesUntilCancelledStorage = false

    private let stateLock = NSLock()
    private var stopped = false
    private var countedActive = false
    private let responseGate = DispatchSemaphore(value: 0)

    static var requestedURLs: [String] {
        lock.withLock { requestedURLStorage }
    }

    static var userAgents: [String] {
        lock.withLock { userAgentStorage }
    }

    static var maximumActiveRequestCount: Int {
        lock.withLock { maximumActiveRequestCountStorage }
    }

    static var currentActiveRequestCount: Int {
        lock.withLock { activeRequestCount }
    }

    static func reset(
        scriptedResponses: [String: [OrderedFragmentResponse]] = [:],
        responseDelaySeconds: Double = 0.03,
        holdResponsesUntilCancelled: Bool = false
    ) {
        lock.withLock {
            requestedURLStorage = []
            userAgentStorage = []
            activeRequestCount = 0
            maximumActiveRequestCountStorage = 0
            scriptedResponsesStorage = scriptedResponses
            responseIndicesStorage = [:]
            responseDelaySecondsStorage = max(0, responseDelaySeconds)
            holdResponsesUntilCancelledStorage = holdResponsesUntilCancelled
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".googlevideo.com") == true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let URL = request.url else { return }
        let started = stateLock.withLock {
            guard !stopped else { return false }
            countedActive = true
            Self.lock.withLock {
                Self.requestedURLStorage.append(URL.absoluteString)
                Self.userAgentStorage.append(
                    request.value(forHTTPHeaderField: "User-Agent") ?? ""
                )
                Self.activeRequestCount += 1
                Self.maximumActiveRequestCountStorage = max(
                    Self.maximumActiveRequestCountStorage,
                    Self.activeRequestCount
                )
            }
            return true
        }
        guard started else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.respond()
        }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
        finishCountingRequest()
        responseGate.signal()
    }

    private func finishCountingRequest() {
        let wasActive = stateLock.withLock {
            let result = countedActive
            countedActive = false
            return result
        }
        if wasActive { Self.lock.withLock { Self.activeRequestCount -= 1 } }
    }

    private func respond() {
        defer { finishCountingRequest() }
        guard let URL = request.url else { return }
        let selection = Self.lock.withLock {
            () -> (OrderedFragmentResponse, Double, Bool) in
            let index = Self.responseIndicesStorage[URL.path, default: 0]
            Self.responseIndicesStorage[URL.path] = index + 1
            let script = Self.scriptedResponsesStorage[URL.path] ?? []
            let selected = script.isEmpty
                ? OrderedFragmentResponse(
                    statusCode: 200,
                    body: URL.lastPathComponent
                )
                : script[min(index, script.count - 1)]
            return (selected, Self.responseDelaySecondsStorage, Self.holdResponsesUntilCancelledStorage)
        }
        if selection.2 {
            // Keep the cancellation precondition stable regardless of scheduling.
            // stopLoading releases this worker even if the test exits early.
            responseGate.wait()
            return
        }
        Thread.sleep(forTimeInterval: selection.1)
        guard !stateLock.withLock({ stopped }) else { return }
        let scriptedResponse = selection.0
        let body = Data(scriptedResponse.body.utf8)
        guard let response = HTTPURLResponse(
            url: URL,
            statusCode: scriptedResponse.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: scriptedResponse.headers.merging(["Content-Length": String(body.count)]) { _, length in length }
        ) else {
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: body)
        // The next fragment/retry may start as soon as completion is delivered.
        finishCountingRequest()
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class StreamDownloadServiceBox: @unchecked Sendable {
    weak var service: StreamDownloadService?
}

private final class WaiterRegistrationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let secondInvocationGate = DispatchSemaphore(value: 0)
    private var invocationCount = 0

    var secondInvocationReached: Bool {
        lock.withLock { invocationCount >= 2 }
    }

    func pauseSecondInvocation() {
        let shouldPause = lock.withLock { () -> Bool in
            invocationCount += 1
            return invocationCount == 2
        }
        if shouldPause {
            secondInvocationGate.wait()
        }
    }

    func releaseSecondInvocation() {
        secondInvocationGate.signal()
    }
}

private enum BackgroundTransferTestError: Error {
    case timeout
}

private actor BoundedRequestStartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    func waitForRelease() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class PrecancelledRequestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    static var requestCount: Int { lock.withLock { count } }
    static func reset() { lock.withLock { count = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "7"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("fixture".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor BackgroundFragmentValidatorFixture: HLSPlaylistNetworking {
    private(set) var requestCount = 0
    func response(for request: URLRequest, maximumBytes: Int) async throws -> HLSPlaylistHTTPResponse {
        requestCount += 1
        return HLSPlaylistHTTPResponse(statusCode: 200, headers: ["ETag": "\"object-one\""], body: Data())
    }
}

private final class DASHResumeProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    var reusedTotals: [Int64] { lock.withLock { values } }
    func record(_ progress: DASHFragmentTransferProgress) {
        lock.withLock {
            values.append(progress.verifiedReusableBytesBeforeFragment + progress.fragmentProgress.verifiedReusableBytes)
        }
    }
}
