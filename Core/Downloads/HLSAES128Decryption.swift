import Foundation

struct HLSAES128KeyLoadResult: Equatable, Sendable {
    let key: Data
    let redirectCount: Int
}

protocol HLSAES128KeyLoading: Sendable {
    func loadKey(
        from initialURL: URL,
        HTTPHeaders: [String: String],
        networkPolicy: StreamTransferNetworkPolicy,
        maximumRedirects: Int
    ) async throws -> HLSAES128KeyLoadResult
}

final class URLSessionHLSAES128KeyLoader:
    HLSAES128KeyLoading,
    @unchecked Sendable
{
    static let keyByteCount = 16

    private let networking: any HLSPlaylistNetworking
    private let policy: HLSPlaylistSessionPolicy

    init(
        networking: (any HLSPlaylistNetworking)? = nil,
        policy: HLSPlaylistSessionPolicy = .secure
    ) {
        self.policy = policy
        self.networking = networking
            ?? URLSessionHLSPlaylistHTTPClient(policy: policy)
    }

    func loadKey(
        from initialURL: URL,
        HTTPHeaders: [String: String],
        networkPolicy: StreamTransferNetworkPolicy,
        maximumRedirects: Int
    ) async throws -> HLSAES128KeyLoadResult {
        guard
            HLSPlaylistSecurity.isAllowedPlaylistURL(initialURL),
            HLSPlaylistSecurity.areAllowedHeaders(HTTPHeaders),
            (0...policy.maximumRedirects).contains(maximumRedirects),
            policy.requestTimeout.isFinite,
            policy.requestTimeout > 0,
            policy.requestTimeout
                <= HLSPlaylistSessionPolicy.secure.requestTimeout,
            policy.resourceTimeout.isFinite,
            policy.resourceTimeout > 0,
            policy.resourceTimeout
                <= HLSPlaylistSessionPolicy.secure.resourceTimeout,
            !policy.acceptsCookies,
            !policy.usesCredentialStorage,
            !policy.usesURLCache,
            policy.usesDefaultTLSVerification
        else {
            throw HLSAES128KeyLoadingError.invalidRequest
        }

        var currentURL = initialURL
        var redirectCount = 0
        var visitedURLs: Set<String> = []
        while true {
            try Task.checkCancellation()
            guard
                HLSPlaylistSecurity.isAllowedPlaylistURL(currentURL),
                visitedURLs.insert(currentURL.absoluteString).inserted
            else {
                throw HLSAES128KeyLoadingError.unsafeRedirect
            }

            var request = URLRequest(url: currentURL)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            request.timeoutInterval = policy.requestTimeout
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.allowsExpensiveNetworkAccess =
                networkPolicy.allowsExpensiveAccess
            request.allowsConstrainedNetworkAccess =
                networkPolicy.allowsConstrainedAccess
            for (name, value) in HTTPHeaders {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

            let response: HLSPlaylistHTTPResponse
            do {
                response = try await networking.response(
                    for: request,
                    maximumBytes: Self.keyByteCount
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                throw URLError(error.code)
            } catch let error as StreamDownloadError {
                throw error
            } catch let error as HLSPlaylistTransportError {
                throw error
            } catch {
                throw HLSAES128KeyLoadingError.networkFailure
            }

            if response.statusCode == 200 {
                guard
                    response.body.count == Self.keyByteCount,
                    hasValidAcceptedHeaders(response.headers)
                else {
                    throw HLSAES128KeyLoadingError.invalidResponse
                }
                return HLSAES128KeyLoadResult(
                    key: response.body,
                    redirectCount: redirectCount
                )
            }
            if response.statusCode >= 400 {
                throw StreamDownloadError.HTTPFailure(statusCode: response.statusCode)
            }
            if (300...399).contains(response.statusCode) {
                let locations = headerValues(
                    named: "Location",
                    in: response.headers
                )
                guard
                    redirectCount < maximumRedirects,
                    locations.count == 1,
                    locations[0].utf8.count
                        <= HLSPlaylistParser.maximumURIBytes,
                    let redirectedURL = URL(
                        string: locations[0],
                        relativeTo: currentURL
                    )?.absoluteURL,
                    HLSPlaylistSecurity.isAllowedPlaylistURL(redirectedURL)
                else {
                    throw HLSAES128KeyLoadingError.tooManyRedirects
                }
                currentURL = redirectedURL
                redirectCount += 1
                continue
            }
            throw HLSAES128KeyLoadingError.invalidResponse
        }
    }

    private func hasValidAcceptedHeaders(
        _ headers: [String: String]
    ) -> Bool {
        let contentLengths = headerValues(
            named: "Content-Length",
            in: headers
        )
        guard contentLengths.count <= 1 else { return false }
        if let value = contentLengths.first {
            guard
                !value.isEmpty,
                value.utf8.allSatisfy({ (48...57).contains($0) }),
                Int(value) == Self.keyByteCount
            else {
                return false
            }
        }
        let contentEncodings = headerValues(
            named: "Content-Encoding",
            in: headers
        )
        guard
            contentEncodings.count <= 1,
            contentEncodings.first == nil
                || contentEncodings.first?.lowercased() == "identity",
            headerValues(named: "Content-Range", in: headers).isEmpty
        else {
            return false
        }
        return true
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
}

enum HLSAES128KeyLoadingError: LocalizedError, Equatable, Sendable {
    case invalidRequest
    case networkFailure
    case unavailable
    case unsafeRedirect
    case tooManyRedirects
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "The HLS key request is invalid."
        case .networkFailure:
            "The HLS key request failed."
        case .unavailable:
            "The HLS key is unavailable."
        case .unsafeRedirect:
            "The HLS key redirected to an unsafe destination."
        case .tooManyRedirects:
            "The HLS key redirected too many times."
        case .invalidResponse:
            "The HLS key response is invalid."
        }
    }
}

enum HLSAES128CBCDecrypter {
    static let blockByteCount = 16
    static let readBufferByteCount = 64 * 1_024

    static func decrypt(
        inputURL: URL,
        outputURL: URL,
        key: Data,
        initializationVector: Data,
        fileManager: FileManager = .default,
        checkpoint: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Int64 {
        try checkpoint()
        guard
            key.count == blockByteCount,
            initializationVector.count == blockByteCount,
            inputURL.standardizedFileURL != outputURL.standardizedFileURL,
            !fileManager.fileExists(atPath: outputURL.path),
            isRegularFile(inputURL, fileManager: fileManager),
            let inputByteCount = exactFileSize(
                inputURL,
                fileManager: fileManager
            ),
            inputByteCount > 0,
            inputByteCount % Int64(blockByteCount) == 0,
            isRegularDirectory(
                outputURL.deletingLastPathComponent(),
                fileManager: fileManager
            )
        else {
            throw HLSAES128CBCDecryptionError.invalidInput
        }

        let decryptor = key.withUnsafeBytes { keyBytes in
            initializationVector.withUnsafeBytes { IVBytes in
                IllucetAES128CBCDecryptorCreate(
                    keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    keyBytes.count,
                    IVBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    IVBytes.count
                )
            }
        }
        guard let decryptor else {
            throw HLSAES128CBCDecryptionError.decryptionFailed
        }
        defer { IllucetAES128CBCDecryptorDestroy(decryptor) }

        guard fileManager.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: BackgroundFileProtection.attributes
        ) else {
            throw HLSAES128CBCDecryptionError.couldNotCreateOutput
        }

        do {
            let input = try FileHandle(forReadingFrom: inputURL)
            let output = try FileHandle(forWritingTo: outputURL)
            defer {
                try? input.close()
                try? output.close()
            }

            var totalOutputBytes: Int64 = 0
            var pendingFinalBlock = Data()
            while true {
                try checkpoint()
                guard let encrypted = try input.read(
                    upToCount: readBufferByteCount
                ), !encrypted.isEmpty else {
                    break
                }
                var plaintext = Data(
                    count: encrypted.count + blockByteCount
                )
                var plaintextByteCount = 0
                let status = plaintext.withUnsafeMutableBytes { outputBytes in
                    encrypted.withUnsafeBytes { inputBytes in
                        IllucetAES128CBCDecryptorUpdate(
                            decryptor,
                            inputBytes.baseAddress?
                                .assumingMemoryBound(to: UInt8.self),
                            inputBytes.count,
                            outputBytes.baseAddress?
                                .assumingMemoryBound(to: UInt8.self),
                            outputBytes.count,
                            &plaintextByteCount
                        )
                    }
                }
                guard
                    status == IllucetAES128CBCStatusOK,
                    plaintextByteCount <= plaintext.count,
                    plaintextByteCount % blockByteCount == 0
                else {
                    throw HLSAES128CBCDecryptionError.decryptionFailed
                }
                plaintext.count = plaintextByteCount
                pendingFinalBlock.append(plaintext)
                if pendingFinalBlock.count > blockByteCount {
                    let writableByteCount = pendingFinalBlock.count
                        - blockByteCount
                    try output.write(
                        contentsOf: pendingFinalBlock.prefix(
                            writableByteCount
                        )
                    )
                    totalOutputBytes = try adding(
                        writableByteCount,
                        to: totalOutputBytes
                    )
                    pendingFinalBlock.removeFirst(writableByteCount)
                }
            }

            try checkpoint()
            var finalPlaintext = Data(count: blockByteCount)
            var finalByteCount = 0
            let finalStatus = finalPlaintext.withUnsafeMutableBytes {
                IllucetAES128CBCDecryptorFinal(
                    decryptor,
                    $0.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    $0.count,
                    &finalByteCount
                )
            }
            guard
                finalStatus == IllucetAES128CBCStatusOK,
                finalByteCount <= finalPlaintext.count,
                finalByteCount % blockByteCount == 0
            else {
                throw HLSAES128CBCDecryptionError.decryptionFailed
            }
            finalPlaintext.count = finalByteCount
            pendingFinalBlock.append(finalPlaintext)
            guard
                pendingFinalBlock.count == blockByteCount,
                let paddingByte = pendingFinalBlock.last,
                (1...blockByteCount).contains(Int(paddingByte))
            else {
                throw HLSAES128CBCDecryptionError.invalidPadding
            }
            let paddingByteCount = Int(paddingByte)
            guard pendingFinalBlock.suffix(paddingByteCount).allSatisfy({
                $0 == paddingByte
            }) else {
                throw HLSAES128CBCDecryptionError.invalidPadding
            }
            pendingFinalBlock.removeLast(paddingByteCount)
            if !pendingFinalBlock.isEmpty {
                try output.write(contentsOf: pendingFinalBlock)
                totalOutputBytes = try adding(
                    pendingFinalBlock.count,
                    to: totalOutputBytes
                )
            }
            try output.synchronize()
            guard
                totalOutputBytes > 0,
                exactFileSize(outputURL, fileManager: fileManager)
                    == totalOutputBytes,
                isRegularFile(outputURL, fileManager: fileManager)
            else {
                throw HLSAES128CBCDecryptionError.decryptionFailed
            }
            try checkpoint()
            return totalOutputBytes
        } catch {
            do {
                if fileManager.fileExists(atPath: outputURL.path) {
                    try fileManager.removeItem(at: outputURL)
                }
            } catch {
                throw HLSAES128CBCDecryptionError.couldNotCleanOutput
            }
            throw error
        }
    }

    private static func adding(_ bytes: Int, to total: Int64) throws -> Int64 {
        guard let bytes = Int64(exactly: bytes) else {
            throw HLSAES128CBCDecryptionError.decryptionFailed
        }
        let addition = total.addingReportingOverflow(bytes)
        guard !addition.overflow, addition.partialValue >= 0 else {
            throw HLSAES128CBCDecryptionError.decryptionFailed
        }
        return addition.partialValue
    }

    private static func exactFileSize(
        _ URL: URL,
        fileManager: FileManager
    ) -> Int64? {
        guard
            let attributes = try? fileManager.attributesOfItem(
                atPath: URL.path
            ),
            let number = attributes[.size] as? NSNumber,
            number.int64Value >= 0
        else {
            return nil
        }
        return number.int64Value
    }

    private static func isRegularFile(
        _ URL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard
            (try? fileManager.destinationOfSymbolicLink(atPath: URL.path))
                == nil,
            let values = try? URL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func isRegularDirectory(
        _ URL: URL,
        fileManager: FileManager
    ) -> Bool {
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
}

enum HLSAES128CBCDecryptionError: LocalizedError, Equatable, Sendable {
    case invalidInput
    case couldNotCreateOutput
    case invalidPadding
    case decryptionFailed
    case couldNotCleanOutput

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            "The encrypted HLS resource is invalid."
        case .couldNotCreateOutput:
            "The HLS plaintext staging file could not be created."
        case .invalidPadding:
            "The encrypted HLS resource padding is invalid."
        case .decryptionFailed:
            "The encrypted HLS resource could not be decrypted."
        case .couldNotCleanOutput:
            "Rejected HLS plaintext could not be removed."
        }
    }
}
