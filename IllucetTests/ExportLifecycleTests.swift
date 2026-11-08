import Foundation
import ImageIO
import Testing
import UIKit
@testable import Illucet

private struct FixturePhotoLibrary: PhotoLibraryExporting {
    func saveAsset(
        at fileURL: URL,
        kind: ExportAssetKind
    ) async throws -> String {
        "fixture-\(kind.rawValue)-\(fileURL.lastPathComponent)"
    }
}

private struct FailingPhotoLibrary: PhotoLibraryExporting {
    func saveAsset(
        at fileURL: URL,
        kind: ExportAssetKind
    ) async throws -> String {
        throw IllucetError.photosPermissionDenied
    }
}

struct ExportLifecycleTests {
    @Test
    func committedExportsSurvivePartialBackupCleanupFailure() async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.documents, withIntermediateDirectories: true)
        var items: [ExportFileTransactionItem] = []
        for index in 0..<2 {
            let source = try fixture.file(named: "source-\(index).mp4", bytes: Data("new-\(index)".utf8))
            items.append(ExportFileTransactionItem(sourceURL: source, filename: "Video-\(index)"))
            try Data("old-\(index)".utf8).write(to: fixture.documents.appending(path: "Video-\(index).mp4"))
        }
        let exporter = ExportManager(
            fileManager: PartiallyFailingBackupCleanupFileManager(),
            documentsRootURL: fixture.documents
        )
        let result = try await exporter.exportFileTransaction(
            items: items,
            destination: .appDocuments,
            folderBookmark: nil,
            duplicateHandling: [.overwrite, .overwrite],
            videoID: "fixture"
        )
        guard case let .committed(URLs) = result else {
            Issue.record("Verified outputs must remain committed after cleanup failure")
            return
        }
        #expect(URLs.count == 2)
        for (index, URL) in URLs.enumerated() {
            #expect(try Data(contentsOf: URL) == Data("new-\(index)".utf8))
        }
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.documents, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".illucet-export-transaction-") }
        let retained = try #require(leftovers.first)
        #expect(!FileManager.default.fileExists(atPath: retained.appending(path: "backups/0.backup").path))
        #expect(try Data(contentsOf: retained.appending(path: "backups/1.backup")) == Data("old-1".utf8))
    }

    @Test(arguments: [false, true])
    func failedFilesSubdirectoryResolutionReleasesSecurityScope(directoryExport: Bool) async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.documents, withIntermediateDirectories: true)
        let bookmark = try fixture.documents.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let scope = ExportScopeRecorder()
        let exporter = ExportManager(securityScope: scope.access)
        let source = try fixture.file(named: "source.mp4", bytes: Data("media".utf8))
        await #expect(throws: IllucetError.filesDestinationUnavailable) {
            if directoryExport {
                _ = try await exporter.exportDirectory(
                    sourceURL: fixture.root,
                    destination: .filesFolder,
                    filename: "Package",
                    folderBookmark: bookmark,
                    duplicateHandling: .addNumber,
                    videoID: "fixture",
                    relativeDirectory: "../invalid"
                )
            } else {
                _ = try await exporter.exportFileTransaction(
                    items: [ExportFileTransactionItem(sourceURL: source, filename: "Video")],
                    destination: .filesFolder,
                    folderBookmark: bookmark,
                    duplicateHandling: [.addNumber],
                    videoID: "fixture",
                    relativeDirectory: "../invalid"
                )
            }
        }
        #expect(scope.starts == 1)
        #expect(scope.stops == 1)
    }

    @Test
    func filesFolderDisplayIdentityPrefersUserVisiblePickerPath() {
        #expect(
            FilesFolderDisplayIdentity.resolve(
                userVisiblePathComponents: [
                    " On My iPhone ",
                    " VLC ",
                ],
                localizedName: "Documents",
                resourceName: "Documents",
                lastPathComponent: "Documents"
            ) == "VLC"
        )
        #expect(
            FilesFolderDisplayIdentity.resolve(
                userVisiblePathComponents: nil,
                localizedName: " VLC ",
                resourceName: "Documents",
                lastPathComponent: "Documents"
            ) == "VLC"
        )
        #expect(
            FilesFolderDisplayIdentity.resolve(
                userVisiblePathComponents: nil,
                localizedName: "  ",
                resourceName: " Documents ",
                lastPathComponent: "com.vendor.provider-root"
            ) == "Documents"
        )
        #expect(
            FilesFolderDisplayIdentity.resolve(
                userVisiblePathComponents: ["On My iPhone", "Documents"],
                localizedName: "Documents",
                resourceName: "Documents",
                lastPathComponent: "Documents"
            ) == "Documents"
        )
        #expect(
            FilesFolderDisplayIdentity.resolve(
                userVisiblePathComponents: [],
                localizedName: nil,
                resourceName: nil,
                lastPathComponent: " Provider Root "
            ) == "Provider Root"
        )
        #expect(
            FilesFolderDisplayIdentity.presentedName(
                alias: nil,
                resolved: "Documents"
            ) == "Documents"
        )
        #expect(
            FilesFolderDisplayIdentity.presentedName(
                alias: " VLC ",
                resolved: "Documents"
            ) == "VLC"
        )
        #expect(
            FilesFolderDisplayIdentity.presentedName(
                alias: " \n ",
                resolved: "VLC"
            ) == "VLC"
        )
        #expect(
            FilesFolderDisplayIdentity.shouldOfferAlias(
                for: " documents "
            )
        )
        #expect(
            !FilesFolderDisplayIdentity.shouldOfferAlias(for: "VLC")
        )
        #expect(
            FilesFolderDisplayIdentity.normalizedAlias(
                "  My\n  Media   Folder  "
            ) == "My Media Folder"
        )
        #expect(
            FilesFolderDisplayIdentity.normalizedAlias(
                String(
                    repeating: "A",
                    count: FilesFolderDisplayIdentity.maximumAliasLength + 5
                )
            )?.count == FilesFolderDisplayIdentity.maximumAliasLength
        )
        #expect(
            FilesFolderDisplayIdentity.representsSameFolder(
                URL(filePath: "/tmp/Illucet/../Illucet/Documents"),
                URL(filePath: "/tmp/Illucet/Documents")
            )
        )
    }

    @Test
    func filesFolderBookmarkRoundTripsAndRequiresWritableAccess() async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let folder = fixture.root.appending(
            path: "Selected Files",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        let selection = try await fixture.exporter.bookmarkSelection(
            for: folder
        )
        let access = try await fixture.exporter.testFolderAccessDetail(
            bookmark: selection.data
        )

        #expect(selection.displayName == "Selected Files")
        #expect(access.displayName == "Selected Files")
        #expect(
            access.folderURL.standardizedFileURL
                == folder.standardizedFileURL
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: folder.appending(path: ".illucet-access-test").path
            )
        )
    }

    @Test
    func resolvedFilesFolderSelectionPrefersPostBookmarkProviderIdentity() {
        let bookmarkData = Data("bookmark".utf8)
        let selection = FilesFolderBookmark(
            data: bookmarkData,
            displayName: "File Provider Storage"
        )
        let resolvedFolder = URL(
            filePath: "/provider/Documents",
            directoryHint: .isDirectory
        )
        let access = FilesFolderAccess(
            folderURL: resolvedFolder,
            displayName: "Documents"
        )

        let resolved = FilesFolderResolvedSelection(
            selection: selection,
            access: access
        )

        #expect(resolved.bookmarkData == bookmarkData)
        #expect(resolved.displayName == "Documents")
        #expect(
            resolved.selectionIdentity
                == FilesFolderDisplayIdentity.selectionIdentity(
                    for: resolvedFolder
                )
        )
        #expect(FilesFolderDisplayIdentity.shouldOfferAlias(
            for: resolved.displayName
        ))
    }

    @Test
    func invalidOrUnavailableFilesFolderBookmarksFailClosed() async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let folder = fixture.root.appending(
            path: "Revoked Files",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let bookmark = try await fixture.exporter.bookmark(for: folder)
        try FileManager.default.removeItem(at: folder)

        await #expect(throws: IllucetError.self) {
            _ = try await fixture.exporter.testFolderAccess(
                bookmark: bookmark
            )
        }
        await #expect(throws: IllucetError.self) {
            _ = try await fixture.exporter.testFolderAccess(
                bookmark: Data("not-a-bookmark".utf8)
            )
        }
    }

    @Test
    func photosCompatibilityIsRequiredOnlyForPhotosDestinations() throws {
        var configuration = DownloadConfiguration.standard
        configuration.mode = .audioOnly
        configuration.audioCodec = .mp3
        configuration.destination = .photos
        configuration = OutputCapabilityMatrix.normalized(configuration)
        FormatSelection.applyAutomaticSelection(
            to: &configuration,
            metadata: DeveloperFixtures.media
        )

        #expect(throws: IllucetError.self) {
            try OutputCapabilityMatrix.validate(
                configuration,
                metadata: DeveloperFixtures.media
            )
        }

        configuration.destination = .filesFolder
        try OutputCapabilityMatrix.validate(
            configuration,
            metadata: DeveloperFixtures.media
        )
    }

    @Test
    func shareUsesDurableStagingUntilActivityFinishes() async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let source = try fixture.file(
            named: "source.mp4",
            bytes: Data([0, 1, 2, 3])
        )
        let jobID = UUID()
        let exporter = fixture.exporter

        let result = try await exporter.export(
            sourceURL: source,
            destination: .share,
            filename: "Shared Output",
            folderBookmark: nil,
            duplicateHandling: .addNumber,
            videoID: "video-id",
            jobID: jobID,
            title: "Shared Output",
            assetKind: .video
        )
        let staged = try #require(result.fileURL)

        #expect(result.outcome == .sharePending)
        #expect(result.shareRequest?.fileURLs == [staged])
        #expect(FileManager.default.fileExists(atPath: staged.path))

        try FileManager.default.removeItem(at: source)
        #expect(FileManager.default.fileExists(atPath: staged.path))

        try await exporter.finishShare(jobID: jobID, state: .cancelled)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test
    func shareFailureKeepsStagedFileForRetry() async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let source = try fixture.file(
            named: "source.mp4",
            bytes: Data([0, 1, 2, 3])
        )
        let jobID = UUID()
        let result = try await fixture.exporter.export(
            sourceURL: source,
            destination: .share,
            filename: "Retry Me",
            folderBookmark: nil,
            duplicateHandling: .addNumber,
            videoID: "video-id",
            jobID: jobID,
            title: "Retry Me",
            assetKind: .video
        )
        let staged = try #require(result.fileURL)

        try await fixture.exporter.finishShare(
            jobID: jobID,
            state: .failed
        )
        let retry = await fixture.exporter.pendingShareRequest(
            jobID: jobID,
            title: "Retry Me"
        )

        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(retry?.fileURLs == [staged])
    }

    @Test
    func shareIncludesSeparateThumbnailInTheSameActivityRequest() async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let media = try fixture.file(
            named: "source.mp4",
            bytes: Data([0, 1, 2])
        )
        let thumbnail = try fixture.file(
            named: "thumbnail.jpg",
            bytes: Data([3, 4, 5])
        )
        let jobID = UUID()
        _ = try await fixture.exporter.export(
            sourceURL: media,
            destination: .share,
            filename: "Media",
            folderBookmark: nil,
            duplicateHandling: .addNumber,
            videoID: "video-id",
            jobID: jobID,
            title: "Media",
            assetKind: .video
        )
        let companion = try await fixture.exporter.exportCompanionImage(
            sourceURL: thumbnail,
            filename: "Media-thumbnail",
            destination: .share,
            mediaFileURL: nil,
            folderBookmark: nil,
            duplicateHandling: .addNumber,
            videoID: "video-id",
            jobID: jobID
        )

        #expect(companion.shareRequest?.fileURLs.count == 2)
        #expect(
            companion.shareRequest?.fileURLs.map(\.lastPathComponent)
                == ["Media-thumbnail.jpg", "Media.mp4"]
        )
    }

    @Test
    func photosOnlyReturnsAssetIdentifierAndNoTemporaryURL() async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let source = try fixture.file(
            named: "verified.mp4",
            bytes: Data([1, 2, 3])
        )

        let result = try await fixture.exporter.export(
            sourceURL: source,
            destination: .photos,
            filename: "Verified",
            folderBookmark: nil,
            duplicateHandling: .addNumber,
            videoID: "video-id",
            jobID: UUID(),
            title: "Verified",
            assetKind: .video
        )

        #expect(result.fileURL == nil)
        #expect(result.outcome == .photos)
        #expect(
            result.photoAssetLocalIdentifiers
                == ["fixture-video-verified.mp4"]
        )
    }

    @Test
    func photosOnlyHistoryNeverPointsAtDeletedTemporaryMedia() {
        var configuration = OutputCapabilityMatrix.normalized(
            DownloadConfiguration.standard
        )
        configuration.destination = .photos
        var job = DownloadJob(
            id: UUID(),
            sourceURL: DeveloperFixtures.RickURL,
            videoID: DeveloperFixtures.media.videoID,
            title: DeveloperFixtures.media.title,
            channel: DeveloperFixtures.media.channel,
            thumbnailURL: DeveloperFixtures.media.thumbnails.first?.url,
            createdAt: .now,
            updatedAt: .now,
            configuration: configuration,
            state: .completed,
            stage: .complete,
            progress: .zero,
            priority: 0,
            retryCount: 0,
            maximumRetries: 2,
            errorCode: nil,
            errorMessage: nil,
            outputURL: nil,
            outputProbe: nil,
            selectedFormatIDs: ["137", "140"],
            extractorVersion: "fixture"
        )
        job.exportOutcome = .photos
        job.photosAssetLocalIdentifiers = ["fixture-photo-id"]

        let record = HistoryRecord(job: job)

        #expect(record.fileURL == nil)
        #expect(record.savedToPhotos)
        #expect(record.exportOutcome == .photos)
        #expect(
            record.photosAssetLocalIdentifiers == ["fixture-photo-id"]
        )
    }

    @Test
    func filesAndPhotosKeepsFileAndRecordsPhotoAsset() async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let source = try fixture.file(
            named: "verified.mp4",
            bytes: Data([1, 2, 3])
        )
        let folder = fixture.root.appending(
            path: "Files",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let bookmark = try await fixture.exporter.bookmark(for: folder)

        let result = try await fixture.exporter.export(
            sourceURL: source,
            destination: .filesAndPhotos,
            filename: "Kept",
            folderBookmark: bookmark,
            duplicateHandling: .addNumber,
            videoID: "video-id",
            jobID: UUID(),
            title: "Kept",
            assetKind: .video
        )

        let file = try #require(result.fileURL)
        #expect(result.outcome == .filesAndPhotos)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(result.photoAssetLocalIdentifiers.count == 1)
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))

        let thumbnail = try fixture.file(
            named: "thumbnail.png",
            bytes: Data([4, 5, 6])
        )
        let companion = try await fixture.exporter.exportCompanionImage(
            sourceURL: thumbnail,
            filename: "Kept-thumbnail",
            destination: .filesAndPhotos,
            mediaFileURL: file,
            folderBookmark: bookmark,
            duplicateHandling: .addNumber,
            videoID: "video-id",
            jobID: UUID()
        )
        let companionFile = try #require(companion.fileURL)
        #expect(
            companionFile.lastPathComponent == "Kept-thumbnail.png"
        )
        #expect(try Data(contentsOf: companionFile) == Data([4, 5, 6]))
        #expect(companion.photoAssetLocalIdentifiers.count == 1)
    }

    @Test
    func filesAndPhotosFailureStillPublishesTheFilesCopy() async throws {
        let fixture = try FixtureDirectory(
            photoLibrary: FailingPhotoLibrary()
        )
        defer { fixture.remove() }
        let source = try fixture.file(
            named: "verified.mp4",
            bytes: Data([1, 2, 3])
        )
        let folder = fixture.root.appending(
            path: "Files",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let bookmark = try await fixture.exporter.bookmark(for: folder)

        do {
            _ = try await fixture.exporter.export(
                sourceURL: source,
                destination: .filesAndPhotos,
                filename: "Partial Success",
                folderBookmark: bookmark,
                duplicateHandling: .addNumber,
                videoID: "video-id",
                jobID: UUID(),
                title: "Partial Success",
                assetKind: .video
            )
            Issue.record("Files + Photos unexpectedly reported full success")
        } catch let error as ExportError {
            guard case let .filesSavedPhotosFailed(fileURL, reason) = error
            else {
                Issue.record("Unexpected export error: \(error)")
                return
            }
            #expect(
                fileURL.lastPathComponent == "Partial Success.mp4"
            )
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
            #expect(try Data(contentsOf: fileURL) == Data([1, 2, 3]))
            #expect(reason.contains("Photos"))
        }
    }

    @Test
    func duplicateAskIsExplicitAndSkipIsSuccessful() async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let source = try fixture.file(
            named: "source.mp4",
            bytes: Data([9])
        )
        let existing = fixture.documents.appending(path: "Existing.mp4")
        try FileManager.default.createDirectory(
            at: fixture.documents,
            withIntermediateDirectories: true
        )
        try Data([7]).write(to: existing)

        let preflight = try await fixture.exporter.preflight(
            destination: .appDocuments,
            filename: "Existing",
            fileExtension: "mp4",
            folderBookmark: nil
        )
        #expect(preflight.hasCollision)
        #expect(preflight.desiredURL == existing)

        await #expect(throws: ExportError.self) {
            _ = try await fixture.exporter.export(
                sourceURL: source,
                destination: .appDocuments,
                filename: "Existing",
                folderBookmark: nil,
                duplicateHandling: .ask,
                videoID: "real-video-id",
                jobID: UUID(),
                title: "Existing",
                assetKind: .video
            )
        }

        let skipped = try await fixture.exporter.export(
            sourceURL: source,
            destination: .appDocuments,
            filename: "Existing",
            folderBookmark: nil,
            duplicateHandling: .skip,
            videoID: "real-video-id",
            jobID: UUID(),
            title: "Existing",
            assetKind: .video
        )
        #expect(skipped.outcome == .duplicateSkipped)
        #expect(skipped.fileURL == nil)
        #expect(try Data(contentsOf: existing) == Data([7]))
    }

    @Test
    func addVideoIDUsesTheActualMediaIdentifier() async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let source = try fixture.file(
            named: "source.mp4",
            bytes: Data([9])
        )
        try FileManager.default.createDirectory(
            at: fixture.documents,
            withIntermediateDirectories: true
        )
        try Data([7]).write(
            to: fixture.documents.appending(path: "Existing.mp4")
        )

        let result = try await fixture.exporter.export(
            sourceURL: source,
            destination: .appDocuments,
            filename: "Existing",
            folderBookmark: nil,
            duplicateHandling: .addVideoID,
            videoID: "dQw4w9WgXcQ",
            jobID: UUID(),
            title: "Existing",
            assetKind: .video
        )

        #expect(
            result.fileURL?.lastPathComponent
                == "Existing-dQw4w9WgXcQ.mp4"
        )
    }

    @Test
    func overwritePublishesReplacementWithoutLeavingAPartial() async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let source = try fixture.file(
            named: "source.mp4",
            bytes: Data([9, 8, 7])
        )
        try FileManager.default.createDirectory(
            at: fixture.documents,
            withIntermediateDirectories: true
        )
        let existing = fixture.documents.appending(path: "Existing.mp4")
        try Data([1, 2, 3]).write(to: existing)

        let result = try await fixture.exporter.export(
            sourceURL: source,
            destination: .appDocuments,
            filename: "Existing",
            folderBookmark: nil,
            duplicateHandling: .overwrite,
            videoID: "video-id",
            jobID: UUID(),
            title: "Existing",
            assetKind: .video
        )

        #expect(result.fileURL == existing)
        #expect(try Data(contentsOf: existing) == Data([9, 8, 7]))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.documents,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "partial" }
        #expect(leftovers.isEmpty)
    }

    @Test
    func playlistQueueItemsCarryDuplicateContextIndependently() {
        var configuration = OutputCapabilityMatrix.normalized(
            DownloadConfiguration.standard
        )
        configuration.playlistBehavior = .referencedVideo
        let job = DownloadJob(
            id: UUID(),
            sourceURL: DeveloperFixtures.RickURL,
            videoID: "child-video-id",
            title: "Playlist child",
            channel: "Fixture",
            thumbnailURL: nil,
            createdAt: .now,
            updatedAt: .now,
            configuration: configuration,
            state: .queued,
            stage: .waiting,
            progress: .zero,
            priority: 0,
            retryCount: 0,
            maximumRetries: 2,
            errorCode: nil,
            errorMessage: nil,
            outputURL: nil,
            outputProbe: nil,
            selectedFormatIDs: ["137", "140"],
            extractorVersion: "fixture",
            playlistItemID: "playlist-index-004"
        )
        let desired = URL(filePath: "/tmp/Playlist child.mp4")
        let conflict = DuplicateConflict(
            job: job,
            desiredURL: desired
        )

        #expect(conflict.videoID == "child-video-id")
        #expect(conflict.playlistItemID == "playlist-index-004")
        #expect(conflict.desiredURL == desired)
    }

    @Test
    func thumbnailOnlyNeedsNoMediaFormats() throws {
        var configuration = DownloadConfiguration.standard
        configuration.thumbnailBehavior = .thumbnailOnly
        configuration.selectedVideoFormatID = nil
        configuration.selectedAudioFormatID = nil
        configuration.thumbnailFormat = .original
        configuration = OutputCapabilityMatrix.normalized(configuration)

        try OutputCapabilityMatrix.validate(
            configuration,
            metadata: DeveloperFixtures.media
        )
    }

    @Test(arguments: ThumbnailService.supportedOutputFormats)
    @MainActor
    func writesEachSupportedThumbnailFormat(
        format: ThumbnailFormatChoice
    ) async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let service = ThumbnailService()
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 24, height: 16)
        ).image { context in
            UIColor.systemBlue.setFill()
            context.fill(
                CGRect(x: 0, y: 0, width: 24, height: 16)
            )
        }
        let PNG = try #require(image.pngData())
        let output = try await service.write(
            PNG,
            to: fixture.root.appending(
                path: "thumbnail-\(format.id)"
            ),
            outputFormat: format,
            cropSquare: true
        )
        #expect(FileManager.default.fileExists(atPath: output.path))
        let data = try Data(contentsOf: output)
        #expect(
            CGImageSourceCreateWithData(data as CFData, nil) != nil
        )
        let source = try #require(
            CGImageSourceCreateWithData(data as CFData, nil)
        )
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        )
        #expect(
            properties[kCGImagePropertyPixelWidth] as? Int
                == properties[kCGImagePropertyPixelHeight] as? Int
        )
        switch format {
        case .original, .png:
            #expect(output.pathExtension == "png")
        case .jpeg:
            #expect(["jpg", "jpeg"].contains(output.pathExtension))
        case .webp:
            #expect(output.pathExtension == "webp")
        }
    }

    @Test
    @MainActor
    func originalThumbnailPreservesBytesAndRealExtension() async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 20, height: 12)
        ).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 12))
        }
        let PNG = try #require(image.pngData())

        let output = try await ThumbnailService().write(
            PNG,
            to: fixture.root.appending(path: "original.wrong"),
            outputFormat: .original,
            cropSquare: false
        )

        #expect(output.pathExtension == "png")
        #expect(try Data(contentsOf: output) == PNG)
    }

    @Test
    func automaticThumbnailFallsBackAfterHTTP200NonImage() async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        ThumbnailFallbackURLProtocol.configure(
            responses: [
                "/largest": .init(
                    statusCode: 200,
                    data: Data("<html>not an image</html>".utf8)
                ),
                "/fallback": .init(
                    statusCode: 200,
                    data: ThumbnailFallbackURLProtocol.validPNG
                ),
            ]
        )
        defer { ThumbnailFallbackURLProtocol.reset() }

        let output = try await ThumbnailFallbackURLProtocol.service().download(
            from: [
                MediaThumbnail(
                    url: URL(string: "https://thumbnail.test/fallback")!,
                    width: 160,
                    height: 90,
                    id: "fallback"
                ),
                MediaThumbnail(
                    url: URL(string: "https://thumbnail.test/largest")!,
                    width: 1_280,
                    height: 720,
                    id: "largest"
                ),
            ],
            selectedID: nil,
            to: fixture.root.appending(path: "automatic"),
            outputFormat: .original,
            cropSquare: false
        )

        #expect(
            ThumbnailFallbackURLProtocol.requestedPaths
                == ["/largest", "/fallback"]
        )
        #expect(
            try Data(contentsOf: output)
                == ThumbnailFallbackURLProtocol.validPNG
        )
        #expect(output.pathExtension == "png")
    }

    @Test
    func automaticThumbnailFailureExhaustsCandidatesInOrder() async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        ThumbnailFallbackURLProtocol.configure(
            responses: [
                "/large-invalid": .init(
                    statusCode: 200,
                    data: Data("not-image".utf8)
                ),
                "/small-failed": .init(
                    statusCode: 503,
                    data: Data()
                ),
            ]
        )
        defer { ThumbnailFallbackURLProtocol.reset() }

        await #expect(throws: ThumbnailError.self) {
            _ = try await ThumbnailFallbackURLProtocol.service().download(
                from: [
                    MediaThumbnail(
                        url: URL(
                            string: "https://thumbnail.test/small-failed"
                        )!,
                        width: 320,
                        height: 180,
                        id: "small"
                    ),
                    MediaThumbnail(
                        url: URL(
                            string: "https://thumbnail.test/large-invalid"
                        )!,
                        width: 640,
                        height: 360,
                        id: "large"
                    ),
                ],
                selectedID: nil,
                to: fixture.root.appending(path: "exhausted"),
                outputFormat: .original,
                cropSquare: false
            )
        }
        #expect(
            ThumbnailFallbackURLProtocol.requestedPaths
                == ["/large-invalid", "/small-failed"]
        )
    }

    @Test
    func selectedThumbnailFailureDoesNotSwitchIdentity() async throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        ThumbnailFallbackURLProtocol.configure(
            responses: [
                "/selected": .init(
                    statusCode: 200,
                    data: Data("selected-is-not-an-image".utf8)
                ),
                "/other": .init(
                    statusCode: 200,
                    data: ThumbnailFallbackURLProtocol.validPNG
                ),
            ]
        )
        defer { ThumbnailFallbackURLProtocol.reset() }

        await #expect(throws: ThumbnailError.self) {
            _ = try await ThumbnailFallbackURLProtocol.service().download(
                from: [
                    MediaThumbnail(
                        url: URL(string: "https://thumbnail.test/other")!,
                        width: 1_280,
                        height: 720,
                        id: "other"
                    ),
                    MediaThumbnail(
                        url: URL(string: "https://thumbnail.test/selected")!,
                        width: 320,
                        height: 180,
                        id: "selected"
                    ),
                ],
                selectedID: "selected",
                to: fixture.root.appending(path: "selected"),
                outputFormat: .original,
                cropSquare: false
            )
        }
        #expect(ThumbnailFallbackURLProtocol.requestedPaths == ["/selected"])
    }
}

