import Foundation

extension StreamDownloadService {
    func downloadHLSResources(
        _ selection: ResolvedHLSPlaylistSelection,
        jobID: UUID,
        progress: @escaping HLSResourceTransferProgressHandler
    ) async throws -> HLSResourceStagingResult {
        try Task.checkCancellation()
        guard Self.isValidHLSSelection(selection) else {
            throw HLSResourceStagingError.invalidPlan
        }

        let lease = try FragmentSourceLeases.shared.acquire(jobID: jobID, formatID: selection.formatID)
        defer { FragmentSourceLeases.shared.release(lease) }
        let encrypted = selection.resourcePlan.events.contains { $0.resource?.encryption != nil }
        // Keys and key identity are intentionally ephemeral. Clear any old plaintext
        // checkpoint and restart encrypted playlists rather than infer key continuity.
        let checkpointStore = try fragmentCheckpoint(jobID: jobID, formatID: selection.formatID,
            fields: encrypted ? ["encrypted-restart", UUID().uuidString] : Self.HLSResumeFields(selection))
        let checkpoint: FragmentResumeCheckpoint? = encrypted ? nil : checkpointStore
        if encrypted { fragmentResumeEvent(jobID, selection.formatID, .encryptedResources) }

        let stagingDirectoryURL = destinationRoots.applicationSupportDirectory
            .appending(path: "HLS-Staging", directoryHint: .isDirectory)
            .appending(
                path: "task-\(jobID.uuidString.lowercased())-\(UUID().uuidString.lowercased())",
                directoryHint: .isDirectory
            )
        let resourceCount = selection.resourcePlan.events.reduce(into: 0) {
            if $1.resource != nil { $0 += 1 }
        }
        let stagingDirectoryIdentity: StreamTransferDestinationIdentity
        let plannedDestinations: [Int: HLSResourceDestination]
        do {
            stagingDirectoryIdentity = try destinationRoots.identity(
                for: stagingDirectoryURL
            )
            guard stagingDirectoryIdentity.root == .applicationSupport else {
                throw HLSResourceStagingError.invalidStagingDestination
            }
            plannedDestinations = try Dictionary(
                uniqueKeysWithValues: selection.resourcePlan.events.compactMap {
                    event -> (Int, HLSResourceDestination)? in
                    guard let resource = event.resource else { return nil }
                    let role = resource.kind == .initialization ? "init" : "media"
                    let filename = String(
                        format: "resource-%06d-%@.part",
                        resource.position,
                        role
                    )
                    let finalURL = stagingDirectoryURL.appending(
                        path: filename,
                        directoryHint: .notDirectory
                    )
                    let inFlightURL = stagingDirectoryURL.appending(
                        path: ".\(filename).inflight",
                        directoryHint: .notDirectory
                    )
                    let plaintextInFlightURL = stagingDirectoryURL.appending(
                        path: ".\(filename).plaintext.inflight",
                        directoryHint: .notDirectory
                    )
                    let finalIdentity = try destinationRoots.identity(
                        for: finalURL
                    )
                    let inFlightIdentity = try destinationRoots.identity(
                        for: inFlightURL
                    )
                    let plaintextInFlightIdentity = try destinationRoots
                        .identity(for: plaintextInFlightURL)

                    guard
                        Set([
                            finalIdentity,
                            inFlightIdentity,
                            plaintextInFlightIdentity,
                        ]).count == 3,
                        finalIdentity.root == .applicationSupport,
                        inFlightIdentity.root == .applicationSupport,
                        plaintextInFlightIdentity.root == .applicationSupport
                    else {
                        throw HLSResourceStagingError
                            .invalidStagingDestination
                    }
                    return (
                        resource.position,
                        HLSResourceDestination(
                            finalURL: finalURL,
                            inFlightURL: inFlightURL,
                            plaintextInFlightURL:
                                plaintextInFlightURL,
                            plaintextInFlightIdentity:
                                plaintextInFlightIdentity,
                            stagingDirectoryIdentity:
                                stagingDirectoryIdentity,
                            inFlightIdentity: inFlightIdentity
                        )
                    )
                }
            )
        } catch let error as HLSResourceStagingError {
            throw error
        } catch {
            throw HLSResourceStagingError.invalidStagingDestination
        }
        guard
            plannedDestinations.count == resourceCount,
            !fileManager.fileExists(atPath: stagingDirectoryURL.path)
        else {
            throw HLSResourceStagingError.invalidStagingDestination
        }

        do {
            try fileManager.createDirectory(
                at: stagingDirectoryURL,
                withIntermediateDirectories: true
            )
            guard isRegularDirectory(stagingDirectoryURL) else {
                throw HLSResourceStagingError.invalidStagingDestination
            }
            try BackgroundFileProtection.protect(stagingDirectoryURL, under: destinationRoots.applicationSupportDirectory, fileManager: fileManager)

            var stagedEvents: [StagedHLSPlaylistEvent] = []
            stagedEvents.reserveCapacity(selection.resourcePlan.events.count)
            var completedResources = 0
            var completedBytes: Int64 = 0
            var reusedBytes: Int64 = 0
            var remainingRedirects = HLSPlaylistSessionPolicy.secure
                .maximumRedirects
            var operationKeyCache: [String: Data] = [:]

            for event in selection.resourcePlan.events {
                try Task.checkCancellation()
                switch event {
                case let .discontinuity(eventPosition):
                    stagedEvents.append(
                        .discontinuity(eventPosition: eventPosition)
                    )
                case let .initialization(eventPosition, resource):
                    guard let destination = plannedDestinations[
                        resource.position
                    ] else {
                        throw HLSResourceStagingError.invalidPlan
                    }
                    let decryption = try await resolveHLSAES128Decryption(
                        resource,
                        selection: selection,
                        jobID: jobID,
                        cachedKey: resource.encryption.flatMap {
                            operationKeyCache[$0.keyURL.absoluteString]
                        },
                        maximumRedirects: remainingRedirects
                    )
                    if let loadedKey = decryption.loadedKey,
                       let keyURL = resource.encryption?.keyURL {
                        operationKeyCache[keyURL.absoluteString] = loadedKey
                    }
                    remainingRedirects -= decryption.redirectCount

                    let staged = try await stageCheckpointedHLSResource(
                        resource,
                        selection: selection,
                        destination: destination,
                        checkpoint: checkpoint,
                        jobID: jobID,
                        decryptionMaterial:
                            decryption.material,
                        maximumRedirects: remainingRedirects
                    )
                    remainingRedirects -= staged.redirectCount
                    reusedBytes = try addingHLSBytes(staged.reusedBytes, to: reusedBytes)
                    completedResources += 1
                    completedBytes = try addingHLSBytes(
                        staged.resource.byteCount,
                        to: completedBytes
                    )
                    stagedEvents.append(
                        .initialization(
                            eventPosition: eventPosition,
                            resource: staged.resource
                        )
                    )
                    progress(
                        HLSResourceTransferProgress(
                            jobID: jobID,
                            formatID: selection.formatID,
                            resourcePosition: resource.position,
                            completedResourceCount: completedResources,
                            resourceCount: resourceCount,
                            completedBytes: completedBytes,
                            verifiedReusableBytes: reusedBytes
                        )
                    )
                case let .media(
                    eventPosition,
                    resource,
                    initializationEventPosition
                ):
                    guard let destination = plannedDestinations[
                        resource.position
                    ] else {
                        throw HLSResourceStagingError.invalidPlan
                    }
                    let decryption = try await resolveHLSAES128Decryption(
                        resource,
                        selection: selection,
                        jobID: jobID,
                        cachedKey: resource.encryption.flatMap {
                            operationKeyCache[$0.keyURL.absoluteString]
                        },
                        maximumRedirects: remainingRedirects
                    )
                    if let loadedKey = decryption.loadedKey,
                       let keyURL = resource.encryption?.keyURL {
                        operationKeyCache[keyURL.absoluteString] = loadedKey
                    }
                    remainingRedirects -= decryption.redirectCount

                    let staged = try await stageCheckpointedHLSResource(
                        resource,
                        selection: selection,
                        destination: destination,
                        checkpoint: checkpoint,
                        jobID: jobID,
                        decryptionMaterial:
                            decryption.material,
                        maximumRedirects: remainingRedirects
                    )
                    remainingRedirects -= staged.redirectCount
                    reusedBytes = try addingHLSBytes(staged.reusedBytes, to: reusedBytes)
                    completedResources += 1
                    completedBytes = try addingHLSBytes(
                        staged.resource.byteCount,
                        to: completedBytes
                    )
                    stagedEvents.append(
                        .media(
                            eventPosition: eventPosition,
                            resource: staged.resource,
                            initializationEventPosition:
                                initializationEventPosition
                        )
                    )
                    progress(
                        HLSResourceTransferProgress(
                            jobID: jobID,
                            formatID: selection.formatID,
                            resourcePosition: resource.position,
                            completedResourceCount: completedResources,
                            resourceCount: resourceCount,
                            completedBytes: completedBytes,
                            verifiedReusableBytes: reusedBytes
                        )
                    )
                }
            }
            guard
                completedResources == resourceCount,
                isRegularDirectory(stagingDirectoryURL)
            else {
                throw HLSResourceStagingError.couldNotStageResource
            }
            try Task.checkCancellation()
            return HLSResourceStagingResult(
                videoID: selection.videoID,
                formatID: selection.formatID,
                stagingDirectoryURL: stagingDirectoryURL,
                events: stagedEvents
            )
        } catch {
            do {
                try discardHLSStagingDirectory(stagingDirectoryURL)
            } catch {
                throw HLSResourceStagingError.couldNotCleanStaging
            }
            throw error
        }
    }

