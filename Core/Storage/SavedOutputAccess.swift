import Foundation

struct SavedOutputReferences: Codable, Equatable, Sendable {
    enum Location: Codable, Equatable, Sendable {
        case downloads(String)
        case external(String)
    }
    struct File: Codable, Equatable, Sendable {
        let recordedURL: URL
        let location: Location
    }
    var files: [File] = []
    var folderBookmark: Data?
    var folderURL: URL?
}

enum SavedOutputAccessFailure: Error, Equatable, LocalizedError, Sendable {
    case missing, authorizationRequired, unavailable
    var errorDescription: String? {
        switch self {
        case .missing: "The saved file is missing from its recorded location."
        case .authorizationRequired: "Choose the saved folder to restore access."
        case .unavailable: "The saved file location is unavailable."
        }
    }
}

struct SavedOutputBookmark: Sendable {
    let url: URL
    let stale: Bool
    static func resolve(_ data: Data) throws -> Self {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withoutUI],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        return Self(url: url, stale: stale)
    }
}

/// The only place that translates saved output identity into current file access.
/// Old absolute URLs remain backward-readable; they never authorize a basename search.
// FileManager operations used here are thread safe; scope state is immutable or
// held by a session. No delegate or shared mutable FileManager configuration is set.
struct SavedOutputResolver: @unchecked Sendable {
    let documentsURL: URL
    let temporaryURL: URL
    let pendingSharesURL: URL
    private let resolveBookmark: @Sendable (Data) throws -> SavedOutputBookmark
    private let securityScope: ExportSecurityScope
    private let fileManager: FileManager
    var downloadsURL: URL { documentsURL.appending(path: "Downloads", directoryHint: .isDirectory) }

