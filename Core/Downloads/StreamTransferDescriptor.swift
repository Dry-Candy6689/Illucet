import Foundation

enum StreamTransferDestinationRoot: String, Codable, Sendable {
    case temporary
    case applicationSupport
}

struct StreamTransferDestinationIdentity:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let root: StreamTransferDestinationRoot
    let relativePath: String
}

struct StreamTransferDestinationRoots: Equatable, Sendable {
    let temporaryDirectory: URL
    let applicationSupportDirectory: URL

    static func live(
        fileManager: FileManager = .default
    ) -> StreamTransferDestinationRoots {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appending(
                path: AppIdentity.storageDirectoryName,
                directoryHint: .isDirectory
            )
            .appending(path: "Transfers", directoryHint: .isDirectory)
        return StreamTransferDestinationRoots(
            temporaryDirectory: fileManager.temporaryDirectory,
            applicationSupportDirectory: applicationSupport
        )
    }

    func identity(
        for destinationURL: URL
    ) throws -> StreamTransferDestinationIdentity {
        guard destinationURL.isFileURL else {
            throw StreamTransferDescriptorError.invalidDestination
        }
        for (kind, rootURL) in orderedRoots {
            guard let relativePath = Self.canonicalRelativePath(
                from: rootURL,
                to: destinationURL
            ) else { continue }
            try Self.validate(relativePath: relativePath)
            return StreamTransferDestinationIdentity(
                root: kind,
                relativePath: relativePath
            )
        }
        throw StreamTransferDescriptorError.destinationOutsideAllowedRoots
    }

    func URL(
        for identity: StreamTransferDestinationIdentity
    ) throws -> Foundation.URL {
        try Self.validate(relativePath: identity.relativePath)
        let root = switch identity.root {
        case .temporary:
            temporaryDirectory
        case .applicationSupport:
            applicationSupportDirectory
        }
        let destination = root.appending(
            path: identity.relativePath,
            directoryHint: .notDirectory
        )
        guard
            let canonicalRelativePath = Self.canonicalRelativePath(
                from: root,
                to: destination
            ),
            let canonicalDestination = Self.canonicalFileURL(destination)
        else {
            throw StreamTransferDescriptorError.invalidDestination
        }
        try Self.validate(relativePath: canonicalRelativePath)
        return canonicalDestination
    }

    private var orderedRoots: [
        (StreamTransferDestinationRoot, Foundation.URL)
    ] {
        [
            (.applicationSupport, applicationSupportDirectory),
            (.temporary, temporaryDirectory),
        ].sorted { $0.1.path.count > $1.1.path.count }
    }

    private static func validate(relativePath: String) throws {
        guard
            !relativePath.isEmpty,
            relativePath.utf8.count <= 2_048,
            !relativePath.hasPrefix("/"),
            !relativePath.contains("\\"),
            !relativePath.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw StreamTransferDescriptorError.invalidDestination
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
        }) else {
            throw StreamTransferDescriptorError.invalidDestination
        }
    }

    private static func canonicalRelativePath(
        from rootURL: URL,
        to destinationURL: URL
    ) -> String? {
        guard rootURL.isFileURL, destinationURL.isFileURL else {
            return nil
        }
        guard
            let canonicalRoot = canonicalFileURL(rootURL),
            let canonicalDestination = canonicalFileURL(destinationURL)
        else {
            return nil
        }
        let rootComponents = canonicalRoot.pathComponents
        let destinationComponents = canonicalDestination.pathComponents
        guard
            destinationComponents.count > rootComponents.count,
            destinationComponents.prefix(rootComponents.count)
                .elementsEqual(rootComponents)
        else {
            return nil
        }
        return destinationComponents
            .dropFirst(rootComponents.count)
            .joined(separator: "/")
    }

    /// Resolves every existing ancestor before restoring any not-yet-created
    /// suffix. `URL.resolvingSymlinksInPath()` alone cannot reliably resolve a
    /// symlink when a later destination component does not exist yet.
    private static func canonicalFileURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }

        let fileManager = FileManager.default
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []

        while !fileManager.fileExists(atPath: existingAncestor.path) {
            // A dangling symlink is not a safe base for a future transfer.
            if (try? fileManager.destinationOfSymbolicLink(
                atPath: existingAncestor.path
            )) != nil {
                return nil
            }

            let component = existingAncestor.lastPathComponent
            let parent = existingAncestor.deletingLastPathComponent()
            guard
                !component.isEmpty,
                parent.path != existingAncestor.path
            else {
                return nil
            }
            missingComponents.append(component)
            existingAncestor = parent
        }

        var canonicalURL = existingAncestor
            .resolvingSymlinksInPath()
            .standardizedFileURL
        for component in missingComponents.reversed() {
            canonicalURL.append(path: component)
        }
        return canonicalURL.standardizedFileURL
    }
}

