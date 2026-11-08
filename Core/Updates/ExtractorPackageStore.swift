import CryptoKit
import Foundation

/// The single metadata file is the commit point. Generations are never edited
/// after publication, and the running interpreter retains its original path.
final class ExtractorPackageStore: @unchecked Sendable {
    struct Selection: Sendable {
        let manifest: ExtractorPackageManifest
        let sitePackages: URL
    }

    private struct State: Codable {
        var schemaVersion = 1
        var active: String?
        var previous: String?
        var pending: String?
        var launching: String?
        var resetPending = false
    }

    // Serialize different service/runtime instances sharing the same store.
    private static let lock = NSLock()
    let root: URL
    private let fm = FileManager.default

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExtractorPackages", isDirectory: true)
    }

    init(root: URL = ExtractorPackageStore.defaultRoot) { self.root = root }

    func currentSelection() throws -> Selection? {
        try Self.lock.withLock { try selection(readState().active) }
    }

    func previousSelection() throws -> Selection? {
        try Self.lock.withLock { try selection(readState().previous) }
    }

    /// Reuse next-launch activation and its rollback; never mutate a running interpreter.
    func restorePrevious() throws {
        try Self.lock.withLock {
            var state = try readState()
            guard state.pending == nil, !state.resetPending, state.launching == nil,
                  let previous = try selection(state.previous) else {
                throw ExtractorPackageError.invalidState
            }
            state.pending = previous.manifest.generation
            try writeState(state)
        }
    }

    func pendingSelection() throws -> Selection? {
        try Self.lock.withLock { try selection(readState().pending) }
    }

    func pendingResetToBundled() throws -> Bool {
        try Self.lock.withLock { try readState().resetPending }
    }

    /// Bootstrap must handle corrupt selected files itself so it can reject
    /// that generation and try the previous/bundled runtime. This predicate
    /// inspects only the durable selection state, never package contents.
    func requiresRuntimeActivation() throws -> Bool {
        try Self.lock.withLock {
            let state = try readState()
            return state.active != nil || state.pending != nil
                || state.launching != nil || state.resetPending
        }
    }

    func prepareForLaunch() throws -> Selection? {
        try Self.lock.withLock {
            var state = try readState()
            if state.launching != nil {
                state.active = state.previous
                state.previous = nil
                state.launching = nil
            }
            if state.resetPending {
                state.previous = state.active
                state.active = nil
                state.pending = nil
                state.resetPending = false
            } else if let pending = state.pending {
                state.previous = state.active
                state.active = pending
                state.pending = nil
            }
            // A corrupt pending/active generation must never enter sys.path.
            // Persist its rejection before returning the previous generation.
            let result: Selection?
            do { result = try selection(state.active) }
            catch {
                state.active = state.previous
                state.previous = nil
                do { result = try selection(state.active) }
                catch { state.active = nil; result = nil }
            }
            state.launching = state.active
            try writeState(state)
            removeUnreferencedGenerations(state)
            return result
        }
    }

    func confirmLaunch(generation: String) throws {
        try Self.lock.withLock {
            var state = try readState()
            guard state.active == generation, state.launching == generation
            else { throw ExtractorPackageError.invalidState }
            _ = try selection(generation)
            state.launching = nil
            try writeState(state)
        }
    }

    func rejectLaunch(generation: String) throws -> Selection? {
        try Self.lock.withLock {
            var state = try readState()
            guard state.active == generation, state.launching == generation
            else { throw ExtractorPackageError.invalidState }
            state.active = state.previous
            state.previous = nil
            var result: Selection?
            do { result = try selection(state.active) }
            catch { state.active = nil; result = nil }
            state.launching = state.active
            try writeState(state)
            return result
        }
    }

    func restoreBundled() throws {
        try Self.lock.withLock {
            var state = try readState()
            state.resetPending = true
            state.pending = nil
            try writeState(state)
        }
    }

    func createStagingDirectory() throws -> URL {
        try Self.lock.withLock {
            try ensureRoot()
            let directory = root.appendingPathComponent("staging-" + UUID().uuidString)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                   attributes: Self.directoryAttributes)
            return directory
        }
    }

    func publish(_ manifest: ExtractorPackageManifest, staging: URL) throws {
        try Self.lock.withLock {
            try manifest.validate()
            try ensureRoot()
            guard staging.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
                  staging.lastPathComponent.hasPrefix("staging-")
            else { throw ExtractorPackageError.unsafePath }
            try requireDirectory(staging)
            let packages = staging.appendingPathComponent("site-packages")
            guard try Self.hashTree(packages) == manifest.fileHashes
            else { throw ExtractorPackageError.checksumMismatch }
            try protectedWrite(JSONEncoder().encode(manifest),
                               to: staging.appendingPathComponent("manifest.json"))
            let destination = root.appendingPathComponent(manifest.generation)
            guard !fm.fileExists(atPath: destination.path)
            else { throw ExtractorPackageError.invalidState }
            var state = try readState()
            try fm.moveItem(at: staging, to: destination)
            try protectGeneration(destination)
            // If metadata commit fails, this directory is an unreferenced orphan;
            // the previous metadata and active runtime remain intact.
            state.pending = manifest.generation
            state.resetPending = false
            try writeState(state)
        }
    }

    static func hashTree(_ directory: URL) throws -> [String: String] {
        let fm = FileManager.default
        let base = try fm.attributesOfItem(atPath: directory.path)
        guard base[.type] as? FileAttributeType == .typeDirectory
        else { throw ExtractorPackageError.unsafePath }
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: directory,
            includingPropertiesForKeys: nil, errorHandler: { _, error in
                enumerationError = error; return false
            }) else { throw ExtractorPackageError.unsafePath }
        var result: [String: String] = [:]
        var total = 0
        var members = 0
        for case let url as URL in enumerator {
            members += 1
            guard members <= 12_000 else { throw ExtractorPackageError.sizeLimit }
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory
            else { throw ExtractorPackageError.unsafePath }
            if type == .typeDirectory { continue }
            guard (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  size <= 32 * 1_024 * 1_024
            else { throw ExtractorPackageError.unsafePath }
            total += size
            guard total <= 128 * 1_024 * 1_024 else { throw ExtractorPackageError.sizeLimit }
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            result[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        if let enumerationError { throw enumerationError }
        return result
    }

    private func selection(_ generation: String?) throws -> Selection? {
        guard let generation else { return nil }
        guard UUID(uuidString: generation)?.uuidString == generation
        else { throw ExtractorPackageError.invalidState }
        let directory = root.appendingPathComponent(generation)
        try requireDirectory(directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try requireFile(manifestURL, maximum: 4 * 1_024 * 1_024)
        let manifest = try JSONDecoder().decode(ExtractorPackageManifest.self,
                                              from: Data(contentsOf: manifestURL))
        try manifest.validate()
        guard manifest.generation == generation else { throw ExtractorPackageError.invalidManifest }
        let sitePackages = directory.appendingPathComponent("site-packages")
        guard try Self.hashTree(sitePackages) == manifest.fileHashes
        else { throw ExtractorPackageError.checksumMismatch }
        return Selection(manifest: manifest, sitePackages: sitePackages)
    }

    private func readState() throws -> State {
        try ensureRoot()
        let url = root.appendingPathComponent("state.json")
        if !fm.fileExists(atPath: url.path) { return State() }
        try requireFile(url, maximum: 16_384)
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        guard state.schemaVersion == 1,
              [state.active, state.previous, state.pending, state.launching]
                .compactMap({ $0 }).allSatisfy({ UUID(uuidString: $0)?.uuidString == $0 }),
              state.launching == nil || state.launching == state.active,
              state.active == nil || state.active != state.previous
        else { throw ExtractorPackageError.invalidState }
        return state
    }

    private func writeState(_ state: State) throws {
        try protectedWrite(JSONEncoder().encode(state), to: root.appendingPathComponent("state.json"))
    }

    private func protectGeneration(_ directory: URL) throws {
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil)
        else { throw ExtractorPackageError.unsafePath }
        let descendants = enumerator.allObjects.compactMap { $0 as? URL }
        for url in descendants + [directory] {
            let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory
            else { throw ExtractorPackageError.unsafePath }
            var attributes: [FileAttributeKey: Any] = [
                .posixPermissions: type == .typeDirectory ? 0o500 : 0o400,
            ]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try fm.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }

    /// Runs only at process bootstrap, before a Python interpreter uses a path.
    /// Installation/reset never remove a directory held by the running engine.
    private func removeUnreferencedGenerations(_ state: State) {
        let retained = Set([state.active, state.previous, state.pending, state.launching].compactMap { $0 })
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return }
        for child in children {
            let name = child.lastPathComponent
            guard !retained.contains(name),
                  let attributes = try? fm.attributesOfItem(atPath: child.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory
            else { continue }
            let abandonedGeneration = UUID(uuidString: name)?.uuidString == name
            let staleStage = name.hasPrefix("staging-")
                && (attributes[.modificationDate] as? Date).map {
                    $0 < Date.now.addingTimeInterval(-86_400)
                } == true
            guard abandonedGeneration || staleStage else { continue }
            // Only restore directory write permission; no symlink is followed.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
            if let enumerator = fm.enumerator(at: child, includingPropertiesForKeys: nil) {
                for case let descendant as URL in enumerator {
                    if let type = try? fm.attributesOfItem(atPath: descendant.path)[.type] as? FileAttributeType,
                       type == .typeDirectory {
                        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: descendant.path)
                    }
                }
            }
            try? fm.removeItem(at: child)
        }
    }

    private func protectedWrite(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        // The protected private parent already denies other users access. A
        // permissions refinement after the atomic commit cannot undo it and
        // must not report a committed transition as an installation failure.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static var directoryAttributes: [FileAttributeKey: Any] {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        return attributes
    }

    private func ensureRoot() throws {
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true,
                                   attributes: Self.directoryAttributes)
        }
        try requireDirectory(root)
    }

    private func requireDirectory(_ url: URL) throws {
        guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory
        else { throw ExtractorPackageError.unsafePath }
    }

    private func requireFile(_ url: URL, maximum: Int) throws {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= maximum
        else { throw ExtractorPackageError.unsafePath }
    }
}