    private func resolveHLSAES128Decryption(
        _ resource: HLSMediaResource,
        selection: ResolvedHLSPlaylistSelection,
        jobID: UUID,
        cachedKey: Data?,
        maximumRedirects: Int
    ) async throws -> (
        material: HLSAES128DecryptionMaterial?,
        loadedKey: Data?,
        redirectCount: Int
    ) {
        try Task.checkCancellation()
        guard maximumRedirects >= 0 else {
            throw HLSResourceStagingError.invalidPlan
        }
        guard let encryption = resource.encryption else {
            guard cachedKey == nil else {
                throw HLSResourceStagingError.invalidPlan
            }
            return (nil, nil, 0)
        }
        guard
            resource.byteRange == nil,
            HLSPlaylistSecurity.isAllowedPlaylistURL(encryption.keyURL),
            encryption.initializationVector.count
                == HLSAES128Encryption.byteCount
        else {
            throw HLSResourceStagingError.invalidPlan
        }

        let key: Data
        let loadedKey: Data?
        let redirectCount: Int
        if let cachedKey {
            guard cachedKey.count == HLSAES128Encryption.byteCount else {
                throw HLSResourceStagingError.invalidPlan
            }
            key = cachedKey
            loadedKey = nil
            redirectCount = 0
        } else {
            let result = try await hlsAES128KeyLoader.loadKey(
                from: encryption.keyURL,
                HTTPHeaders: selection.HTTPHeaders,
                networkPolicy: lifecycle.networkPolicy(jobID: jobID),
                maximumRedirects: maximumRedirects
            )
            guard
                result.key.count == HLSAES128Encryption.byteCount,
                (0...maximumRedirects).contains(result.redirectCount)
            else {
                throw HLSAES128KeyLoadingError.invalidResponse
            }
            key = result.key
            loadedKey = result.key
            redirectCount = result.redirectCount
        }
        return (
            HLSAES128DecryptionMaterial(
                key: key,
                initializationVector: encryption.initializationVector
            ),
            loadedKey,
            redirectCount
        )
    }

