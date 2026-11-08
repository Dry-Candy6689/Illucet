import Foundation

enum LiveMetadataStage0ProofRunner {
    private static let requestID: UInt64 = 30_001

    static func run(
        engine: PythonEngine,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] =
            ProcessInfo.processInfo.environment
    ) async -> [Stage0Check] {
        guard AuthorizedLiveTestConfigurationLoader.executionWasRequested(
            arguments: arguments,
            environment: environment
        ) else {
            return checks(
                status: .notRun,
                evidence:
                    "Live network extraction requires --stage0-live and an "
                    + "explicit user-supplied public metadata URL; no "
                    + "network request was made."
            )
        }

        let configuration: AuthorizedLiveTestConfiguration
        do {
            configuration = try AuthorizedLiveTestConfigurationLoader.load(
                arguments: arguments,
                environment: environment
            )
        } catch let error as AuthorizedLiveTestConfigurationError {
            let status: ProofStatus = error == .disabled ? .notRun : .blocked
            return checks(
                status: status,
                evidence: error.localizedDescription
            )
        } catch {
            return checks(
                status: .fail,
                evidence: "Live-test configuration failed closed."
            )
        }

        let extractor = YTDLPExtractorEngine(python: engine)
        do {
            let result = try await extractor.analyzeWithEvidence(
                url: configuration.standardVideoURL,
                requestID: requestID
            )
            let validation = LiveExtractionValidator.validate(
                result,
                requestedURL: configuration.standardVideoURL
            )
            let metadata = result.metadata
            let provider = result.providerEvidence
            let challengeProofStatus = challengeProofStatus(
                providerPathIsValid: validation.providerPathIsValid,
                challengeRequestCount: provider.challengeRequestCount
            )
            let resolutions = Set(
                metadata.formats.compactMap(\.height)
            ).sorted()
            let identityEvidence =
                "source=\(configuration.source.rawValue); "
                + "video_id=\(metadata.videoID); "
                + "title=\(metadata.title); "
                + "duration=\(metadata.durationSeconds ?? 0)s; "
                + "thumbnails=\(metadata.thumbnails.count)"
            let formatsEvidence =
                "usable_formats=\(metadata.formats.count); "
                + "heights=\(resolutions); "
                + "video=\(metadata.formats.count(where: \.hasVideo)); "
                + "audio=\(metadata.formats.count(where: \.hasAudio))"
            let providerEvidence =
                "provider=\(provider.providerKey); "
                + "requests=\(provider.challengeRequestCount); "
                + "responses=\(provider.challengeResponseCount); "
                + "types=\(provider.challengeTypes.sorted()); "
                + "runtime_calls=\(provider.runtimeCallCount); "
                + "formats=\(provider.formatCount); "
                + "inventory_sha256=\(provider.formatInventorySHA256); "
                + "warnings=\(provider.warningCount); "
                + "errors=\(provider.errorCount)"

            return [
                Stage0Check(
                    id: "live-metadata-identity",
                    name: "Retrieve user-supplied public video metadata",
                    status: validation.identityIsValid &&
                        validation.thumbnailIsValid ? .pass : .fail,
                    evidence: identityEvidence
                ),
                Stage0Check(
                    id: "live-metadata-formats",
                    name: "Retrieve usable live format inventory",
                    status: validation.formatsAreValid ? .pass : .fail,
                    evidence: formatsEvidence
                ),
                Stage0Check(
                    id: "live-js-provider-path",
                    name: "Use in-process QuickJS for live challenges",
                    status: challengeProofStatus,
                    evidence: providerEvidence
                ),
            ]
        } catch let error as ExtractionError {
            let evidence: String
            if case let .extractorFailure(code, message, _) = error {
                evidence = "code=\(code); \(message)"
            } else {
                evidence = error.localizedDescription
            }
            return checks(
                status: .fail,
                evidence: evidence
            )
        } catch {
            return checks(
                status: .fail,
                evidence: "Live extraction failed with a redacted error."
            )
        }
    }

    static func challengeProofStatus(
        providerPathIsValid: Bool,
        challengeRequestCount: Int
    ) -> ProofStatus {
        guard providerPathIsValid else { return .fail }
        if challengeRequestCount == 0 {
            return .notRun
        }
        return .pass
    }

    private static func checks(
        status: ProofStatus,
        evidence: String
    ) -> [Stage0Check] {
        [
                Stage0Check(
                    id: "live-metadata-identity",
                    name: "Retrieve user-supplied public video metadata",
                status: status,
                evidence: evidence
            ),
            Stage0Check(
                id: "live-metadata-formats",
                name: "Retrieve usable live format inventory",
                status: status,
                evidence: evidence
            ),
            Stage0Check(
                id: "live-js-provider-path",
                name: "Use in-process QuickJS for live challenges",
                status: status,
                evidence: evidence
            ),
        ]
    }
}
