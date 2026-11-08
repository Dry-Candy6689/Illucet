import Foundation

/// Only callers that already own a validated local root may use this helper.
/// Account storage, external providers and unrelated private files keep their policy.
enum BackgroundFileProtection {
    static var attributes: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }

    static func protect(_ url: URL, under root: URL, fileManager: FileManager = .default) throws {
        let base = root.standardizedFileURL
        let target = url.standardizedFileURL
        let components = target.pathComponents
        let rootComponents = base.pathComponents
        guard target.isFileURL, root.isFileURL, components.starts(with: rootComponents) else { throw Failure.invalidOwnedPath }
        var path = base
        var paths = [base]
        for component in components.dropFirst(rootComponents.count) {
            path.appendPathComponent(component)
            paths.append(path)
        }
        for path in paths {
            let values = try path.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink == false, values.isDirectory == true || values.isRegularFile == true else {
                throw Failure.invalidOwnedPath
            }
        }
        let resolvedBase = base.resolvingSymlinksInPath().pathComponents
        guard target.resolvingSymlinksInPath().pathComponents.starts(with: resolvedBase) else { throw Failure.invalidOwnedPath }
        if try fileManager.attributesOfItem(atPath: target.path)[.protectionKey] as? String != FileProtectionType.completeUntilFirstUserAuthentication.rawValue {
            try fileManager.setAttributes(attributes, ofItemAtPath: target.path)
        }
    }

    static func protectTree(_ url: URL, under root: URL, fileManager: FileManager = .default) throws {
        try protect(url, under: root, fileManager: fileManager)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { return }
        guard let entries = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else {
            throw Failure.invalidOwnedPath
        }
        for case let entry as URL in entries {
            try Task.checkCancellation()
            try protect(entry, under: root, fileManager: fileManager)
        }
    }

    static func protectJobLocal(_ url: URL, jobID: UUID, fileManager: FileManager = .default) throws {
        let root = fileManager.temporaryDirectory.appending(path: "Illucet-\(jobID.uuidString)", directoryHint: .isDirectory)
        guard url.standardizedFileURL.pathComponents.starts(with: root.standardizedFileURL.pathComponents) else { return }
        try protect(url, under: root, fileManager: fileManager)
    }

    enum Failure: Error { case invalidOwnedPath }
}