    private func stageCheckpointedHLSResource(
        _ resource: HLSMediaResource,
        selection: ResolvedHLSPlaylistSelection,
        destination: HLSResourceDestination,
        checkpoint: FragmentResumeCheckpoint?,
        jobID: UUID,
        decryptionMaterial: HLSAES128DecryptionMaterial?,
        maximumRedirects: Int
    ) async throws -> (resource: StagedHLSResource, redirectCount: Int, reusedBytes: Int64) {
        if let checkpoint,
           let bytes = try await restoreFragment(checkpoint: checkpoint,
               position: resource.position, remoteURL: resource.URL,
               headers: selection.HTTPHeaders, destination: destination.finalURL,
               jobID: jobID, expectedBytes: resource.byteRange?.length) {
            return (StagedHLSResource(position: resource.position, kind: resource.kind,
                fileURL: destination.finalURL, byteCount: bytes, byteRange: resource.byteRange), 0, bytes)
        }
        let staged = try await stageHLSResource(resource, selection: selection,
            destination: destination, jobID: jobID, decryptionMaterial: decryptionMaterial,
            maximumRedirects: maximumRedirects)
        try checkpoint?.accept(position: resource.position, fileURL: staged.resource.fileURL,
            remoteURL: resource.URL, validator: staged.validatorDigest)
        return (staged.resource, staged.redirectCount, 0)
    }

