import Foundation

enum DownloadRetryReason: String, Codable, Equatable, Sendable {
    case extractorTemporarilyUnavailable
    case mediaAccessForbidden
    case mediaURLExpired
    case mediaURLGone
    case networkFailure
    case serverFailure
}

enum DownloadFailureClassification: Equatable, Sendable {
    case cancelled
    case permanent
    case waitForConnectivity
    case retryable(
        reason: DownloadRetryReason,
        reResolveStreams: Bool
    )
}

enum DownloadRetryDisposition: Equatable, Sendable {
    case doNotRetry
    case waitForConnectivity
    case retry(
        reason: DownloadRetryReason,
        delaySeconds: Double,
        reResolveStreams: Bool
    )
}

struct DownloadRetryPolicy: Equatable, Sendable {
    let initialDelaySeconds: Double
    let multiplier: Double
    let maximumDelaySeconds: Double

    init(
        initialDelaySeconds: Double = 1,
        multiplier: Double = 2,
        maximumDelaySeconds: Double = 60
    ) {
        self.initialDelaySeconds = max(0, initialDelaySeconds)
        self.multiplier = max(1, multiplier)
        self.maximumDelaySeconds = max(
            self.initialDelaySeconds,
            maximumDelaySeconds
        )
    }

    func disposition(
        for error: any Error,
        retriesAlreadyUsed: Int,
        maximumRetries: Int
    ) -> DownloadRetryDisposition {
        switch classify(error) {
        case .cancelled, .permanent:
            return .doNotRetry
        case .waitForConnectivity:
            return .waitForConnectivity
        case let .retryable(reason, reResolveStreams):
            guard retriesAlreadyUsed < max(0, maximumRetries) else {
                return .doNotRetry
            }
            return .retry(
                reason: reason,
                delaySeconds: delay(
                    forRetryNumber: retriesAlreadyUsed + 1
                ),
                reResolveStreams: reResolveStreams
            )
        }
    }

    func delay(forRetryNumber retryNumber: Int) -> Double {
        guard retryNumber > 1 else {
            return initialDelaySeconds
        }
        let exponent = Double(retryNumber - 1)
        let candidate = initialDelaySeconds * pow(multiplier, exponent)
        guard candidate.isFinite else {
            return maximumDelaySeconds
        }
        return min(maximumDelaySeconds, candidate)
    }

    func classify(
        _ error: any Error
    ) -> DownloadFailureClassification {
        if error is CancellationError {
            return .cancelled
        }
        if let processor = error as? MediaProcessorError,
           processor == .cancelled {
            return .cancelled
        }
        if let resolution = error as? DASHFragmentResolutionError,
           resolution == .cancelled {
            return .cancelled
        }
        if let extraction = error as? ExtractionError {
            switch extraction {
            case .cancelled:
                return .cancelled
            case let .extractorFailure(_, _, retryable):
                return retryable
                    ? .retryable(
                        reason: .extractorTemporarilyUnavailable,
                        reResolveStreams: true
                    )
                    : .permanent
            case .invalidURL, .unsupportedSite, .invalidResponse:
                return .permanent
            }
        }
        if let resolution = error as? StreamResolutionError {
            switch resolution {
            case .cancelled:
                return .cancelled
            case let .resolverFailure(_, details):
                return Self.classifyResolutionFailure(details)
            case .bridgeUnavailable:
                return .retryable(
                    reason: .extractorTemporarilyUnavailable,
                    reResolveStreams: true
                )
            case .invalidSelection, .invalidResponse, .unsupportedProtocol:
                return .permanent
            }
        }
        if let resolution = error as? HLSPlaylistResolutionError {
            switch resolution {
            case .cancelled:
                return .cancelled
            case let .resolverFailure(_, details):
                return Self.classifyResolutionFailure(details)
            case .bridgeUnavailable:
                return .retryable(
                    reason: .extractorTemporarilyUnavailable,
                    reResolveStreams: true
                )
            case .invalidSelection, .invalidResponse, .identityMismatch,
                 .recursivePlaylist:
                return .permanent
            }
        }
        if let staging = error as? HLSResourceStagingError,
           staging == .networkFailure {
            return .retryable(reason: .networkFailure, reResolveStreams: true)
        }
        if let key = error as? HLSAES128KeyLoadingError,
           key == .networkFailure {
            return .retryable(reason: .networkFailure, reResolveStreams: true)
        }
        if let transfer = error as? StreamDownloadError {
            switch transfer {
            case .cancelled:
                return .cancelled
            case .networkFailure:
                return .retryable(
                    reason: .networkFailure,
                    reResolveStreams: true
                )
            case .unauthorizedHTTPFailure:
                return .permanent
            case .forbiddenHTTPFailure:
                return .retryable(
                    reason: .mediaAccessForbidden,
                    reResolveStreams: true
                )
            case .goneHTTPFailure:
                return .retryable(
                    reason: .mediaURLGone,
                    reResolveStreams: true
                )
            case .transientHTTPFailure:
                return .retryable(
                    reason: .serverFailure,
                    reResolveStreams: true
                )
            case .permanentHTTPFailure:
                return .permanent
            case .couldNotCommitFile, .invalidPartialContent,
                 .rangeAssemblyFailure:
                return .permanent
            }
        }
        if let URLFailure = error as? URLError {
            switch URLFailure.code {
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet:
                return .waitForConnectivity
            case .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .resourceUnavailable:
                return .retryable(
                    reason: .networkFailure,
                    reResolveStreams: true
                )
            default:
                return .permanent
            }
        }
        if let illucet = error as? IllucetError {
            switch illucet {
            case .networkOffline:
                return .waitForConnectivity
            case .mediaURLExpired:
                return .retryable(
                    reason: .mediaURLExpired,
                    reResolveStreams: true
                )
            case .userCancelled:
                return .cancelled
            default:
                return .permanent
            }
        }
        if let thumbnail = error as? ThumbnailError {
            switch thumbnail {
            case .downloadFailed:
                return .retryable(
                    reason: .networkFailure,
                    reResolveStreams: false
                )
            case .invalidURL, .decodeFailed, .encoderUnavailable:
                return .permanent
            }
        }
        return .permanent
    }

    private static func classifyResolutionFailure(
        _ details: StreamResolutionFailureDetails
    ) -> DownloadFailureClassification {
        let normalized = details.code.lowercased()
        if normalized == "http_401" {
            return .permanent
        }
        guard details.retryable else {
            return .permanent
        }
        let reason: DownloadRetryReason
        switch normalized {
        case "http_403":
            reason = .mediaAccessForbidden
        case "http_410":
            reason = .mediaURLGone
        default:
            reason = normalized.contains("expired")
                ? .mediaURLExpired
                : .extractorTemporarilyUnavailable
        }
        return .retryable(reason: reason, reResolveStreams: true)
    }
}