struct StreamTransferDescriptor:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    static let currentSchemaVersion = 2
    static let minimumSupportedSchemaVersion = 1
    static let maximumDescriptionBytes = 4_096

    let schemaVersion: Int
    let sessionIdentifier: String
    let taskIdentifier: Int
    let jobID: UUID
    let streamID: String
    let destination: StreamTransferDestinationIdentity
    let mediaRole: StreamTransferMediaRole?
    let expectedTotalBytes: Int64?
    let byteRange: StreamByteRange?
    let rangeChunkBytes: Int64?
    let stagingDestination: StreamTransferDestinationIdentity?

    init(
        sessionIdentifier: String,
        taskIdentifier: Int,
        jobID: UUID,
        streamID: String,
        destination: StreamTransferDestinationIdentity,
        mediaRole: StreamTransferMediaRole? = nil,
        expectedTotalBytes: Int64? = nil,
        byteRange: StreamByteRange? = nil,
        rangeChunkBytes: Int64? = nil,
        stagingDestination: StreamTransferDestinationIdentity? = nil
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.sessionIdentifier = sessionIdentifier
        self.taskIdentifier = taskIdentifier
        self.jobID = jobID
        self.streamID = streamID
        self.destination = destination
        self.mediaRole = mediaRole
        self.expectedTotalBytes = expectedTotalBytes
        self.byteRange = byteRange
        self.rangeChunkBytes = rangeChunkBytes
        self.stagingDestination = stagingDestination
        try validate(
            expectedSessionIdentifier: sessionIdentifier,
            expectedTaskIdentifier: taskIdentifier
        )
    }

    func encodedTaskDescription() throws -> String {
        try validate(
            expectedSessionIdentifier: sessionIdentifier,
            expectedTaskIdentifier: taskIdentifier
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumDescriptionBytes else {
            throw StreamTransferDescriptorError.descriptionTooLarge
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeTaskDescription(
        _ value: String?,
        expectedSessionIdentifier: String,
        expectedTaskIdentifier: Int
    ) throws -> StreamTransferDescriptor {
        guard
            let value,
            !value.isEmpty,
            value.utf8.count <= maximumDescriptionBytes
        else {
            throw StreamTransferDescriptorError.invalidDescription
        }
        let descriptor: StreamTransferDescriptor
        do {
            descriptor = try JSONDecoder().decode(
                StreamTransferDescriptor.self,
                from: Data(value.utf8)
            )
        } catch {
            throw StreamTransferDescriptorError.invalidDescription
        }
        try descriptor.validate(
            expectedSessionIdentifier: expectedSessionIdentifier,
            expectedTaskIdentifier: expectedTaskIdentifier
        )
        return descriptor
    }

    func destinationURL(
        in roots: StreamTransferDestinationRoots
    ) throws -> URL {
        try roots.URL(for: destination)
    }

    func transferOutputURL(
        in roots: StreamTransferDestinationRoots
    ) throws -> URL {
        if let stagingDestination {
            return try roots.URL(for: stagingDestination)
        }
        return try destinationURL(in: roots)
    }

    static func expectedStagingDestination(
        destination: StreamTransferDestinationIdentity,
        mediaRole: StreamTransferMediaRole,
        expectedTotalBytes: Int64,
        byteRange: StreamByteRange
    ) throws -> StreamTransferDestinationIdentity {
        let validationRoots = StreamTransferDestinationRoots(
            temporaryDirectory: URL(filePath: "/tmp"),
            applicationSupportDirectory: URL(filePath: "/app-support")
        )
        let destinationURL = try validationRoots.URL(for: destination)
        let stagingURL = StreamRangeStaging.chunkURL(
            in: StreamRangeStaging.directory(
                for: destinationURL,
                role: mediaRole,
                totalBytes: expectedTotalBytes
            ),
            range: byteRange
        )
        return try validationRoots.identity(for: stagingURL)
    }

    private func validate(
        expectedSessionIdentifier: String,
        expectedTaskIdentifier: Int
    ) throws {
        guard
            (Self.minimumSupportedSchemaVersion
                ... Self.currentSchemaVersion).contains(schemaVersion)
        else {
            throw StreamTransferDescriptorError.unsupportedSchema
        }
        guard
            !sessionIdentifier.isEmpty,
            sessionIdentifier.utf8.count <= 255,
            sessionIdentifier == expectedSessionIdentifier
        else {
            throw StreamTransferDescriptorError.sessionMismatch
        }
        guard
            taskIdentifier > 0,
            taskIdentifier == expectedTaskIdentifier
        else {
            throw StreamTransferDescriptorError.taskMismatch
        }
        guard
            !streamID.isEmpty,
            streamID.utf8.count <= 256,
            !streamID.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw StreamTransferDescriptorError.invalidStreamID
        }
        let validationRoots = StreamTransferDestinationRoots(
            temporaryDirectory: URL(filePath: "/tmp"),
            applicationSupportDirectory: URL(filePath: "/app-support")
        )
        _ = try validationRoots.URL(for: destination)
        if schemaVersion == Self.minimumSupportedSchemaVersion {
            guard
                mediaRole == nil,
                expectedTotalBytes == nil,
                byteRange == nil,
                rangeChunkBytes == nil,
                stagingDestination == nil
            else {
                throw StreamTransferDescriptorError.invalidRange
            }
            return
        }
        if let expectedTotalBytes, expectedTotalBytes <= 0 {
            throw StreamTransferDescriptorError.invalidRange
        }
        guard let byteRange else {
            guard
                rangeChunkBytes == nil,
                stagingDestination == nil
            else {
                throw StreamTransferDescriptorError.invalidRange
            }
            return
        }
        guard
            let mediaRole,
            let expectedTotalBytes,
            let rangeChunkBytes,
            let stagingDestination,
            stagingDestination.root == destination.root,
            stagingDestination != destination
        else {
            throw StreamTransferDescriptorError.invalidRange
        }
        do {
            try byteRange.validate(totalBytes: expectedTotalBytes)
            guard
                let plan = StreamRangePlan(
                    expectedTotalBytes: expectedTotalBytes,
                    suggestedChunkBytes: rangeChunkBytes
                ),
                plan.chunkBytes == rangeChunkBytes,
                plan.ranges.contains(byteRange)
            else {
                throw StreamTransferDescriptorError.invalidRange
            }
            let expectedStagingDestination = try Self
                .expectedStagingDestination(
                    destination: destination,
                    mediaRole: mediaRole,
                    expectedTotalBytes: expectedTotalBytes,
                    byteRange: byteRange
                )
            guard stagingDestination == expectedStagingDestination else {
                throw StreamTransferDescriptorError.invalidRange
            }
        } catch {
            throw StreamTransferDescriptorError.invalidRange
        }
    }
}

enum StreamTransferTaskState: String, Codable, Equatable, Sendable {
    case running
    case suspended
    case cancelling
    case completed
    case unknown

    init(_ state: URLSessionTask.State) {
        self = switch state {
        case .running: .running
        case .suspended: .suspended
        case .canceling: .cancelling
        case .completed: .completed
        @unknown default: .unknown
        }
    }
}

struct StreamTransferRegistration: Equatable, Sendable {
    let descriptor: StreamTransferDescriptor
    let state: StreamTransferTaskState
    let bytesReceived: Int64
    let totalBytesExpected: Int64?
    let verifiedReusableBytes: Int64
    let networkBytesReceived: Int64
    let earliestBeginDate: Date?

    init(
        descriptor: StreamTransferDescriptor,
        state: StreamTransferTaskState,
        bytesReceived: Int64,
        totalBytesExpected: Int64?,
        verifiedReusableBytes: Int64 = 0,
        networkBytesReceived: Int64? = nil,
        earliestBeginDate: Date? = nil
    ) {
        self.descriptor = descriptor
        self.state = state
        self.bytesReceived = max(0, bytesReceived)
        self.totalBytesExpected = totalBytesExpected
        self.verifiedReusableBytes = max(0, verifiedReusableBytes)
        self.networkBytesReceived = max(
            0,
            networkBytesReceived ?? bytesReceived
        )
        self.earliestBeginDate = earliestBeginDate
    }
}

enum HLSBackgroundResourceKind: String, Codable, Equatable, Sendable {
    case initialization = "init"
    case media

    init(_ kind: HLSMediaResourceKind) {
        self = switch kind {
        case .initialization: .initialization
        case .media: .media
        }
    }
}

/// Durable identity for one currently active HLS background resource task.
/// It intentionally contains no transport URL, headers, playlist, or completed
/// resource state. A recreated service can only cancel the lost operation and
/// remove its task-owned staging directory; it cannot resume the HLS plan.
struct HLSResourceTransferDescriptor:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    static let descriptorType = "illucet.hls-resource.active"
    static let legacyUndurableTaskDescription = "illucet-hls-resource-v1"
    static let currentSchemaVersion = 1
    static let maximumDescriptionBytes = 4_096
    static let maximumResourcePosition =
        HLSPlaylistParser.maximumMediaEntries
            + HLSPlaylistParser.maximumInitializationDeclarations - 1

    let descriptorType: String
    let schemaVersion: Int
    let sessionIdentifier: String
    let taskIdentifier: Int
    let jobID: UUID
    let resourcePosition: Int
    let resourceKind: HLSBackgroundResourceKind
    let stagingDirectory: StreamTransferDestinationIdentity
    let inFlightDestination: StreamTransferDestinationIdentity

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case descriptorType
        case schemaVersion
        case sessionIdentifier
        case taskIdentifier
        case jobID
        case resourcePosition
        case resourceKind
        case stagingDirectory
        case inFlightDestination
    }

    init(
        sessionIdentifier: String,
        taskIdentifier: Int,
        jobID: UUID,
        resourcePosition: Int,
        resourceKind: HLSBackgroundResourceKind,
        stagingDirectory: StreamTransferDestinationIdentity,
        inFlightDestination: StreamTransferDestinationIdentity
    ) throws {
        descriptorType = Self.descriptorType
        schemaVersion = Self.currentSchemaVersion
        self.sessionIdentifier = sessionIdentifier
        self.taskIdentifier = taskIdentifier
        self.jobID = jobID
        self.resourcePosition = resourcePosition
        self.resourceKind = resourceKind
        self.stagingDirectory = stagingDirectory
        self.inFlightDestination = inFlightDestination
        try validate(
            expectedSessionIdentifier: sessionIdentifier,
            expectedTaskIdentifier: taskIdentifier
        )
    }

    func encodedTaskDescription() throws -> String {
        try validate(
            expectedSessionIdentifier: sessionIdentifier,
            expectedTaskIdentifier: taskIdentifier
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumDescriptionBytes else {
            throw HLSResourceTransferDescriptorError.descriptionTooLarge
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeTaskDescription(
        _ value: String?,
        expectedSessionIdentifier: String,
        expectedTaskIdentifier: Int
    ) throws -> HLSResourceTransferDescriptor {
        guard
            let value,
            !value.isEmpty,
            value.utf8.count <= maximumDescriptionBytes
        else {
            throw HLSResourceTransferDescriptorError.invalidDescription
        }
        let data = Data(value.utf8)
        guard
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue)),
            Self.hasExactDestinationKeys(object["stagingDirectory"]),
            Self.hasExactDestinationKeys(object["inFlightDestination"])
        else {
            throw HLSResourceTransferDescriptorError.invalidDescription
        }
        let descriptor: HLSResourceTransferDescriptor
        do {
            descriptor = try JSONDecoder().decode(
                HLSResourceTransferDescriptor.self,
                from: data
            )
        } catch {
            throw HLSResourceTransferDescriptorError.invalidDescription
        }
        try descriptor.validate(
            expectedSessionIdentifier: expectedSessionIdentifier,
            expectedTaskIdentifier: expectedTaskIdentifier
        )
        return descriptor
    }

    static func hasTypeMarker(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        if value == legacyUndurableTaskDescription { return true }
        return value.contains(#""descriptorType""#)
            && value.contains(#""illucet.hls-resource.active""#)
    }

    private static func hasExactDestinationKeys(_ value: Any?) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        return Set(object.keys) == ["root", "relativePath"]
    }

    func stagingDirectoryURL(
        in roots: StreamTransferDestinationRoots
    ) throws -> URL {
        try roots.URL(for: stagingDirectory)
    }

    func inFlightURL(
        in roots: StreamTransferDestinationRoots
    ) throws -> URL {
        try roots.URL(for: inFlightDestination)
    }

    private func validate(
        expectedSessionIdentifier: String,
        expectedTaskIdentifier: Int
    ) throws {
        guard descriptorType == Self.descriptorType else {
            throw HLSResourceTransferDescriptorError.invalidType
        }
        guard schemaVersion == Self.currentSchemaVersion else {
            throw HLSResourceTransferDescriptorError.unsupportedSchema
        }
        guard
            !sessionIdentifier.isEmpty,
            sessionIdentifier.utf8.count <= 255,
            sessionIdentifier == expectedSessionIdentifier
        else {
            throw HLSResourceTransferDescriptorError.sessionMismatch
        }
        guard
            taskIdentifier > 0,
            taskIdentifier == expectedTaskIdentifier
        else {
            throw HLSResourceTransferDescriptorError.taskMismatch
        }
        guard
            (0 ... Self.maximumResourcePosition).contains(resourcePosition),
            stagingDirectory.root == .applicationSupport,
            inFlightDestination.root == .applicationSupport
        else {
            throw HLSResourceTransferDescriptorError.invalidIdentity
        }

        let stagingComponents = stagingDirectory.relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard
            stagingComponents.count == 2,
            stagingComponents[0] == "HLS-Staging"
        else {
            throw HLSResourceTransferDescriptorError.invalidIdentity
        }
        let taskComponent = String(stagingComponents[1])
        let prefix = "task-\(jobID.uuidString.lowercased())-"
        guard
            taskComponent.hasPrefix(prefix),
            taskComponent == taskComponent.lowercased()
        else {
            throw HLSResourceTransferDescriptorError.invalidIdentity
        }
        let uniqueText = String(taskComponent.dropFirst(prefix.count))
        guard
            let uniqueID = UUID(uuidString: uniqueText),
            uniqueID.uuidString.lowercased() == uniqueText
        else {
            throw HLSResourceTransferDescriptorError.invalidIdentity
        }

        let filename = String(
            format: ".resource-%06d-%@.part.inflight",
            resourcePosition,
            resourceKind.rawValue
        )
        guard inFlightDestination.relativePath
            == "\(stagingDirectory.relativePath)/\(filename)"
        else {
            throw HLSResourceTransferDescriptorError.invalidIdentity
        }

        let validationRoots = StreamTransferDestinationRoots(
            temporaryDirectory: URL(filePath: "/tmp"),
            applicationSupportDirectory: URL(filePath: "/app-support")
        )
        do {
            _ = try validationRoots.URL(for: stagingDirectory)
            _ = try validationRoots.URL(for: inFlightDestination)
        } catch {
            throw HLSResourceTransferDescriptorError.invalidIdentity
        }
    }
}

enum HLSResourceTransferDescriptorError:
    LocalizedError,
    Equatable,
    Sendable
{
    case invalidDescription
    case descriptionTooLarge
    case invalidType
    case unsupportedSchema
    case sessionMismatch
    case taskMismatch
    case invalidIdentity

    var errorDescription: String? {
        switch self {
        case .invalidDescription:
            "The active HLS background descriptor is invalid."
        case .descriptionTooLarge:
            "The active HLS background descriptor exceeded its size limit."
        case .invalidType:
            "The active HLS background descriptor type is invalid."
        case .unsupportedSchema:
            "The active HLS background descriptor schema is unsupported."
        case .sessionMismatch:
            "The active HLS background task belongs to another session."
        case .taskMismatch:
            "The active HLS background task identity does not match."
        case .invalidIdentity:
            "The active HLS background staging identity is invalid."
        }
    }
}

enum StreamTransferDescriptorError: LocalizedError, Equatable, Sendable {
    case invalidDescription
    case descriptionTooLarge
    case unsupportedSchema
    case sessionMismatch
    case taskMismatch
    case invalidStreamID
    case invalidDestination
    case destinationOutsideAllowedRoots
    case invalidRange

    var errorDescription: String? {
        switch self {
        case .invalidDescription:
            "The background transfer descriptor is invalid."
        case .descriptionTooLarge:
            "The background transfer descriptor exceeded its size limit."
        case .unsupportedSchema:
            "The background transfer descriptor uses an unsupported schema."
        case .sessionMismatch:
            "The background transfer belongs to another session."
        case .taskMismatch:
            "The background transfer task identity does not match."
        case .invalidStreamID:
            "The background transfer stream identity is invalid."
        case .invalidDestination:
            "The background transfer destination is invalid."
        case .destinationOutsideAllowedRoots:
            "The background transfer destination is outside Illucet storage."
        case .invalidRange:
            "The background transfer byte-range identity is invalid."
        }
    }
}