    init(documentsURL: URL? = nil, temporaryURL: URL? = nil, pendingSharesURL: URL? = nil,
         fileManager: FileManager = .default,
         resolveBookmark: @escaping @Sendable (Data) throws -> SavedOutputBookmark = SavedOutputBookmark.resolve,
         securityScope: ExportSecurityScope = .system) {
        self.fileManager = fileManager
        self.documentsURL = documentsURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.temporaryURL = temporaryURL ?? fileManager.temporaryDirectory
        self.pendingSharesURL = pendingSharesURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: AppIdentity.storageDirectoryName + "/PendingShares", directoryHint: .isDirectory)
        self.resolveBookmark = resolveBookmark
        self.securityScope = securityScope
    }

    func references(for urls: [URL], previous: SavedOutputReferences? = nil, folderBookmark: Data? = nil) -> SavedOutputReferences? {
        guard !urls.isEmpty else { return nil }
        let bookmark = previous?.folderBookmark ?? folderBookmark
        let needsFolder = urls.contains { url in
            previous?.files.contains(where: { $0.recordedURL == url }) != true && ownedRelativePath(url) == nil
        }
        let folder = needsFolder ? bookmark.flatMap { try? resolveBookmark($0).url } : previous?.folderURL
        var result = SavedOutputReferences(folderBookmark: bookmark, folderURL: previous?.folderURL ?? folder)
        for url in urls {
            guard Self.localComponents(url) != nil else { continue }
            if let saved = previous?.files.first(where: { $0.recordedURL == url }) { result.files.append(saved) }
            else if let relative = ownedRelativePath(url) { result.files.append(.init(recordedURL: url, location: .downloads(relative))) }
            else if let folder, let relative = Self.relativePath(url, under: folder) {
                result.files.append(.init(recordedURL: url, location: .external(relative)))
            }
        }
        if !result.files.contains(where: { if case .external = $0.location { true } else { false } }) {
            result.folderBookmark = nil; result.folderURL = nil
        }
        return result.files.isEmpty ? nil : result
    }

    func open(_ record: HistoryRecord, fallbackBookmark: Data? = nil, allowMissing: Bool = false) -> SavedOutputAccessSession {
        let references = references(for: record.ownedFileURLs, previous: record.outputReferences, folderBookmark: fallbackBookmark) ?? SavedOutputReferences()
        var urls: [URL: URL] = [:], roots: [URL: URL] = [:], failures: [URL: SavedOutputAccessFailure] = [:]
        var external: Set<URL> = []
        var folderAccess: SavedOutputFolderAccess?
        var folderResult: Result<URL, SavedOutputAccessFailure>?
        for original in record.ownedFileURLs {
            do {
                guard Self.localComponents(original) != nil else { throw SavedOutputAccessFailure.unavailable }
                let target: URL, root: URL
                if let reference = references.files.first(where: { $0.recordedURL == original }) {
                    switch reference.location {
                    case let .downloads(relative):
                        root = downloadsURL; target = try Self.child(relative, under: root)
                    case let .external(relative):
                        if folderResult == nil {
                            do {
                                guard let data = references.folderBookmark else { throw SavedOutputAccessFailure.authorizationRequired }
                                let folder = try resolveBookmark(data)
                                guard !folder.stale, folder.url.isFileURL else { throw SavedOutputAccessFailure.authorizationRequired }
                                let started = securityScope.startAccessing(folder.url)
                                guard started || isInCurrentContainer(folder.url) else { throw SavedOutputAccessFailure.authorizationRequired }
                                if started { folderAccess = SavedOutputFolderAccess(url: folder.url, stop: securityScope.stopAccessing) }
                                folderResult = .success(folder.url)
                            } catch { folderResult = .failure(.authorizationRequired) }
                        }
                        guard let folderResult else { throw SavedOutputAccessFailure.authorizationRequired }
                        root = try folderResult.get(); target = try Self.child(relative, under: root)
                        external.insert(original)
                    }
                } else if Self.relativePath(original, under: temporaryURL) != nil {
                    root = temporaryURL; target = original.standardizedFileURL
                } else if Self.relativePath(original, under: pendingSharesURL) != nil {
                    root = pendingSharesURL; target = original.standardizedFileURL
                } else {
                    throw record.destination == .filesFolder || record.destination == .filesAndPhotos
                        ? SavedOutputAccessFailure.authorizationRequired : .unavailable
                }
                try Self.validate(target, under: root, allowDirectory: original == record.packageURL, allowMissing: allowMissing)
                urls[original] = target; roots[original] = root
            } catch {
                failures[original] = (error as? SavedOutputAccessFailure) ?? (Self.isMissing(error) ? .missing
                    : external.contains(original) && Self.isPermissionDenied(error) ? .authorizationRequired : .unavailable)
            }
        }
        return SavedOutputAccessSession(urls: urls, failures: failures, roots: roots,
            external: external, packageURL: record.packageURL,
            folderAccess: external.contains(where: { urls[$0] != nil }) ? folderAccess : nil, fileManager: fileManager)
    }

    func reauthorizedReferences(for record: HistoryRecord, folderURL: URL, bookmark: Data, previousBookmark: Data?) throws -> SavedOutputReferences {
        let old = references(for: record.ownedFileURLs, previous: record.outputReferences, folderBookmark: previousBookmark) ?? SavedOutputReferences()
        if let expected = old.folderBookmark.flatMap({ try? resolveBookmark($0).url }) ?? old.folderURL {
            guard expected.standardizedFileURL.resolvingSymlinksInPath() == folderURL.standardizedFileURL.resolvingSymlinksInPath() else {
                throw SavedOutputAccessFailure.authorizationRequired
            }
        } else {
            // Legacy records without a resolvable bookmark require the actual recorded
            // folder path. Explicit selection cannot redirect a record by basename.
            guard record.ownedFileURLs.contains(where: { Self.relativePath($0, under: folderURL) != nil }) else {
                throw SavedOutputAccessFailure.authorizationRequired
            }
        }
        var result = SavedOutputReferences(folderBookmark: bookmark, folderURL: folderURL)
        for url in record.ownedFileURLs {
            if let file = old.files.first(where: { $0.recordedURL == url }), case .downloads = file.location {
                result.files.append(file); continue
            }
            let relative: String
            if let file = old.files.first(where: { $0.recordedURL == url }), case let .external(saved) = file.location { relative = saved }
            else if let path = Self.relativePath(url, under: folderURL) { relative = path }
            else { throw SavedOutputAccessFailure.authorizationRequired }
            _ = try Self.child(relative, under: folderURL)
            result.files.append(.init(recordedURL: url, location: .external(relative)))
        }
        return result
    }

    private func isInCurrentContainer(_ url: URL) -> Bool {
        [documentsURL, temporaryURL, pendingSharesURL].contains {
            Self.localComponents(url) == Self.localComponents($0) || Self.relativePath(url, under: $0) != nil
        }
    }

    private func ownedRelativePath(_ url: URL) -> String? {
        if let path = Self.relativePath(url, under: downloadsURL) { return path }
        guard let parts = Self.localComponents(url) else { return nil }
        for index in parts.indices where parts[index] == "Application" {
            guard index >= 2,
                  parts[index - 2] == "Containers", parts[index - 1] == "Data",
                  parts.count > index + 4, UUID(uuidString: parts[index + 1]) != nil,
                  parts[index + 2] == "Documents", parts[index + 3] == "Downloads" else { continue }
            let prefix = Array(parts.prefix(index - 2))
            let physical = prefix == ["/", "var", "mobile"] || prefix == ["/", "private", "var", "mobile"]
            let simulator = prefix.count == 9 && prefix[0] == "/" && prefix[1] == "Users"
                && Array(prefix[3...6]) == ["Library", "Developer", "CoreSimulator", "Devices"]
                && UUID(uuidString: prefix[7]) != nil && prefix[8] == "data"
            guard physical || simulator else { continue }
            let relative = parts.dropFirst(index + 4).joined(separator: "/")
            return (try? Self.child(relative, under: downloadsURL)) == nil ? nil : relative
        }
        return nil
    }

    static func relativePath(_ url: URL, under root: URL) -> String? {
        guard let parts = localComponents(url), let base = localComponents(root) else { return nil }
        guard parts.starts(with: base), parts.count > base.count else { return nil }
        return parts.dropFirst(base.count).joined(separator: "/")
    }

    fileprivate static func localComponents(_ url: URL) -> [String]? {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !url.pathComponents.contains("..") else { return nil }
        var parts = url.standardizedFileURL.pathComponents
        // Normalize only the OS's /var alias. Resolving the full child path here
        // would hide a symlink that validation must reject.
        if parts.count >= 3, parts[1] == "private", parts[2] == "var" { parts.remove(at: 1) }
        return parts
    }

    private static func child(_ relative: String, under root: URL) throws -> URL {
        let parts = relative.components(separatedBy: "/")
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }) else {
            throw SavedOutputAccessFailure.unavailable
        }
        return parts.reduce(root.standardizedFileURL) { $0.appendingPathComponent($1) }
    }

    fileprivate static func validate(_ url: URL, under root: URL, allowDirectory: Bool, allowMissing: Bool = false) throws {
        guard let relative = relativePath(url, under: root) else { throw SavedOutputAccessFailure.unavailable }
        var path = root.standardizedFileURL
        let parts = relative.components(separatedBy: "/")
        for index in 0...parts.count {
            if index > 0 { path.appendPathComponent(parts[index - 1]) }
            do {
                let values = try path.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                guard values.isSymbolicLink != true,
                      index < parts.count ? values.isDirectory == true : (values.isRegularFile == true || (allowDirectory && values.isDirectory == true)) else {
                    throw SavedOutputAccessFailure.unavailable
                }
            } catch {
                if allowMissing && isMissing(error) { return }
                throw error
            }
        }
        guard url.resolvingSymlinksInPath().pathComponents.starts(with: root.resolvingSymlinksInPath().pathComponents) else {
            throw SavedOutputAccessFailure.unavailable
        }
    }

    fileprivate static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }

    fileprivate static func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code)
    }
}

