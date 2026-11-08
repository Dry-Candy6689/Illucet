import Foundation

struct DiagnosticEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let level: DiagnosticLogLevel
    let subsystem: String
    let event: String
    let detail: String?

    init(
        level: DiagnosticLogLevel,
        subsystem: String,
        event: String,
        detail: String? = nil
    ) {
        id = UUID()
        date = .now
        self.level = level
        self.subsystem = String(subsystem.prefix(64))
        self.event = String(event.prefix(128))
        self.detail = detail.map {
            DiagnosticRedactor.redact(String($0.prefix(2_048)))
        }
    }
}
enum DiagnosticRedactor {
    private static let URLExpression = try? NSRegularExpression(
        pattern: #"https?://[^\s"']+"#,
        options: [.caseInsensitive]
    )
    private static let sensitiveExpression = try? NSRegularExpression(
        pattern:
            #"(?i)(authorization|cookie|token|signature|sig|nsig|password)\s*[:=]\s*[^\s,;]+"#
    )

    static func redact(_ value: String) -> String {
        var result = value
        let full = NSRange(result.startIndex..., in: result)
        result = sensitiveExpression?.stringByReplacingMatches(
            in: result,
            range: full,
            withTemplate: "$1=[REDACTED]"
        ) ?? result
        let URLRange = NSRange(result.startIndex..., in: result)
        result = URLExpression?.stringByReplacingMatches(
            in: result,
            range: URLRange,
            withTemplate: "[URL REDACTED]"
        ) ?? result
        return result
    }
}

/// A deliberately narrow projection of resolved-stream state for transport
/// measurement. Signed URLs, query values, request headers, and raw downloader
/// options are not stored by this type and therefore cannot reach diagnostics.
struct StreamTransportDiagnosticFacts: Equatable, Sendable {
    let formatID: String
    let mediaRole: String
    let expectedBytes: Int64?
    let sourceType: String
    let protocolName: String
    let hostname: String
    let httpChunkSize: Int64?
    let challengeResolutionSucceeded: Bool
    let availabilityWaitSeconds: Int?

    init(stream: ResolvedStream) {
        formatID = Self.safeAtom(stream.formatID, maximum: 256)
        mediaRole = switch (stream.hasVideo, stream.hasAudio) {
        case (true, true): "video_audio"
        case (true, false): "video"
        case (false, true): "audio"
        case (false, false): "unknown"
        }
        expectedBytes = stream.expectedBytes
        sourceType = Self.safeAtom(stream.sourceType, maximum: 64)
        protocolName = Self.safeAtom(stream.protocolName, maximum: 32)
        hostname = Self.safeAtom(
            stream.URL.host()?.lowercased() ?? "unknown",
            maximum: 253
        )
        httpChunkSize = stream.httpChunkSize.flatMap { value in
            (1...YTDLPStreamResolver.maximumHTTPChunkSize).contains(value)
                ? value
                : nil
        }
        challengeResolutionSucceeded = true
        availabilityWaitSeconds = stream.availableAt.flatMap { date in
            guard (try? MediaAvailability.validated(date)) != nil else { return nil }
            return Int(ceil(max(0, date.timeIntervalSinceNow)))
        }
    }

    var resolutionDetail: String {
        var fields = [
            "format_id=\(formatID)",
            "role=\(mediaRole)",
            "expected_bytes=\(expectedBytes.map(String.init) ?? "unknown")",
            "source_type=\(sourceType)",
            "protocol=\(protocolName)",
            "host=\(hostname)",
            "http_chunk_size=\(httpChunkSize.map(String.init) ?? "absent")",
            "challenge_resolved=\(challengeResolutionSucceeded)",
        ]
        if let availabilityWaitSeconds {
            fields.append("availability_wait_seconds=\(availabilityWaitSeconds)")
        }
        return fields.joined(separator: ", ")
    }

