import Foundation
import Testing
@testable import Illucet

@Suite("P10.6 HLS AES-128 playlist parsing")
struct HLSAES128PlaylistParserTests {
    @Test
    func preservesKeyRotationNoneExplicitIVAndDerivedSequenceIV() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:5
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:42
        #EXT-X-KEY:METHOD=AES-128,URI="key-a.bin",IV=0x000102030405060708090A0B0C0D0E0F,KEYFORMAT="identity"
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6,
        one.m4s
        #EXT-X-KEY:METHOD=AES-128,URI="key-b.bin"
        #EXTINF:6,
        two.m4s
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:6,
        three.m4s
        #EXT-X-ENDLIST
        """
        let document = try HLSPlaylistParser.parse(
            Data(playlist.utf8),
            finalPlaylistURL: mediaURL
        )
        guard case let .media(plan) = document else {
            Issue.record("Expected a media playlist.")
            return
        }
        let resources = plan.events.compactMap(\.resource)
        let explicitIV = Data(Array(0...15).map(UInt8.init))
        let derivedIV = Data(
            [UInt8](repeating: 0, count: 15) + [43]
        )

        #expect(resources.count == 4)
        #expect(resources.map(\.mediaSequence) == [nil, 42, 43, 44])
        #expect(resources[0].kind == .initialization)
        #expect(
            resources[0].encryption?.keyURL.absoluteString
                == "https://manifest.googlevideo.com/hls/key-a.bin"
        )
        #expect(resources[0].encryption?.initializationVector == explicitIV)
        #expect(
            resources[0].encryption?.initializationVectorSource == .explicit
        )
        #expect(resources[1].encryption == resources[0].encryption)
        #expect(
            resources[2].encryption?.keyURL.absoluteString
                == "https://manifest.googlevideo.com/hls/key-b.bin"
        )
        #expect(resources[2].encryption?.initializationVector == derivedIV)
        #expect(
            resources[2].encryption?.initializationVectorSource
                == .mediaSequence
        )
        #expect(resources[3].encryption == nil)
    }

    @Test
    func acceptsUppercaseHexPrefixWithVersionedIdentityKeyFormat() throws {
        let playlist = encryptionPlaylist(
            version: 5,
            key:
                "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0X1,KEYFORMAT=\"identity\""
        )
        let document = try HLSPlaylistParser.parse(
            Data(playlist.utf8),
            finalPlaylistURL: mediaURL
        )
        guard
            case let .media(plan) = document,
            let resource = plan.events.compactMap(\.resource).first,
            let encryption = resource.encryption
        else {
            Issue.record("Expected one encrypted media resource.")
            return
        }

        #expect(
            encryption.keyURL.absoluteString
                == "https://manifest.googlevideo.com/hls/key.bin"
        )
        #expect(
            encryption.initializationVector
                == Data([UInt8](repeating: 0, count: 15) + [1])
        )
        #expect(encryption.initializationVectorSource == .explicit)
    }

    @Test
    func derivesDefaultAndMaximumMediaSequenceIVsOverflowSafely() throws {
        let defaultSequencePlaylist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:6,
        zero.ts
        #EXTINF:6,
        one.ts
        #EXT-X-ENDLIST
        """
        let document = try HLSPlaylistParser.parse(
            Data(defaultSequencePlaylist.utf8),
            finalPlaylistURL: mediaURL
        )
        guard case let .media(plan) = document else {
            Issue.record("Expected a media playlist.")
            return
        }
        let resources = plan.events.compactMap(\.resource)
        #expect(resources.map(\.mediaSequence) == [0, 1])
        #expect(
            resources[0].encryption?.initializationVector
                == Data(repeating: 0, count: 16)
        )
        #expect(
            resources[1].encryption?.initializationVector
                == Data([UInt8](repeating: 0, count: 15) + [1])
        )

        let overflow = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:18446744073709551615
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:6,
        max.ts
        #EXTINF:6,
        overflow.ts
        #EXT-X-ENDLIST
        """
        #expect(throws: HLSPlaylistParsingError.invalidMediaSequence) {
            _ = try HLSPlaylistParser.parse(
                Data(overflow.utf8),
                finalPlaylistURL: mediaURL
            )
        }
    }

    @Test
    func rejectsInvalidEncryptionLexemesAndLowCompatibilityVersions() {
        let explicitIV = "0x00000000000000000000000000000001"
        let invalid: [(String, HLSPlaylistParsingError)] = [
            (
                encryptionPlaylist(
                    version: 2,
                    key:
                        "#EXT-X-KEY:METHOD=\"AES-128\",URI=\"key.bin\",IV=\(explicitIV)"
                ),
                .malformedEncryption
            ),
            (
                encryptionPlaylist(
                    key: "#EXT-X-KEY:METHOD=AES-128,URI=key.bin"
                ),
                .malformedEncryption
            ),
            (
                encryptionPlaylist(
                    version: 2,
                    key:
                        "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=\"\(explicitIV)\""
                ),
                .malformedEncryption
            ),
            (
                encryptionPlaylist(
                    version: 2,
                    key:
                        "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x0000000000000000000000000000000G"
                ),
                .invalidInitializationVector
            ),
            (
                encryptionPlaylist(
                    key:
                        "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=\(explicitIV)"
                ),
                .incompatibleEncryptionVersion
            ),
            (
                encryptionPlaylist(
                    version: 1,
                    key:
                        "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=\(explicitIV)"
                ),
                .incompatibleEncryptionVersion
            ),
            (
                encryptionPlaylist(
                    key:
                        "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",KEYFORMAT=\"identity\""
                ),
                .incompatibleEncryptionVersion
            ),
            (
                encryptionPlaylist(
                    version: 4,
                    key:
                        "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",KEYFORMAT=\"identity\""
                ),
                .incompatibleEncryptionVersion
            ),
            (
                encryptionPlaylist(
                    version: 5,
                    key:
                        "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",KEYFORMAT=identity"
                ),
                .malformedEncryption
            ),
            (
                encryptionPlaylist(
                    version: 5,
                    key:
                        "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",KEYFORMAT=\"identity\",KEYFORMATVERSIONS=\"1\""
                ),
                .malformedEncryption
            ),
        ]

        for (playlist, expected) in invalid {
            do {
                _ = try HLSPlaylistParser.parse(
                    Data(playlist.utf8),
                    finalPlaylistURL: mediaURL
                )
                Issue.record("Invalid encryption grammar unexpectedly parsed.")
            } catch let error as HLSPlaylistParsingError {
                #expect(error == expected)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test
    func rejectsAmbiguousEncryptionDRMUnsafeKeysAndEncryptedRanges() {
        let invalid: [(String, HLSPlaylistParsingError)] = [
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6,\none.ts\n#EXT-X-ENDLIST\n",
                .encryptedInitializationRequiresExplicitIV
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:6,\n#EXT-X-BYTERANGE:16@0\none.ts\n#EXT-X-ENDLIST\n",
                .encryptedByteRangeUnsupported
            ),
            (
                "#EXTM3U\n#EXT-X-VERSION:2\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x00000000000000000000000000000001\n#EXT-X-MAP:URI=\"init.mp4\",BYTERANGE=\"16@0\"\n#EXTINF:6,\none.ts\n#EXT-X-ENDLIST\n",
                .encryptedByteRangeUnsupported
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key.bin\"\n#EXTINF:6,\none.ts\n#EXT-X-ENDLIST\n",
                .encryptionUnsupported
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,URI=\"key.bin\"\n#EXTINF:6,\none.ts\n#EXT-X-ENDLIST\n",
                .encryptionUnsupported
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",KEYFORMAT=\"com.apple.streamingkeydelivery\"\n#EXTINF:6,\none.ts\n#EXT-X-ENDLIST\n",
                .nonIdentityKeyFormatUnsupported
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI=\"skd://license.example/key\"\n#EXTINF:6,\none.ts\n#EXT-X-ENDLIST\n",
                .unsafeURI
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI=\"http://manifest.googlevideo.com/key\"\n#EXTINF:6,\none.ts\n#EXT-X-ENDLIST\n",
                .unsafeURI
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128\n#EXTINF:6,\none.ts\n#EXT-X-ENDLIST\n",
                .malformedEncryption
            ),
            (
                "#EXTM3U\n#EXT-X-VERSION:2\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x100000000000000000000000000000000\n#EXTINF:6,\none.ts\n#EXT-X-ENDLIST\n",
                .invalidInitializationVector
            ),
            (
                "#EXTM3U\n#EXT-X-VERSION:2\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x0000000000000000000000000000000a\n#EXTINF:6,\none.ts\n#EXT-X-ENDLIST\n",
                .invalidInitializationVector
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=NONE,URI=\"key.bin\"\n#EXTINF:6,\none.ts\n#EXT-X-ENDLIST\n",
                .malformedEncryption
            ),
            (
                "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:6,\none.ts\n#EXT-X-ENDLIST\n",
                .sessionKeyUnsupported
            ),
        ]

        for (playlist, expected) in invalid {
            do {
                _ = try HLSPlaylistParser.parse(
                    Data(playlist.utf8),
                    finalPlaylistURL: mediaURL
                )
                Issue.record("Rejected encrypted playlist unexpectedly parsed.")
            } catch let error as HLSPlaylistParsingError {
                #expect(error == expected)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    private func encryptionPlaylist(
        version: Int? = nil,
        key: String
    ) -> String {
        [
            "#EXTM3U",
            version.map { "#EXT-X-VERSION:\($0)" },
            "#EXT-X-TARGETDURATION:6",
            key,
            "#EXTINF:6,",
            "one.ts",
            "#EXT-X-ENDLIST",
        ].compactMap { $0 }.joined(separator: "\n") + "\n"
    }

    private var mediaURL: URL {
        URL(
            string: "https://manifest.googlevideo.com/hls/media.m3u8"
        )!
    }
}
