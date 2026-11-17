import Foundation
import CryptoKit
import ImageIO
import Testing
import UniformTypeIdentifiers
import UIKit
@testable import Illucet

@Suite("Multi-site import and identity")
struct BulkImportTests {
    @Test func imageContentIdentityRejectsChangedDownloadBytes() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ContentIdentity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let original = Data("original photo bytes".utf8)
        try original.write(to: file)
        let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        try NativeImageProcessor.verifyContent(file, expectedSHA256: digest)
        try Data("different photo bytes".utf8).write(to: file)
        #expect(throws: (any Error).self) { try NativeImageProcessor.verifyContent(file, expectedSHA256: digest) }
    }

    @Test func imageIdentityProbeRejectsNonServiceDestinations() async {
        for url in ["http://p16.tiktokcdn.com/a", "https://127.0.0.1/a", "https://tiktokcdn.com.evil.example/a", "https://user:secret@p16.tiktokcdn.com/a"] {
            await #expect(throws: (any Error).self) { try await NativeImageProcessor.contentFingerprint(url, maximumBytes: 1024) }
        }
    }
    @Test func automaticFallbackDoesNotRetryAuthenticationOrCancellation() {
        #expect(DownloadPipelineRunner.permitsEngineFallback(StreamDownloadError.invalidPartialContent))
        #expect(!DownloadPipelineRunner.permitsEngineFallback(StreamDownloadError.forbiddenHTTPFailure(statusCode:403)))
        #expect(!DownloadPipelineRunner.permitsEngineFallback(StreamDownloadError.transientHTTPFailure(statusCode:429)))
        #expect(!DownloadPipelineRunner.permitsEngineFallback(CancellationError()))
    }
    @Test func findsMixedLinksAndDeduplicatesCanonicalYouTubeIdentity() throws {
        let links = try BulkLinkImport.links(in: "Notes:\n(https://youtu.be/dQw4w9WgXcQ).\nhttps://www.youtube.com/watch?v=dQw4w9WgXcQ&utm_source=note\nhttps://x.com/example/status/123?utm_source=notes\nhttps://example.com/article")
        #expect(links.count == 4)
        #expect(links.filter(\.selected).count == 2)
        #expect(links[1].duplicate)
        #expect(links[2].url.absoluteString == "https://x.com/example/status/123")
        #expect(links[3].site == nil)
    }
    @Test func limitsAndUntrustedSchemesAreExplicit() throws {
        #expect(throws: BulkImportError.self) { try BulkLinkImport.links(in: String(repeating: "x", count: BulkLinkImport.maximumBytes + 1)) }
        #expect(throws: BulkImportError.self) { try BulkLinkImport.links(in: (0...500).map { "https://vimeo.com/\($0)" }.joined(separator: "\n")) }
        #expect(MediaSite.recognize(URL(string:"https://instagram.com.evil.example/p/id")!) == nil)
        #expect(MediaSite.recognize(URL(string:"https://user:secret@x.com/a/status/123")!) == nil)
        #expect(MediaSite.recognize(URL(string:"file:///tmp/media")!) == nil)
    }
    @Test func richTextImportFindsNamedHyperlinks() throws {
        let url = try #require(URL(string: "https://x.com/example/status/123"))
        let note = NSAttributedString(string: "A clip to save", attributes: [.link: url])
        let rtf = try note.data(from: NSRange(location: 0, length: note.length),
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let links = try BulkLinkImport.links(in: BulkLinkImport.text(from: rtf, fileExtension: "rtf"))
        #expect(links.filter(\.selected).map(\.url) == [url])
    }
    @Test func originalImageIsAdmittedWithoutAVFormatSelections() throws {
        let metadata = try #require(DeveloperFixtures.externalAssets.first { $0.sourceIdentity?.kind == .image })
        var configuration = DownloadConfiguration.standard
        configuration.sourceIdentity = metadata.sourceIdentity
        configuration.assetFingerprint = metadata.assetFingerprint
        try OutputCapabilityMatrix.validate(configuration, metadata: metadata)
        #expect(configuration.selectedFormatIDs == [DownloadConfiguration.originalImageFormatID])
        configuration.selectedVideoFormatID = "another-format"
        #expect(throws: OutputCompatibilityError.self) { try OutputCapabilityMatrix.validate(configuration, metadata: metadata) }
    }
    @Test func legacySettingsAndMetadataDecodeWithoutNewFields() throws {
        let encoder = JSONEncoder()
        let settings = try JSONDecoder().decode(AppSettings.self, from: encoder.encode(AppSettings.defaults))
        #expect(settings.engines == nil)
        let metadata = try JSONDecoder().decode(MediaMetadata.self, from: encoder.encode(DeveloperFixtures.media))
        #expect(metadata.sourceIdentity == nil)
        #expect(metadata == DeveloperFixtures.media)
    }
    @Test func siteScopedCookiesCannotCrossAccounts() throws {
        let cookie = YouTubeAccountCookie(domain: ".instagram.com", path: "/", name: "sessionid", value: "synthetic", secure: true, expires: nil)
        #expect(try YouTubeAccountCookie.validated([cookie], site: .instagram).count == 1)
        #expect(throws: AccountError.self) { try YouTubeAccountCookie.validated([cookie], site: .x) }
        #expect(throws: AccountError.self) { try YouTubeAccountCookie.validated([cookie]) }
    }
    @Test func ephemeralSourceCannotEncodeAndRejectsIdentityMismatch() throws {
        let identity = MediaSourceIdentity(site:.x,postID:"1",assetID:"2",kind:.video)
        let source = ExternalResolvedAsset(identity:identity,formatID:"v1",url:URL(string:"https://cdn.example.com/v.mp4?token=secret")!,headers:[:],fileExtension:"mp4",protocolName:"https",hasVideo:true,hasAudio:true,expectedBytes:20)
        try source.validate(identity:identity,formatID:"v1")
        #expect(throws: StreamResolutionError.self) { try source.validate(identity:.init(site:.instagram,postID:"1",assetID:"2",kind:.video),formatID:"v1") }
        #expect(throws: StreamResolutionError.self) { try source.validate(identity:identity,formatID:"other") }
    }
    @Test func preferenceBackupOmitsDeviceAccountBindings() throws {
        var settings=AppSettings.defaults
        settings.siteDefaults=["instagram":.init(accountID:UUID())]
        let backup=PreferencesBackup(settings:settings,presets:[])
        #expect(backup.settings.siteDefaults?["instagram"]?.accountID == nil)
    }
    @Test func accountPreferencesInheritGeneralEngineUntilOverridden() throws {
        var settings = AppSettings.defaults
        settings.engines = .init(download: .ytDLP)
        settings.siteDefaults = ["instagram": .init(accountID: UUID())]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.extractionPreferences(for: .instagram).download == .ytDLP)
        settings.siteDefaults?["instagram"]?.engine = .automatic
        #expect(settings.extractionPreferences(for: .instagram).download == .automatic)
    }
    @Test func imagePrivacyCopyStripsGPSWithoutChangingDimensions() throws {
        let root=FileManager.default.temporaryDirectory.appending(path:"ImagePrivacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let original=root.appending(path:"original.jpg")
        let colorSpace=CGColorSpaceCreateDeviceRGB()
        let context=try #require(CGContext(data:nil,width:4,height:3,bitsPerComponent:8,bytesPerRow:16,space:colorSpace,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
        let image=try #require(context.makeImage())
        let destination=try #require(CGImageDestinationCreateWithURL(original as CFURL,UTType.jpeg.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,[kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:40.0,kCGImagePropertyGPSLongitude:70.0]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let output=try NativeImageProcessor.prepare(original,removeMetadata:true,directory:root)
        let source=try NativeImageProcessor.verify(output)
        let properties=try #require(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 4)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 3)
    }
}
