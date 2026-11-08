import Foundation

protocol RuntimeProviding: Sendable {
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
