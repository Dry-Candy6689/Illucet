import Foundation

struct AuthorizedLiveTestConfiguration: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case launchArgument = "launch argument"
        case documents = "app Documents"
        case bundle = "application bundle"
        case environmentPath = "explicit environment path"
    }

    let standardVideoURL: URL
    let source: Source
}

enum AuthorizedLiveTestConfigurationError: LocalizedError, Equatable {
    case missing
    case disabled
    case invalidPropertyList
    case missingStandardVideoURL

    var errorDescription: String? {
        switch self {
        case .missing:
            "AuthorizedLiveTestURLs.plist was not found."
        case .disabled:
            "AuthorizedLiveTestURLs.plist has LiveTestsEnabled set to false."
        case .invalidPropertyList:
            "AuthorizedLiveTestURLs.plist could not be decoded."
        case .missingStandardVideoURL:
            "The enabled live-test configuration has no valid StandardVideoURL."
        }
    }
}

enum AuthorizedLiveTestConfigurationLoader {
    static let enableArgument = "--stage0-live"
    static let URLArgument = "--stage0-live-url"

    static func executionWasRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] =
            ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.contains(enableArgument) ||
            environment["ILLUCET_STAGE0_LIVE_TESTS"] == "1"
    }

    static func load(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] =
            ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> AuthorizedLiveTestConfiguration {
        guard executionWasRequested(
            arguments: arguments,
            environment: environment
        ) else {
            throw AuthorizedLiveTestConfigurationError.disabled
        }

        if let index = arguments.firstIndex(of: URLArgument),
           arguments.indices.contains(index + 1),
           let url = URL(string: arguments[index + 1])
        {
            return AuthorizedLiveTestConfiguration(
                standardVideoURL: url,
                source: .launchArgument
            )
        }

        var candidates: [(URL, AuthorizedLiveTestConfiguration.Source)] = []
        if let path = environment[
            "ILLUCET_AUTHORIZED_LIVE_TEST_CONFIG_PATH"
        ], !path.isEmpty {
            candidates.append((URL(filePath: path), .environmentPath))
        }
        if let documents = try? fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            candidates.append(
                (
                    documents.appending(
                        path: "AuthorizedLiveTestURLs.plist"
                    ),
                    .documents
                )
            )
        }
        if let bundled = bundle.url(
            forResource: "AuthorizedLiveTestURLs",
            withExtension: "plist"
        ) {
            candidates.append((bundled, .bundle))
        }

        guard let candidate = candidates.first(where: {
            fileManager.fileExists(atPath: $0.0.path)
        }) else {
            throw AuthorizedLiveTestConfigurationError.missing
        }
        return try decode(
            Data(contentsOf: candidate.0),
            source: candidate.1
        )
    }

    static func decode(
        _ data: Data,
        source: AuthorizedLiveTestConfiguration.Source
    ) throws -> AuthorizedLiveTestConfiguration {
        let propertyList: [String: Any]
        do {
            let decoded = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
            guard let dictionary = decoded as? [String: Any] else {
                throw AuthorizedLiveTestConfigurationError
                    .invalidPropertyList
            }
            propertyList = dictionary
        } catch is AuthorizedLiveTestConfigurationError {
            throw AuthorizedLiveTestConfigurationError.invalidPropertyList
        } catch {
            throw AuthorizedLiveTestConfigurationError.invalidPropertyList
        }

        guard propertyList["LiveTestsEnabled"] as? Bool == true else {
            throw AuthorizedLiveTestConfigurationError.disabled
        }
        guard
            let rawURL = propertyList["StandardVideoURL"] as? String,
            let url = URL(string: rawURL),
            !rawURL.isEmpty
        else {
            throw AuthorizedLiveTestConfigurationError
                .missingStandardVideoURL
        }
        return AuthorizedLiveTestConfiguration(
            standardVideoURL: url,
            source: source
        )
    }
}