    func completionDetail(
        actualBytes: Int64,
        rollingBytesPerSecond: Double?,
        reusedSource: Bool,
        transferStrategy: StreamTransferStrategy? = nil,
        plannedRangeCount: Int = 0,
        requestedRangeCount: Int = 0,
        verifiedReusableBytes: Int64 = 0,
        networkBytesReceived: Int64 = 0
    ) -> String {
        let expectedMatch = expectedBytes.map {
            String($0 == actualBytes)
        } ?? "unknown"
        let rollingThroughput = rollingBytesPerSecond.flatMap { value in
            guard
                value.isFinite,
                value >= 0,
                value <= Double(Int64.max)
            else { return nil }
            return String(Int64(value.rounded()))
        } ?? "unknown"
        return [
            "format_id=\(formatID)",
            "role=\(mediaRole)",
            "actual_bytes=\(actualBytes)",
            "expected_bytes=\(expectedBytes.map(String.init) ?? "unknown")",
            "expected_bytes_match=\(expectedMatch)",
            "rolling_bytes_per_second=\(rollingThroughput)",
            "source_reused=\(reusedSource)",
            "strategy=\(transferStrategy?.rawValue ?? (reusedSource ? "source_reuse" : "unknown"))",
            "planned_ranges=\(max(0, plannedRangeCount))",
            "requested_ranges=\(max(0, requestedRangeCount))",
            "verified_reusable_bytes=\(max(0, verifiedReusableBytes))",
            "network_bytes_received=\(max(0, networkBytesReceived))",
        ].joined(separator: ", ")
    }

    private static func safeAtom(
        _ value: String,
        maximum: Int
    ) -> String {
        var result = ""
        result.reserveCapacity(min(value.utf8.count, maximum))
        for scalar in value.unicodeScalars.prefix(maximum) {
            let number = scalar.value
            let allowed = (48...57).contains(number)
                || (65...90).contains(number)
                || (97...122).contains(number)
                || [43, 45, 46, 95].contains(number)
            result.unicodeScalars.append(
                allowed ? scalar : UnicodeScalar(95)!
            )
        }
        return result.isEmpty ? "unknown" : result
    }
}

/// Secret-free projection of an ephemeral DASH plan. Fragment URLs, request
/// headers, and staging paths are deliberately absent.
struct DASHTransportDiagnosticFacts: Equatable, Sendable {
    let formatID: String
    let mediaRole: String
    let expectedBytes: Int64?
    let fragmentCount: Int

    init(plan: ResolvedDASHFragmentPlan) {
        formatID = String(plan.formatID.prefix(256))
        mediaRole = switch (plan.hasVideo, plan.hasAudio) {
        case (true, true): "video_audio"
        case (true, false): "video"
        case (false, true): "audio"
        case (false, false): "unknown"
        }
        expectedBytes = plan.expectedBytes
        fragmentCount = max(0, plan.fragments.count)
    }

    var resolutionDetail: String {
        [
            "format_id=\(formatID)",
            "role=\(mediaRole)",
            "expected_bytes=\(expectedBytes.map(String.init) ?? "unknown")",
            "source_type=dash",
            "protocol=http_dash_segments",
            "fragment_count=\(fragmentCount)",
        ].joined(separator: ", ")
    }

    func completionDetail(
        actualBytes: Int64,
        rollingBytesPerSecond: Double?,
        reusedSource: Bool
    ) -> String {
        let expectedMatch = expectedBytes.map {
            String($0 == actualBytes)
        } ?? "unknown"
        let rollingThroughput = rollingBytesPerSecond.flatMap { value in
            guard value.isFinite, value >= 0, value <= Double(Int64.max)
            else { return nil }
            return String(Int64(value.rounded()))
        } ?? "unknown"
        return [
            "format_id=\(formatID)",
            "role=\(mediaRole)",
            "actual_bytes=\(actualBytes)",
            "expected_bytes=\(expectedBytes.map(String.init) ?? "unknown")",
            "expected_bytes_match=\(expectedMatch)",
            "rolling_bytes_per_second=\(rollingThroughput)",
            "source_reused=\(reusedSource)",
            "strategy=\(reusedSource ? "source_reuse" : "dash_fragments")",
            "fragment_count=\(fragmentCount)",
        ].joined(separator: ", ")
    }
}

/// Secret-free projection of an ephemeral HLS selection. Playlist/resource
/// URLs, request headers, staging paths, and raw manifests are absent.
struct HLSTransportDiagnosticFacts: Equatable, Sendable {
    let formatID: String
    let mediaRole: String
    let protocolName: String
    let playlistRequestCount: Int
    let resourceCount: Int

    init(selection: ResolvedHLSPlaylistSelection) {
        formatID = String(selection.formatID.prefix(256))
        mediaRole = switch (selection.hasVideo, selection.hasAudio) {
        case (true, true): "video_audio"
        case (true, false): "video"
        case (false, true): "audio"
        case (false, false): "unknown"
        }
        protocolName = selection.protocolName
        playlistRequestCount = max(0, selection.playlistRequestCount)
        resourceCount = selection.resourcePlan.events.count {
            $0.resource != nil
        }
    }

