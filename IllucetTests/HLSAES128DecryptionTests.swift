import Foundation
import Testing
@testable import Illucet

@Suite("P10.6 HLS AES-128 key loading and decryption")
struct HLSAES128DecryptionTests {
    @Test
    func keyLoaderAcceptsOneExactBoundedKeyAndSecureRedirect() async throws {
        let initialURL = URL(
            string: "https://manifest.googlevideo.com/hls/key-start.bin"
        )!
        let finalURL = URL(
            string: "https://manifest.googlevideo.com/hls/key-final.bin"
        )!
        let key = Data(Array(0...15).map(UInt8.init))
        let networking = FixtureHLSKeyNetworking(responses: [
            initialURL.absoluteString: [
                HLSPlaylistHTTPResponse(
                    statusCode: 302,
                    headers: ["Location": finalURL.absoluteString],
                    body: Data()
                ),
            ],
            finalURL.absoluteString: [
                HLSPlaylistHTTPResponse(
                    statusCode: 200,
                    headers: [
                        "Content-Length": "16",
                        "Content-Encoding": "identity",
                    ],
                    body: key
                ),
            ],
        ])
        let loader = URLSessionHLSAES128KeyLoader(networking: networking)

        let result = try await loader.loadKey(
            from: initialURL,
            HTTPHeaders: ["User-Agent": "Illucet-HLS-Test"],
            networkPolicy: StreamTransferNetworkPolicy(
                allowsExpensiveAccess: false,
                allowsConstrainedAccess: false
            ),
            maximumRedirects: 2
        )

        #expect(result == HLSAES128KeyLoadResult(key: key, redirectCount: 1))
        let requests = await networking.recordedRequests()
        #expect(requests.compactMap(\.url) == [initialURL, finalURL])
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.allSatisfy { !$0.httpShouldHandleCookies })
        #expect(
            requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Accept-Encoding") == "identity"
            }
        )
        #expect(requests.allSatisfy { !$0.allowsExpensiveNetworkAccess })
        #expect(requests.allSatisfy { !$0.allowsConstrainedNetworkAccess })
    }

    @Test
    func keyLoaderPreservesHTTPRetryAndNetworkClassifications() async throws {
        let keyURL = URL(string: "https://manifest.googlevideo.com/hls/key.bin")!
        let policy = DownloadRetryPolicy()
        for status in [401, 403, 404, 410, 429, 500, 503] {
            let networking = FixtureHLSKeyNetworking(responses: [
                keyURL.absoluteString: [
                    HLSPlaylistHTTPResponse(statusCode: status, headers: [:], body: Data()),
                ],
            ])
            await #expect(throws: StreamDownloadError.HTTPFailure(statusCode: status)) {
                _ = try await URLSessionHLSAES128KeyLoader(networking: networking)
                    .loadKey(from: keyURL, HTTPHeaders: [:], networkPolicy: .unrestricted, maximumRedirects: 0)
            }
        }
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .cancelled] {
            let networking = FixtureHLSKeyNetworking(
                responses: [:],
                forcedError: URLError(code, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://secret.invalid"])
            )
            do {
                _ = try await URLSessionHLSAES128KeyLoader(networking: networking)
                    .loadKey(from: keyURL, HTTPHeaders: [:], networkPolicy: .unrestricted, maximumRedirects: 0)
                Issue.record("Expected network failure")
            } catch let error as URLError {
                #expect(error.code == code)
                #expect(error.userInfo.isEmpty)
                #expect(policy.classify(error) == policy.classify(URLError(code)))
            }
        }
        let oversized = FixtureHLSKeyNetworking(
            responses: [:], forcedError: HLSPlaylistTransportError.responseTooLarge
        )
        await #expect(throws: HLSPlaylistTransportError.responseTooLarge) {
            _ = try await URLSessionHLSAES128KeyLoader(networking: oversized)
                .loadKey(from: keyURL, HTTPHeaders: [:], networkPolicy: .unrestricted, maximumRedirects: 0)
        }
    }

    @Test
    func keyLoaderRejectsWrongLengthStatusContentAndRedirects() async {
        let keyURL = URL(
            string: "https://manifest.googlevideo.com/hls/key.bin"
        )!
        let invalidResponses: [
            (HLSPlaylistHTTPResponse, HLSAES128KeyLoadingError)
        ] = [
            (
                HLSPlaylistHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(repeating: 1, count: 15)
                ),
                .invalidResponse
            ),
            (
                HLSPlaylistHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(repeating: 1, count: 17)
                ),
                .invalidResponse
            ),
            (
                HLSPlaylistHTTPResponse(
                    statusCode: 206,
                    headers: ["Content-Range": "bytes 0-15/16"],
                    body: Data(repeating: 1, count: 16)
                ),
                .invalidResponse
            ),
            (
                HLSPlaylistHTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Length": "15"],
                    body: Data(repeating: 1, count: 16)
                ),
                .invalidResponse
            ),
            (
                HLSPlaylistHTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Encoding": "gzip"],
                    body: Data(repeating: 1, count: 16)
                ),
                .invalidResponse
            ),
        ]

        for (response, expected) in invalidResponses {
            let networking = FixtureHLSKeyNetworking(responses: [
                keyURL.absoluteString: [response],
            ])
            let loader = URLSessionHLSAES128KeyLoader(networking: networking)
            do {
                _ = try await loader.loadKey(
                    from: keyURL,
                    HTTPHeaders: [:],
                    networkPolicy: .unrestricted,
                    maximumRedirects: 1
                )
                Issue.record("Invalid key response unexpectedly succeeded.")
            } catch let error as HLSAES128KeyLoadingError {
                #expect(error == expected)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }

        let unsafeRedirect = FixtureHLSKeyNetworking(responses: [
            keyURL.absoluteString: [
                HLSPlaylistHTTPResponse(
                    statusCode: 302,
                    headers: ["Location": "http://example.invalid/key"],
                    body: Data()
                ),
            ],
        ])
        await #expect(throws: HLSAES128KeyLoadingError.self) {
            _ = try await URLSessionHLSAES128KeyLoader(
                networking: unsafeRedirect
            ).loadKey(
                from: keyURL,
                HTTPHeaders: [:],
                networkPolicy: .unrestricted,
                maximumRedirects: 1
            )
        }

        let cancelled = FixtureHLSKeyNetworking(
            responses: [:],
            forcedError: CancellationError()
        )
        await #expect(throws: CancellationError.self) {
            _ = try await URLSessionHLSAES128KeyLoader(
                networking: cancelled
            ).loadKey(
                from: keyURL,
                HTTPHeaders: [:],
                networkPolicy: .unrestricted,
                maximumRedirects: 1
            )
        }
    }

    @Test
    func decryptsKnownCBCFixtureToExactPlaintext() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appending(path: "ciphertext.bin")
        let outputURL = directory.appending(path: "plaintext.bin")
        let plaintext = Data("Illucet P10.6".utf8)
        try fixtureCiphertext.write(to: inputURL)

        let byteCount = try HLSAES128CBCDecrypter.decrypt(
            inputURL: inputURL,
            outputURL: outputURL,
            key: fixtureKey,
            initializationVector: fixtureIV
        )

        #expect(byteCount == Int64(plaintext.count))
        #expect(try Data(contentsOf: outputURL) == plaintext)
        #expect(FileManager.default.fileExists(atPath: inputURL.path))
    }

    @Test
    func wrongKeyIVBlockPaddingAndCancellationNeverPublishPlaintext() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = FileManager.default

        var tampered = fixtureCiphertext
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        var wrongIV = fixtureIV
        wrongIV[wrongIV.index(before: wrongIV.endIndex)] ^= 1
        let rejected: [(Data, Data, Data)] = [
            (fixtureCiphertext, Data(repeating: 0, count: 16), fixtureIV),
            (fixtureCiphertext, fixtureKey, wrongIV),
            (Data(fixtureCiphertext.dropLast()), fixtureKey, fixtureIV),
            (tampered, fixtureKey, fixtureIV),
        ]
        for (index, fixture) in rejected.enumerated() {
            let inputURL = directory.appending(path: "rejected-\(index).bin")
            let outputURL = directory.appending(
                path: "rejected-\(index).plaintext"
            )
            try fixture.0.write(to: inputURL)
            #expect(throws: HLSAES128CBCDecryptionError.self) {
                _ = try HLSAES128CBCDecrypter.decrypt(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    key: fixture.1,
                    initializationVector: fixture.2
                )
            }
            #expect(!manager.fileExists(atPath: outputURL.path))
        }

        let cancellationInput = directory.appending(
            path: "cancel-ciphertext.bin"
        )
        let cancellationOutput = directory.appending(
            path: "cancel-plaintext.bin"
        )
        try cancellationCiphertext.write(to: cancellationInput)
        var checkpoints = 0
        #expect(throws: CancellationError.self) {
            _ = try HLSAES128CBCDecrypter.decrypt(
                inputURL: cancellationInput,
                outputURL: cancellationOutput,
                key: fixtureKey,
                initializationVector: fixtureIV,
                checkpoint: {
                    checkpoints += 1
                    if checkpoints == 3 {
                        throw CancellationError()
                    }
                }
            )
        }
        #expect(checkpoints == 3)
        #expect(!manager.fileExists(atPath: cancellationOutput.path))
    }

    private var fixtureKey: Data {
        Data(Array(0...15).map(UInt8.init))
    }

    private var fixtureIV: Data {
        Data(Array(16...31).map(UInt8.init))
    }

    private var fixtureCiphertext: Data {
        Self.data(hex: "90f1439cce23bacc7d465f7b3517e541")
    }

    private var cancellationCiphertext: Data {
        Self.data(
            hex: "ae6cc753aaefdce77a7cbad791ef3b6f"
                + "d579bf55456fc948d7623e602fa15bfe"
                + "0e9ff79381c1a96fdbc1439f6af277ab"
        )
    }

    private func temporaryDirectory() throws -> URL {
        let URL = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-HLS-AES-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: URL,
            withIntermediateDirectories: false
        )
        return URL
    }

    private static func data(hex: String) -> Data {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }
}

private actor FixtureHLSKeyNetworking: HLSPlaylistNetworking {
    private var responses: [String: [HLSPlaylistHTTPResponse]]
    private let forcedError: (any Error)?
    private var requests: [URLRequest] = []

    init(
        responses: [String: [HLSPlaylistHTTPResponse]],
        forcedError: (any Error)? = nil
    ) {
        self.responses = responses
        self.forcedError = forcedError
    }

    func response(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> HLSPlaylistHTTPResponse {
        guard maximumBytes == URLSessionHLSAES128KeyLoader.keyByteCount else {
            throw HLSPlaylistTransportError.responseTooLarge
        }
        requests.append(request)
        if let forcedError {
            throw forcedError
        }
        guard
            let URL = request.url,
            var queued = responses[URL.absoluteString],
            !queued.isEmpty
        else {
            throw HLSPlaylistTransportError.HTTPFailure
        }
        let response = queued.removeFirst()
        responses[URL.absoluteString] = queued
        return response
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}