    private func stageHLSResource(
        _ resource: HLSMediaResource,
        selection: ResolvedHLSPlaylistSelection,
        destination: HLSResourceDestination,
        jobID: UUID,
        decryptionMaterial: HLSAES128DecryptionMaterial?,
        maximumRedirects: Int
    ) async throws -> (
        resource: StagedHLSResource,
        redirectCount: Int,
        validatorDigest: String?
    ) {
        guard
            maximumRedirects >= 0,
            HLSPlaylistSecurity.isAllowedPlaylistURL(resource.URL),
            HLSPlaylistSecurity.areAllowedHeaders(selection.HTTPHeaders),
            try destinationRoots.identity(for: destination.finalURL)
                .root == .applicationSupport,
            try destinationRoots.identity(for: destination.inFlightURL)
                == destination.inFlightIdentity,
            try destinationRoots.identity(
                for: destination.plaintextInFlightURL
            ) == destination.plaintextInFlightIdentity,
            (resource.encryption == nil) == (decryptionMaterial == nil),
            resource.encryption == nil || resource.byteRange == nil,
            decryptionMaterial == nil
                || (decryptionMaterial?.key.count == HLSAES128Encryption.byteCount
                    && decryptionMaterial?.initializationVector.count
                        == HLSAES128Encryption.byteCount),
            isRegularDirectory(destination.finalURL.deletingLastPathComponent()),
            !fileManager.fileExists(atPath: destination.finalURL.path),
            !fileManager.fileExists(atPath: destination.inFlightURL.path),
            !fileManager.fileExists(atPath: destination.plaintextInFlightURL.path)
        else {
            throw HLSResourceStagingError.invalidStagingDestination
        }

        var request = URLRequest(url: resource.URL)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let networkPolicy = lifecycle.networkPolicy(jobID: jobID)
        request.allowsExpensiveNetworkAccess =
            networkPolicy.allowsExpensiveAccess
        request.allowsConstrainedNetworkAccess =
            networkPolicy.allowsConstrainedAccess
        for (name, value) in selection.HTTPHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range = resource.byteRange?.streamRange {
            request.setValue(
                range.HTTPHeaderValue,
                forHTTPHeaderField: "Range"
            )
        } else if resource.byteRange != nil {
            throw HLSResourceStagingError.invalidPlan
        }

        let response = try await performHLSResourceTransfer(
            request,
            jobID: jobID,
            resourcePosition: resource.position,
            resourceKind: HLSBackgroundResourceKind(resource.kind),
            HTTPHeaders: selection.HTTPHeaders,
            byteRange: resource.byteRange,
            stagingDirectoryIdentity: destination.stagingDirectoryIdentity,
            inFlightIdentity: destination.inFlightIdentity,
            maximumRedirects: maximumRedirects
        )
        try Task.checkCancellation()
        do {
            let ciphertextByteCount = try validateHLSResourceResponse(
                response,
                expectedRange: resource.byteRange
            )
            guard
                response.fileURL.standardizedFileURL
                    == destination.inFlightURL.standardizedFileURL,
                isVerifiedRegularFile(
                    response.fileURL,
                    byteCount: ciphertextByteCount
                ),
                !fileManager.fileExists(atPath: destination.finalURL.path),
                !fileManager.fileExists(
                    atPath: destination.plaintextInFlightURL.path
                )
            else {
                throw HLSResourceStagingError.couldNotStageResource
            }

            let plaintextByteCount: Int64
            if let decryptionMaterial {
                plaintextByteCount = try HLSAES128CBCDecrypter.decrypt(
                    inputURL: response.fileURL,
                    outputURL: destination.plaintextInFlightURL,
                    key: decryptionMaterial.key,
                    initializationVector:
                        decryptionMaterial.initializationVector,
                    fileManager: fileManager
                )
                try Task.checkCancellation()
                guard isVerifiedRegularFile(
                    destination.plaintextInFlightURL,
                    byteCount: plaintextByteCount
                ) else {
                    throw HLSResourceStagingError.couldNotStageResource
                }
                try fileManager.removeItem(at: response.fileURL)
                guard !fileManager.fileExists(
                    atPath: response.fileURL.path
                ) else {
                    throw HLSResourceStagingError.couldNotStageResource
                }
                try fileManager.moveItem(
                    at: destination.plaintextInFlightURL,
                    to: destination.finalURL
                )
            } else {
                plaintextByteCount = ciphertextByteCount
                try fileManager.moveItem(
                    at: response.fileURL,
                    to: destination.finalURL
                )
            }
            guard isVerifiedRegularFile(
                destination.finalURL,
                byteCount: plaintextByteCount
            ) else {
                throw HLSResourceStagingError.couldNotStageResource
            }
            return (
                StagedHLSResource(
                    position: resource.position,
                    kind: resource.kind,
                    fileURL: destination.finalURL,
                    byteCount: plaintextByteCount,
                    byteRange: resource.byteRange
                ),
                response.redirectCount,
                response.finalURL == resource.URL
                    ? FragmentResumeCheckpoint.strongValidator(response.headers) : nil
            )
        } catch {
            try? fileManager.removeItem(at: destination.inFlightURL)
            try? fileManager.removeItem(at: destination.plaintextInFlightURL)
            try? fileManager.removeItem(at: destination.finalURL)
            throw error
        }
    }

