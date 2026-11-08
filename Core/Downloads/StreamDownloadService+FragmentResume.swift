import Foundation

/// Response validators are captured only for explicitly watched DASH transfers.
/// No HTTP header values survive the operation or enter durable task descriptors.
final class FragmentResponseValidators: @unchecked Sendable {
    private let lock = NSLock()
    private var watched: Set<URL> = []
    private var validators: [URL: String] = [:]

    func watch(_ destination: URL) {
        lock.lock()
        defer { lock.unlock() }
        watched.insert(destination.standardizedFileURL)
        validators[destination.standardizedFileURL] = nil
    }

    func record(_ destination: URL, response: HTTPURLResponse?) {
        lock.lock()
        defer { lock.unlock() }
        let key = destination.standardizedFileURL
        guard watched.contains(key), let response,
              response.statusCode == 200,
              let tag = response.value(forHTTPHeaderField: "ETag") else { return }
        validators[key] = FragmentResumeCheckpoint.strongValidator(["ETag": tag])
    }

    func take(_ destination: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let key = destination.standardizedFileURL
        watched.remove(key)
        return validators.removeValue(forKey: key)
    }
}

extension StreamDownloadService {
    func fragmentCheckpoint(
        jobID: UUID, formatID: String, fields: [String]
    ) throws -> FragmentResumeCheckpoint {
        try fileManager.createDirectory(at: destinationRoots.applicationSupportDirectory,
                                        withIntermediateDirectories: true)
        let checkpoint = try FragmentResumeCheckpoint(roots: destinationRoots, jobID: jobID,
            formatID: formatID, planDigest: FragmentResumeCheckpoint.fingerprint(fields),
            fileManager: fileManager)
        checkpoint.onRestart = { [fragmentResumeEvent] reason in
            fragmentResumeEvent(jobID, formatID, reason)
        }
        if let reason = checkpoint.restartReason { fragmentResumeEvent(jobID, formatID, reason) }
        return checkpoint
    }

    func discardFragmentCheckpoints(jobID: UUID, formatID: String?) throws {
        try FragmentResumeCheckpoint.discard(jobID: jobID, formatID: formatID,
            roots: destinationRoots, fileManager: fileManager)
    }

    func restoreFragment(
        checkpoint: FragmentResumeCheckpoint,
        position: Int,
        remoteURL: URL,
        headers: [String: String],
        destination: URL,
        jobID: UUID,
        expectedBytes: Int64?
    ) async throws -> Int64? {
        guard let saved = checkpoint.resource(at: position) else { return nil }
        guard saved.URLDigest == FragmentResumeCheckpoint.fingerprint([remoteURL.absoluteString]),
              expectedBytes == nil || expectedBytes == saved.byteCount else {
            try checkpoint.reject(saved, reason: .planChanged)
            return nil
        }
        guard HLSPlaylistSecurity.isAllowedPlaylistURL(remoteURL) else {
            try checkpoint.reject(saved, reason: .validatorUnavailable)
            return nil
        }
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        let policy = lifecycle.networkPolicy(jobID: jobID)
        request.allowsExpensiveNetworkAccess = policy.allowsExpensiveAccess
        request.allowsConstrainedNetworkAccess = policy.allowsConstrainedAccess
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(nil, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // The bounded client refuses redirects. A validator is never compared
        // across a different URI, even when its spelling or origin looks similar.
        let response: HLSPlaylistHTTPResponse
        do {
            response = try await fragmentValidatorNetworking.response(for: request, maximumBytes: 1)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            if FragmentURLRecovery.isExpired(error) { throw error }
            if let failure = error as? StreamDownloadError,
               case .unauthorizedHTTPFailure = failure { throw error }
            // HEAD is optional optimization evidence. Unsupported HEAD, a
            // transient probe failure or malformed validator never authorizes
            // reuse: discard that cache entry and perform the ordinary GET.
            try checkpoint.reject(saved, reason: .validatorUnavailable)
            return nil
        }
        try Task.checkCancellation()
        if response.statusCode == 403 || response.statusCode == 410 {
            throw StreamDownloadError.HTTPFailure(statusCode: response.statusCode)
        }
        guard response.statusCode == 200,
              let validator = FragmentResumeCheckpoint.strongValidator(response.headers) else {
            try checkpoint.reject(saved, reason: .validatorUnavailable)
            return nil
        }
        guard validator == saved.validatorDigest else {
            try checkpoint.reject(saved, reason: .validatorChanged)
            return nil
        }
        return try checkpoint.restore(saved, to: destination) ? saved.byteCount : nil
    }

    static func DASHResumeFields(_ plan: ResolvedDASHFragmentPlan) -> [String] {
        ["dash-v1", plan.videoID, plan.formatID, plan.protocolName, plan.sourceType,
         plan.fileExtension, String(plan.hasVideo), String(plan.hasAudio),
         plan.expectedBytes.map(String.init) ?? "unknown"] + plan.fragments.flatMap {
            [String($0.position), $0.URL.absoluteString, $0.expectedBytes.map(String.init) ?? "unknown"]
        }
    }

    static func HLSResumeFields(_ selection: ResolvedHLSPlaylistSelection) -> [String] {
        var fields = ["hls-v1", selection.videoID, selection.formatID, selection.protocolName,
                      selection.sourceType, selection.fileExtension,
                      String(selection.hasVideo), String(selection.hasAudio)]
        for event in selection.resourcePlan.events {
            fields.append(String(event.position))
            switch event {
            case .initialization: fields.append("initialization")
            case let .media(_, _, initialization):
                fields.append("media")
                fields.append(initialization.map(String.init) ?? "none")
            case .discontinuity: fields.append("discontinuity")
            }
            if let resource = event.resource {
                fields += [String(resource.position), resource.URL.absoluteString,
                           resource.mediaSequence.map(String.init) ?? "none",
                           resource.byteRange.map { "\($0.offset):\($0.length)" } ?? "none"]
            }
        }
        return fields
    }
}