private final class SavedOutputFolderAccess: @unchecked Sendable {
    let url: URL
    private let stop: @Sendable (URL) -> Void
    init(url: URL, stop: @escaping @Sendable (URL) -> Void) { self.url = url; self.stop = stop }
    deinit { stop(url) }
}

/// Retain this session for the full player/share lifetime. One folder grant covers
/// all contained outputs, and is released only after the last consumer is gone.
final class SavedOutputAccessSession: @unchecked Sendable {
    let id = UUID()
    let urls: [URL: URL]
    let failures: [URL: SavedOutputAccessFailure]
    private let roots: [URL: URL]
    private let external: Set<URL>
    private let packageURL: URL?
    private let folderAccess: SavedOutputFolderAccess?
    private let fileManager: FileManager

    fileprivate init(urls: [URL: URL], failures: [URL: SavedOutputAccessFailure], roots: [URL: URL], external: Set<URL>,
                     packageURL: URL?, folderAccess: SavedOutputFolderAccess?, fileManager: FileManager) {
        self.urls = urls; self.failures = failures; self.roots = roots; self.external = external
        self.packageURL = packageURL; self.folderAccess = folderAccess; self.fileManager = fileManager
    }

    func read<Value>(_ original: URL, operation: (URL) throws -> Value) throws -> Value {
        do { return try coordinate(original, deleting: false, operation: operation) }
        catch {
            if SavedOutputResolver.isMissing(error) { throw SavedOutputAccessFailure.missing }
            if external.contains(original), SavedOutputResolver.isPermissionDenied(error) { throw SavedOutputAccessFailure.authorizationRequired }
            throw error
        }
    }

    func remove(_ original: URL) throws {
        try coordinate(original, deleting: true) { url in
            do { try fileManager.removeItem(at: url) }
            catch { if !SavedOutputResolver.isMissing(error) { throw error } }
        }
    }

    private func coordinate<Value>(_ original: URL, deleting: Bool, operation: (URL) throws -> Value) throws -> Value {
        guard let url = urls[original], let root = roots[original] else { throw failures[original] ?? .unavailable }
        func perform(_ current: URL) throws -> Value {
            guard SavedOutputResolver.localComponents(current) == SavedOutputResolver.localComponents(url) else { throw SavedOutputAccessFailure.unavailable }
            try SavedOutputResolver.validate(current, under: root, allowDirectory: original == packageURL, allowMissing: deleting)
            return try operation(current)
        }
        guard external.contains(original) else { return try perform(url) }
        var error: NSError?, result: Result<Value, Error>?
        let coordinator = NSFileCoordinator()
        let accessor: (URL) -> Void = { current in result = Result { try perform(current) } }
        if deleting { coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &error, byAccessor: accessor) }
        else { coordinator.coordinate(readingItemAt: url, options: [], error: &error, byAccessor: accessor) }
        if let error { throw error }
        guard let result else { throw SavedOutputAccessFailure.unavailable }
        return try result.get()
    }
}