    var resolutionDetail: String {
        [
            "format_id=\(formatID)",
            "role=\(mediaRole)",
            "source_type=hls",
            "protocol=\(protocolName)",
            "playlist_requests=\(playlistRequestCount)",
            "resource_count=\(resourceCount)",
        ].joined(separator: ", ")
    }

    func completionDetail(
        actualBytes: Int64,
        rollingBytesPerSecond: Double?,
        reusedSource: Bool
    ) -> String {
        let rollingThroughput = rollingBytesPerSecond.flatMap { value in
            guard value.isFinite, value >= 0, value <= Double(Int64.max)
            else { return nil }
            return String(Int64(value.rounded()))
        } ?? "unknown"
        return [
            "format_id=\(formatID)",
            "role=\(mediaRole)",
            "actual_bytes=\(actualBytes)",
            "expected_bytes=unknown",
            "expected_bytes_match=unknown",
            "rolling_bytes_per_second=\(rollingThroughput)",
            "source_reused=\(reusedSource)",
            "strategy=\(reusedSource ? "source_reuse" : "hls_resources")",
            "resource_count=\(resourceCount)",
        ].joined(separator: ", ")
    }
}

actor DiagnosticStore {
    private let fileManager: FileManager
    private let logURL: URL
    private var entries: [DiagnosticEntry] = []
    private let maximumEntries = 2_000

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let root = rootURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(
            path: AppIdentity.storageDirectoryName,
            directoryHint: .isDirectory
        )
        logURL = root.appending(path: "Diagnostics.json")
    }

    func load() {
        guard
            let data = try? Data(contentsOf: logURL),
            let loaded = try? JSONDecoder.illucetDecoder.decode(
                [DiagnosticEntry].self,
                from: data
            )
        else { return }
        entries = Array(loaded.suffix(maximumEntries))
    }

    func record(
        _ level: DiagnosticLogLevel,
        subsystem: String,
        event: String,
        detail: String? = nil
    ) {
        entries.append(
            DiagnosticEntry(
                level: level,
                subsystem: subsystem,
                event: event,
                detail: detail
            )
        )
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        persist()
    }

    func allEntries() -> [DiagnosticEntry] {
        entries.reversed()
    }

    func clear() { try? clearReportingFailure() }

    func clearReportingFailure() throws {
        if fileManager.fileExists(atPath: logURL.path) { try fileManager.removeItem(at: logURL) }
        entries = []
    }

    func exportReport(
        environment: [String: String],
        jobs: [DownloadJob]
    ) throws -> URL {
        let reportRoot = fileManager.temporaryDirectory.appending(
            path: "Illucet-Diagnostics-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: reportRoot,
            withIntermediateDirectories: true
        )
        let reportURL = reportRoot.appending(path: "Illucet-Diagnostics.txt")
        var lines = [
            "\(AppIdentity.displayName) diagnostics",
            "Generated: \(Date.now.formatted(.iso8601))",
            "",
            "Environment",
        ]
        for key in environment.keys.sorted() {
            lines.append("\(key): \(DiagnosticRedactor.redact(environment[key] ?? ""))")
        }
        lines.append("")
        lines.append("Jobs")
        for job in jobs {
            lines.append(
                "\(job.id.uuidString): \(job.state.rawValue), "
                    + "\(job.stage.rawValue), formats=\(job.selectedFormatIDs.joined(separator: ","))"
            )
        }
        lines.append("")
        lines.append("Events")
        for entry in entries {
            let detail = entry.detail.map { " — \($0)" } ?? ""
            lines.append(
                "\(entry.date.formatted(.iso8601)) [\(entry.level.rawValue)] "
                    + "\(entry.subsystem).\(entry.event)\(detail)"
            )
        }
        try Data(lines.joined(separator: "\n").utf8).write(
            to: reportURL,
            options: [.atomic, .completeFileProtection]
        )
        return reportURL
    }

    private func persist() {
        do {
            try fileManager.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder.illucetEncoder.encode(entries).write(
                to: logURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            // Diagnostics must never make the primary workflow fail.
        }
    }
}

/// Opt-in observational SponsorBlock events. Callers supply only bounded
/// categorical facts; the shared store applies its final redaction boundary.
actor SponsorBlockDiagnosticLogger {
    private let store: DiagnosticStore
    private var enabled = false

    init(store: DiagnosticStore) {
        self.store = store
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }

    func record(
        _ level: DiagnosticLogLevel = .info,
        event: String,
        detail: String? = nil
    ) async {
        guard enabled else { return }
        await store.record(
            level,
            subsystem: "sponsorblock",
            event: event,
            detail: detail
        )
    }
}