    private func performHLSResourceTransfer(
        _ request: URLRequest,
        jobID: UUID,
        resourcePosition: Int,
        resourceKind: HLSBackgroundResourceKind,
        HTTPHeaders: [String: String],
        byteRange: HLSMediaByteRange?,
        stagingDirectoryIdentity: StreamTransferDestinationIdentity,
        inFlightIdentity: StreamTransferDestinationIdentity,
        maximumRedirects: Int
    ) async throws -> HLSResourceHTTPResponse {
        try await requireExecution(jobID: jobID)
        try await bandwidthLimiter.waitForAdmission(jobID: jobID)
        var mediaRequest = request
        mediaRequest.assumesHTTP3Capable = MediaTransportProtocolPolicy.assumesHTTP3Capable(request.url)
        let task = session.downloadTask(with: mediaRequest)
        bindNativeTask(task, jobID: jobID)
        let descriptor = try HLSResourceTransferDescriptor(
            sessionIdentifier: sessionIdentifier,
            taskIdentifier: task.taskIdentifier,
            jobID: jobID,
            resourcePosition: resourcePosition,
            resourceKind: resourceKind,
            stagingDirectory: stagingDirectoryIdentity,
            inFlightDestination: inFlightIdentity
        )
        task.taskDescription = try descriptor.encodedTaskDescription()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                hlsLifecycle.register(
                    task: task,
                    descriptor: descriptor,
                    HTTPHeaders: HTTPHeaders,
                    byteRange: byteRange,
                    inFlightIdentity: inFlightIdentity,
                    maximumRedirects: maximumRedirects,
                    initialURL: request.url,
                    continuation: continuation
                )
                if Task.isCancelled {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
        try await transferAcknowledgements.wait(taskID: task.taskIdentifier)
        try Task.checkCancellation()
        return result
    }

    private func validateHLSResourceResponse(
        _ response: HLSResourceHTTPResponse,
        expectedRange: HLSMediaByteRange?
    ) throws -> Int64 {
        if response.statusCode >= 400 {
            throw StreamDownloadError.HTTPFailure(statusCode: response.statusCode)
        }
        guard
            HLSPlaylistSecurity.isAllowedPlaylistURL(response.finalURL),
            let byteCount = exactFileSize(response.fileURL),
            byteCount > 0
        else {
            throw HLSResourceStagingError.invalidHTTPResponse
        }
        let contentLength = try strictHLSContentLength(response.headers)
        let contentEncodings = headerValues(
            named: "Content-Encoding",
            in: response.headers
        )
        guard
            contentEncodings.count <= 1,
            contentEncodings.first == nil
                || contentEncodings.first?.lowercased() == "identity"
        else {
            throw HLSResourceStagingError.invalidHTTPResponse
        }
        if let expectedRange {
            let contentRanges = headerValues(
                named: "Content-Range",
                in: response.headers
            )
            guard
                response.statusCode == 206,
                let streamRange = expectedRange.streamRange,
                contentRanges.count == 1,
                let contentRange = try? StreamContentRange.parse(
                    contentRanges[0]
                ),
                contentRange.range == streamRange,
                byteCount == expectedRange.length,
                contentLength.map({ $0 == expectedRange.length }) ?? true
            else {
                throw HLSResourceStagingError.invalidPartialContent
            }
        } else {
            guard
                response.statusCode == 200,
                headerValues(
                    named: "Content-Range",
                    in: response.headers
                ).isEmpty,
                contentLength.map({ $0 == byteCount }) ?? true
            else {
                throw HLSResourceStagingError.invalidHTTPResponse
            }
        }
        return byteCount
    }

    private func strictHLSContentLength(
        _ headers: [String: String]
    ) throws -> Int64? {
        let values = headerValues(named: "Content-Length", in: headers)
        guard values.count <= 1 else {
            throw HLSResourceStagingError.invalidContentLength
        }
        guard let raw = values.first else {
            return nil
        }
        guard
            !raw.isEmpty,
            raw.utf8.allSatisfy({ (48...57).contains($0) }),
            let value = Int64(raw),
            value >= 0
        else {
            throw HLSResourceStagingError.invalidContentLength
        }
        return value
    }

    private func headerValues(
        named name: String,
        in headers: [String: String]
    ) -> [String] {
        headers.compactMap {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
                ? $0.value
                : nil
        }
    }

    private func isVerifiedRegularFile(
        _ URL: URL,
        byteCount: Int64
    ) -> Bool {
        guard
            (try? fileManager.destinationOfSymbolicLink(atPath: URL.path))
                == nil,
            let values = try? URL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            ),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            values.fileSize.map(Int64.init) == byteCount
        else {
            return false
        }
        return true
    }

