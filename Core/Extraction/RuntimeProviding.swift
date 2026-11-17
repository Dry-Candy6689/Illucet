import Foundation

protocol RuntimeProviding: ExternalMediaProviding, Sendable {
    func configuredExtractor(accountID: UUID?, preferences: EnginePreferences?) async throws -> any ExtractorEngine
    func configuredResolver(accountID: UUID?, preferences: EnginePreferences?) async throws -> any StreamResolver
    func configuredDASHResolver(accountID: UUID?, preferences: EnginePreferences?) async throws -> any DASHFragmentResolving
    func configuredHLSResolver(accountID: UUID?, preferences: EnginePreferences?) async throws -> any HLSPlaylistResolving
    func makeExtractor() async throws -> any ExtractorEngine
    func makeResolver() async throws -> any StreamResolver
    func makeDASHFragmentResolver() async throws
        -> any DASHFragmentResolving
    func makeHLSPlaylistResolver() async throws
        -> any HLSPlaylistResolving
    func makeExtractor(accountID: UUID?) async throws -> any ExtractorEngine

    func makeResolver(accountID: UUID?) async throws -> any StreamResolver

    func makeDASHFragmentResolver(accountID: UUID?) async throws -> any DASHFragmentResolving

    func makeHLSPlaylistResolver(accountID: UUID?) async throws -> any HLSPlaylistResolving

}

extension RuntimeProviding {
    func configuredHLSResolver(accountID: UUID?, preferences: EnginePreferences?) async throws -> any HLSPlaylistResolving { try await makeHLSPlaylistResolver(accountID: accountID) }
    func configuredExtractor(accountID: UUID?, preferences: EnginePreferences?) async throws -> any ExtractorEngine { try await makeExtractor(accountID: accountID) }
    func configuredResolver(accountID: UUID?, preferences: EnginePreferences?) async throws -> any StreamResolver { try await makeResolver(accountID: accountID) }
    func configuredDASHResolver(accountID: UUID?, preferences: EnginePreferences?) async throws -> any DASHFragmentResolving { try await makeDASHFragmentResolver(accountID: accountID) }
    func makeExtractor(accountID: UUID?) async throws -> any ExtractorEngine {
        guard accountID == nil else { throw AccountError.unavailable }
        return try await makeExtractor()
    }

    func makeResolver(accountID: UUID?) async throws -> any StreamResolver {
        guard accountID == nil else { throw AccountError.unavailable }
        return try await makeResolver()
    }

    func makeDASHFragmentResolver(accountID: UUID?) async throws -> any DASHFragmentResolving {
        guard accountID == nil else { throw AccountError.unavailable }
        return try await makeDASHFragmentResolver()
    }

    func makeHLSPlaylistResolver(accountID: UUID?) async throws -> any HLSPlaylistResolving {
        guard accountID == nil else { throw AccountError.unavailable }
        return try await makeHLSPlaylistResolver()
    }

    func makeDASHFragmentResolver() async throws
        -> any DASHFragmentResolving
    {
        throw DASHFragmentResolutionError.bridgeUnavailable
    }

    func makeHLSPlaylistResolver() async throws
        -> any HLSPlaylistResolving
    {
        throw HLSPlaylistResolutionError.bridgeUnavailable
    }
}

extension RuntimeEnvironment: RuntimeProviding {
    func configuredHLSResolver(accountID: UUID?, preferences: EnginePreferences?) async throws -> any HLSPlaylistResolving {
        YTDLPHLSPlaylistResolver(python: try await startedPython(),
            authentication: accountID.map { AccountAuthentication(id: $0, store: accounts) },
            preferences: preferences ?? .init())
    }
    func configuredExtractor(accountID: UUID?, preferences: EnginePreferences?) async throws -> any ExtractorEngine {
        try await extractor(accountID: accountID, preferences: preferences ?? .init())
    }
    func configuredResolver(accountID: UUID?, preferences: EnginePreferences?) async throws -> any StreamResolver {
        try await resolver(accountID: accountID, preferences: preferences ?? .init())
    }
    func configuredDASHResolver(accountID: UUID?, preferences: EnginePreferences?) async throws -> any DASHFragmentResolving {
        try await resolver(accountID: accountID, preferences: preferences ?? .init())
    }
    func makeExtractor(accountID: UUID?) async throws -> any ExtractorEngine {
        try await extractor(accountID: accountID)
    }

    func makeResolver(accountID: UUID?) async throws -> any StreamResolver {
        try await resolver(accountID: accountID)
    }

    func makeDASHFragmentResolver(accountID: UUID?) async throws -> any DASHFragmentResolving {
        try await resolver(accountID: accountID)
    }

    func makeHLSPlaylistResolver(accountID: UUID?) async throws -> any HLSPlaylistResolving {
        try await hlsPlaylistResolver(accountID: accountID)
    }

    func makeExtractor() async throws -> any ExtractorEngine {
        try await extractor()
    }

    func makeResolver() async throws -> any StreamResolver {
        try await resolver()
    }

    func makeDASHFragmentResolver() async throws
        -> any DASHFragmentResolving
    {
        try await resolver()
    }

    func makeHLSPlaylistResolver() async throws
        -> any HLSPlaylistResolving
    {
        try await hlsPlaylistResolver()
    }
}