private final class ThumbnailFallbackURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    struct Response: Sendable {
        let statusCode: Int
        let data: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Response] = [:]
    nonisolated(unsafe) private static var paths: [String] = []

    static let validPNG = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    static var requestedPaths: [String] {
        lock.withLock { paths }
    }

    static func configure(responses: [String: Response]) {
        lock.withLock {
            self.responses = responses
            paths = []
        }
    }

    static func reset() {
        lock.withLock {
            responses = [:]
            paths = []
        }
    }

    static func service() -> ThumbnailService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThumbnailFallbackURLProtocol.self]
        return ThumbnailService(
            session: URLSession(configuration: configuration)
        )
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "thumbnail.test"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let response = Self.lock.withLock { () -> Response? in
            Self.paths.append(path)
            return Self.responses[path]
        }
        guard
            let response,
            let URL = request.url,
            let HTTP = HTTPURLResponse(
                url: URL,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "\(response.data.count)",
                    "Content-Type": "image/png",
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
            didReceive: HTTP,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct FixtureDirectory {
    let root: URL
    let documents: URL
    let shares: URL
    let exporter: ExportManager

    init(
        photoLibrary: any PhotoLibraryExporting = FixturePhotoLibrary()
    ) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part2-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        documents = root.appending(
            path: "Documents",
            directoryHint: .isDirectory
        )
        shares = root.appending(
            path: "Shares",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        exporter = ExportManager(
            photoLibrary: photoLibrary,
            documentsRootURL: documents,
            shareRootURL: shares
        )
    }

    func file(named name: String, bytes: Data) throws -> URL {
        let URL = root.appending(path: name)
        try bytes.write(to: URL)
        return URL
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class PartiallyFailingBackupCleanupFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        if URL.lastPathComponent.hasPrefix(".illucet-export-transaction-") {
            // Model a provider deleting one backup before recursive cleanup fails.
            try super.removeItem(at: URL.appending(path: "backups/0.backup"))
            throw CocoaError(.fileWriteUnknown)
        }
        try super.removeItem(at: URL)
    }
}

private final class ExportScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var stopCount = 0

    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }
    var access: ExportSecurityScope {
        ExportSecurityScope(
            startAccessing: { [self] _ in
                lock.withLock { startCount += 1 }
                return true
            },
            stopAccessing: { [self] _ in
                lock.withLock { stopCount += 1 }
            }
        )
    }
}