    private func isRegularDirectory(_ URL: URL) -> Bool {
        guard
            (try? fileManager.destinationOfSymbolicLink(atPath: URL.path))
                == nil,
            let values = try? URL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func discardHLSStagingDirectory(_ URL: URL) throws {
        if fileManager.fileExists(atPath: URL.path) {
            do {
                try fileManager.removeItem(at: URL)
            } catch {
                guard !fileManager.fileExists(atPath: URL.path) else {
                    throw error
                }
            }
        }
        guard !fileManager.fileExists(atPath: URL.path) else {
            throw HLSResourceStagingError.couldNotCleanStaging
        }
    }

    @discardableResult
    func cleanupLostHLSOperation(
        _ descriptor: HLSResourceTransferDescriptor
    ) -> Bool {
        do {
            let stagingDirectoryURL = try descriptor.stagingDirectoryURL(
                in: destinationRoots
            )
            try discardHLSStagingDirectory(stagingDirectoryURL)
            return !fileManager.fileExists(atPath: stagingDirectoryURL.path)
        } catch {
            return false
        }
    }

    private func addingHLSBytes(
        _ bytes: Int64,
        to total: Int64
    ) throws -> Int64 {
        let addition = total.addingReportingOverflow(bytes)
        guard !addition.overflow, addition.partialValue >= 0 else {
            throw HLSResourceStagingError.couldNotStageResource
        }
        return addition.partialValue
    }

    private static func isValidHLSSelection(
        _ selection: ResolvedHLSPlaylistSelection
    ) -> Bool {
        selection.videoID.utf8.count == 11
            && selection.videoID.utf8.allSatisfy({
                (48...57).contains($0)
                    || (65...90).contains($0)
                    || (97...122).contains($0)
                    || $0 == 45
                    || $0 == 95
            })
            && !selection.formatID.isEmpty
            && selection.formatID.utf8.count <= 256
            && ["m3u8", "m3u8_native"].contains(selection.protocolName)
            && selection.sourceType == "hls"
            && ["m4a", "mp4", "webm"].contains(selection.fileExtension)
            && (selection.hasVideo || selection.hasAudio)
            && HLSPlaylistSecurity.areAllowedHeaders(selection.HTTPHeaders)
            && HLSPlaylistSecurity.isAllowedPlaylistURL(
                selection.mediaPlaylistURL
            )
            && (0...HLSPlaylistSessionPolicy.secure.maximumRedirects)
                .contains(selection.redirectCount)
            && selection.route == .directMedia
            && selection.playlistRequestCount == 1
            && selection.masterVariantCount == 0
            && selection.mediaSegmentCount
                == selection.resourcePlan.mediaSegmentCount
            && HLSPlaylistParser.isValidMediaResourcePlan(
                selection.resourcePlan
            )
    }

}
