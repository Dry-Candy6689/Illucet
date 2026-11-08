import Foundation

enum HLSMasterVariantKind: Equatable, Sendable {
    case stream
    case audioRendition
    case videoRendition
}

struct HLSMasterVariant: Equatable, Sendable {
    let kind: HLSMasterVariantKind
    let playlistURL: URL
}

enum HLSMediaResourceKind: Equatable, Sendable {
    case initialization
    case media
}

enum HLSAES128InitializationVectorSource: Equatable, Sendable {
    case explicit
    case mediaSequence
}

struct HLSAES128Encryption: Equatable, Sendable {
    static let byteCount = 16

    let keyURL: URL
    let initializationVector: Data
    let initializationVectorSource: HLSAES128InitializationVectorSource
}

struct HLSMediaByteRange: Equatable, Sendable {
    let offset: Int64
    let length: Int64

    var streamRange: StreamByteRange? {
        let decrement = length.subtractingReportingOverflow(1)
        guard
            offset >= 0,
            length > 0,
            !decrement.overflow
        else {
            return nil
        }
        let addition = offset.addingReportingOverflow(
            decrement.partialValue
        )
        guard
            !addition.overflow
        else {
            return nil
        }
        return StreamByteRange(start: offset, end: addition.partialValue)
    }
}

struct HLSMediaResource: Equatable, Sendable {
    let position: Int
    let kind: HLSMediaResourceKind
    let URL: URL
    let byteRange: HLSMediaByteRange?
    let mediaSequence: UInt64?
    let encryption: HLSAES128Encryption?
}

enum HLSMediaPlaylistEvent: Equatable, Sendable {
    case initialization(
        eventPosition: Int,
        resource: HLSMediaResource
    )
    case media(
        eventPosition: Int,
        resource: HLSMediaResource,
        initializationEventPosition: Int?
    )
    case discontinuity(eventPosition: Int)

    var position: Int {
        switch self {
        case let .initialization(eventPosition, _),
             let .media(eventPosition, _, _),
             let .discontinuity(eventPosition):
            eventPosition
        }
    }

    var resource: HLSMediaResource? {
        switch self {
        case let .initialization(_, resource),
             let .media(_, resource, _):
            resource
        case .discontinuity:
            nil
        }
    }
}

struct HLSMediaResourcePlan: Equatable, Sendable {
    let events: [HLSMediaPlaylistEvent]
    let mediaSegmentCount: Int
    let initializationCount: Int
    let projectedByteCount: Int
}

enum HLSPlaylistDocument: Equatable, Sendable {
    case master(variants: [HLSMasterVariant])
    case media(plan: HLSMediaResourcePlan)
}

enum HLSPlaylistParser {
    static let maximumManifestBytes = 1 * 1_024 * 1_024
    static let maximumLines = 4_096
    static let maximumLineBytes = 8 * 1_024
    static let maximumVariants = 256
    static let maximumURIBytes = 16_384
    static let maximumMediaEntries = 1_024
    static let maximumInitializationDeclarations = 256
    static let maximumPlanEvents = 4_096
    static let maximumProjectedPlanBytes = 8 * 1_024 * 1_024

    static func parse(
        _ data: Data,
        finalPlaylistURL: URL
    ) throws -> HLSPlaylistDocument {
        guard
            !data.isEmpty,
            data.count <= maximumManifestBytes,
            HLSPlaylistSecurity.isAllowedPlaylistURL(finalPlaylistURL)
        else {
            throw HLSPlaylistParsingError.invalidManifest
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HLSPlaylistParsingError.invalidUTF8
        }
        guard
            !text.unicodeScalars.contains(where: {
                $0.value == 0x7f
                    || ($0.value < 0x20
                        && $0.value != 0x0a
                        && $0.value != 0x0d)
            }),
            !text.unicodeScalars.contains(where: { $0.value == 0xfeff })
        else {
            throw HLSPlaylistParsingError.controlCharacter
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.contains("\r") else {
            throw HLSPlaylistParsingError.controlCharacter
        }
        let lines = normalized.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard lines.count <= maximumLines else {
            throw HLSPlaylistParsingError.tooManyLines
        }
        guard lines.allSatisfy({ $0.utf8.count <= maximumLineBytes }) else {
            throw HLSPlaylistParsingError.lineTooLong
        }
        guard lines.first == "#EXTM3U" else {
            throw HLSPlaylistParsingError.invalidManifest
        }
        guard
            lines.dropFirst().allSatisfy({ $0 != "#EXTM3U" })
        else {
            throw HLSPlaylistParsingError.invalidManifest
        }

        let hasMasterTag = lines.contains(where: {
            $0.hasPrefix("#EXT-X-STREAM-INF")
                || $0.hasPrefix("#EXT-X-MEDIA:")
                || $0 == "#EXT-X-MEDIA"
                || $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF")
        })
        let hasMediaTag = lines.contains(where: {
            $0.hasPrefix("#EXT-X-TARGETDURATION")
                || $0.hasPrefix("#EXTINF")
                || $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE")
                || $0 == "#EXT-X-ENDLIST"
        })
        guard !(hasMasterTag && hasMediaTag) else {
            throw HLSPlaylistParsingError.mixedPlaylistKinds
        }
        if hasMasterTag {
            return try parseMaster(
                Array(lines.dropFirst()),
                finalPlaylistURL: finalPlaylistURL
            )
        }
        guard hasMediaTag else {
            throw HLSPlaylistParsingError.invalidManifest
        }
        return try parseMedia(
            Array(lines.dropFirst()),
            finalPlaylistURL: finalPlaylistURL
        )
    }

    static func exactVariant(
        in document: HLSPlaylistDocument,
        requestedMediaPlaylistURL: URL
    ) throws -> HLSMasterVariant {
        guard case let .master(variants) = document else {
            throw HLSPlaylistParsingError.invalidManifest
        }
        guard HLSPlaylistSecurity.isAllowedPlaylistURL(
            requestedMediaPlaylistURL
        ) else {
            throw HLSPlaylistParsingError.unsafeURI
        }
        let exact = variants.filter {
            $0.playlistURL.absoluteString
                == requestedMediaPlaylistURL.absoluteString
        }
        guard !exact.isEmpty else {
            throw HLSPlaylistParsingError.requestedVariantMissing
        }
        guard exact.count == 1 else {
            throw HLSPlaylistParsingError.ambiguousVariant
        }
        return exact[0]
    }

    private static func parseMaster(
        _ lines: [String],
        finalPlaylistURL: URL
    ) throws -> HLSPlaylistDocument {
        var variants: [HLSMasterVariant] = []
        var variantReferenceCount = 0
        var pendingStream = false

        for line in lines {
            if line.hasPrefix("#EXT-X-KEY") {
                throw HLSPlaylistParsingError.encryptionUnsupported
            }
            try rejectUnsupportedDirective(line)
            if pendingStream {
                guard !line.isEmpty, !line.hasPrefix("#") else {
                    throw HLSPlaylistParsingError.malformedDirective
                }
                variants.append(
                    HLSMasterVariant(
                        kind: .stream,
                        playlistURL: try resolveURI(
                            line,
                            relativeTo: finalPlaylistURL
                        )
                    )
                )
                pendingStream = false
                variantReferenceCount += 1
                guard variantReferenceCount <= maximumVariants else {
                    throw HLSPlaylistParsingError.tooManyVariants
                }
                continue
            }
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                guard line.hasPrefix("#EXT-X-STREAM-INF:") else {
                    throw HLSPlaylistParsingError.malformedDirective
                }
                let attributes = try parseAttributes(
                    String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                )
                try validateStreamAttributes(attributes)
                pendingStream = true
                continue
            }
            if line.hasPrefix("#EXT-X-MEDIA:") || line == "#EXT-X-MEDIA" {
                guard line.hasPrefix("#EXT-X-MEDIA:") else {
                    throw HLSPlaylistParsingError.malformedDirective
                }
                let attributes = try parseAttributes(
                    String(line.dropFirst("#EXT-X-MEDIA:".count))
                )
                let kind = try validateMediaAttributes(attributes)
                if let rawURI = attributes["URI"] {
                    let URL = try resolveURI(
                        rawURI,
                        relativeTo: finalPlaylistURL
                    )
                    variantReferenceCount += 1
                    guard variantReferenceCount <= maximumVariants else {
                        throw HLSPlaylistParsingError.tooManyVariants
                    }
                    if let kind {
                        variants.append(
                            HLSMasterVariant(
                                kind: kind,
                                playlistURL: URL
                            )
                        )
                    }
                }
                continue
            }
            if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF") {
                throw HLSPlaylistParsingError.unsupportedDirective
            }
            if !line.isEmpty, !line.hasPrefix("#") {
                throw HLSPlaylistParsingError.malformedDirective
            }
        }

        guard !pendingStream, !variants.isEmpty else {
            throw HLSPlaylistParsingError.malformedDirective
        }
        return .master(variants: variants)
    }

    private static func parseMedia(
        _ lines: [String],
        finalPlaylistURL: URL
    ) throws -> HLSPlaylistDocument {
        let hasEncryptionDirective = lines.contains {
            $0.hasPrefix("#EXT-X-KEY")
        }
        let encryptionCompatibilityVersion = hasEncryptionDirective
            ? try parseEncryptionCompatibilityVersion(in: lines)
            : 1
        var targetDurationCount = 0
        var segmentCount = 0
        var initializationCount = 0
        var pendingSegment = false
        var pendingByteRange: RawByteRange?
        var endListCount = 0
        var events: [HLSMediaPlaylistEvent] = []
        var resourceCount = 0
        var projectedByteCount = 0
        var activeInitializationEventPosition: Int?
        var priorMediaRange: (URL: URL, range: HLSMediaByteRange)?
        var priorInitializationRange: (URL: URL, range: HLSMediaByteRange)?
        var mediaSequenceCount = 0
        var firstMediaSequence: UInt64 = 0
        var activeEncryption: ActiveAES128Key?

        for line in lines {
            try rejectUnsupportedDirective(line)
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE") {
                guard
                    line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:"),
                    mediaSequenceCount == 0,
                    segmentCount == 0,
                    !pendingSegment,
                    endListCount == 0,
                    let sequence = strictNonnegativeUInt64(
                        line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)
                    )
                else {
                    throw HLSPlaylistParsingError.invalidMediaSequence
                }
                mediaSequenceCount += 1
                firstMediaSequence = sequence
                continue
            }
            if line.hasPrefix("#EXT-X-KEY") {
                guard !pendingSegment, endListCount == 0 else {
                    throw HLSPlaylistParsingError.malformedEncryption
                }
                activeEncryption = try parseEncryptionDirective(
                    line,
                    finalPlaylistURL: finalPlaylistURL,
                    compatibilityVersion: encryptionCompatibilityVersion
                )
                continue
            }
            if line.hasPrefix("#EXT-X-TARGETDURATION") {
                guard
                    line.hasPrefix("#EXT-X-TARGETDURATION:"),
                    let duration = UInt64(
                        line.dropFirst("#EXT-X-TARGETDURATION:".count)
                    ),
                    duration > 0
                else {
                    throw HLSPlaylistParsingError.malformedDirective
                }
                targetDurationCount += 1
                continue
            }
            if line.hasPrefix("#EXT-X-MAP") {
                guard
                    !pendingSegment,
                    endListCount == 0,
                    line.hasPrefix("#EXT-X-MAP:")
                else {
                    throw HLSPlaylistParsingError.malformedDirective
                }
                let attributes = try parseAttributes(
                    String(line.dropFirst("#EXT-X-MAP:".count))
                )
                guard
                    Set(attributes.keys).isSubset(of: ["URI", "BYTERANGE"]),
                    let rawURI = attributes["URI"]
                else {
                    throw HLSPlaylistParsingError.malformedDirective
                }
                let resourceURL = try resolveURI(
                    rawURI,
                    relativeTo: finalPlaylistURL
                )
                let byteRange = try attributes["BYTERANGE"].map {
                    let rawRange = try parseRawByteRange($0)
                    return try resolveByteRange(
                        rawRange,
                        resourceURL: resourceURL,
                        priorRange: priorInitializationRange
                    )
                }
                let encryption = try activeEncryption.map { active in
                    guard let IV = active.explicitInitializationVector else {
                        throw HLSPlaylistParsingError
                            .encryptedInitializationRequiresExplicitIV
                    }
                    return HLSAES128Encryption(
                        keyURL: active.keyURL,
                        initializationVector: IV,
                        initializationVectorSource: .explicit
                    )
                }
                if encryption != nil, byteRange != nil {
                    throw HLSPlaylistParsingError
                        .encryptedByteRangeUnsupported
                }
                initializationCount += 1
                guard initializationCount
                        <= maximumInitializationDeclarations
                else {
                    throw HLSPlaylistParsingError
                        .tooManyInitializationSections
                }
                let resource = HLSMediaResource(
                    position: resourceCount,
                    kind: .initialization,
                    URL: resourceURL,
                    byteRange: byteRange,
                    mediaSequence: nil,
                    encryption: encryption
                )
                let eventPosition = events.count
                try append(
                    .initialization(
                        eventPosition: eventPosition,
                        resource: resource
                    ),
                    to: &events,
                    projectedByteCount: &projectedByteCount
                )
                resourceCount += 1
                activeInitializationEventPosition = eventPosition
                priorInitializationRange = byteRange.map {
                    (resourceURL, $0)
                }
                continue
            }
            if line.hasPrefix("#EXTINF") {
                guard
                    !pendingSegment,
                    endListCount == 0,
                    line.hasPrefix("#EXTINF:"),
                    let comma = line.firstIndex(of: ","),
                    let duration = Double(
                        line[line.index(
                            line.startIndex,
                            offsetBy: "#EXTINF:".count
                        )..<comma]
                    ),
                    duration.isFinite,
                    duration >= 0
                else {
                    throw HLSPlaylistParsingError.malformedDirective
                }
                pendingSegment = true
                continue
            }
            if line.hasPrefix("#EXT-X-BYTERANGE") {
                guard
                    pendingSegment,
                    pendingByteRange == nil,
                    line.hasPrefix("#EXT-X-BYTERANGE:")
                else {
                    throw HLSPlaylistParsingError.malformedDirective
                }
                pendingByteRange = try parseRawByteRange(
                    String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                )
                continue
            }
            if line == "#EXT-X-DISCONTINUITY"
                || line.hasPrefix("#EXT-X-DISCONTINUITY:") {
                guard
                    line == "#EXT-X-DISCONTINUITY",
                    !pendingSegment,
                    endListCount == 0
                else {
                    throw HLSPlaylistParsingError.malformedDirective
                }
                try append(
                    .discontinuity(eventPosition: events.count),
                    to: &events,
                    projectedByteCount: &projectedByteCount
                )
                continue
            }
            if line == "#EXT-X-ENDLIST" {
                guard !pendingSegment else {
                    throw HLSPlaylistParsingError.malformedDirective
                }
                endListCount += 1
                continue
            }
            if !line.isEmpty, !line.hasPrefix("#") {
                guard pendingSegment, endListCount == 0 else {
                    throw HLSPlaylistParsingError.malformedDirective
                }
                let resourceURL = try resolveURI(
                    line,
                    relativeTo: finalPlaylistURL
                )
                let byteRange = try pendingByteRange.map {
                    try resolveByteRange(
                        $0,
                        resourceURL: resourceURL,
                        priorRange: priorMediaRange
                    )
                }
                let sequenceAddition = firstMediaSequence
                    .addingReportingOverflow(UInt64(segmentCount))
                guard !sequenceAddition.overflow else {
                    throw HLSPlaylistParsingError.invalidMediaSequence
                }
                let mediaSequence = sequenceAddition.partialValue
                let encryption = activeEncryption.map { active in
                    let source: HLSAES128InitializationVectorSource
                    let IV: Data
                    if let explicit = active.explicitInitializationVector {
                        source = .explicit
                        IV = explicit
                    } else {
                        source = .mediaSequence
                        IV = derivedInitializationVector(
                            mediaSequence: mediaSequence
                        )
                    }
                    return HLSAES128Encryption(
                        keyURL: active.keyURL,
                        initializationVector: IV,
                        initializationVectorSource: source
                    )
                }
                if encryption != nil, byteRange != nil {
                    throw HLSPlaylistParsingError
                        .encryptedByteRangeUnsupported
                }
                segmentCount += 1
                guard segmentCount <= maximumMediaEntries else {
                    throw HLSPlaylistParsingError.tooManyMediaEntries
                }
                let resource = HLSMediaResource(
                    position: resourceCount,
                    kind: .media,
                    URL: resourceURL,
                    byteRange: byteRange,
                    mediaSequence: mediaSequence,
                    encryption: encryption
                )
                try append(
                    .media(
                        eventPosition: events.count,
                        resource: resource,
                        initializationEventPosition:
                            activeInitializationEventPosition
                    ),
                    to: &events,
                    projectedByteCount: &projectedByteCount
                )
                resourceCount += 1
                priorMediaRange = byteRange.map { (resourceURL, $0) }
                pendingSegment = false
                pendingByteRange = nil
            }
        }

        guard
            targetDurationCount == 1,
            segmentCount > 0,
            !pendingSegment,
            pendingByteRange == nil,
            endListCount == 1
        else {
            throw HLSPlaylistParsingError.malformedDirective
        }
        let plan = HLSMediaResourcePlan(
            events: events,
            mediaSegmentCount: segmentCount,
            initializationCount: initializationCount,
            projectedByteCount: projectedByteCount
        )
        guard isValidMediaResourcePlan(plan) else {
            throw HLSPlaylistParsingError.invalidResourcePlan
        }
        return .media(plan: plan)
    }

    static func isValidMediaResourcePlan(
        _ plan: HLSMediaResourcePlan
    ) -> Bool {
        guard
            !plan.events.isEmpty,
            plan.events.count <= maximumPlanEvents,
            (1...maximumMediaEntries).contains(plan.mediaSegmentCount),
            (0...maximumInitializationDeclarations)
                .contains(plan.initializationCount)
        else {
            return false
        }
        var mediaCount = 0
        var initializationCount = 0
        var resourcePosition = 0
        var projectedTotal = 0
        var activeInitializationEventPosition: Int?
        var priorMediaSequence: UInt64?
        for (offset, event) in plan.events.enumerated() {
            guard event.position == offset else { return false }
            switch event {
            case let .initialization(eventPosition, resource):
                guard
                    eventPosition == offset,
                    resource.position == resourcePosition,
                    resource.kind == .initialization,
                    isValid(resource)
                else {
                    return false
                }
                initializationCount += 1
                resourcePosition += 1
                activeInitializationEventPosition = eventPosition
            case let .media(
                eventPosition,
                resource,
                initializationEventPosition
            ):
                guard let mediaSequence = resource.mediaSequence else {
                    return false
                }
                if let priorMediaSequence {
                    let next = priorMediaSequence
                        .addingReportingOverflow(1)
                    guard
                        !next.overflow,
                        next.partialValue == mediaSequence
                    else { return false }
                }
                guard
                    eventPosition == offset,
                    resource.position == resourcePosition,
                    resource.kind == .media,
                    initializationEventPosition
                        == activeInitializationEventPosition,
                    isValid(resource)
                else {
                    return false
                }
                mediaCount += 1
                resourcePosition += 1
                priorMediaSequence = mediaSequence
            case let .discontinuity(eventPosition):
                guard eventPosition == offset else { return false }
            }
            guard let next = projectedBytes(
                after: event,
                current: projectedTotal
            ) else {
                return false
            }
            projectedTotal = next
        }
        return mediaCount == plan.mediaSegmentCount
            && initializationCount == plan.initializationCount
            && projectedTotal == plan.projectedByteCount
    }

    private static func isValid(_ resource: HLSMediaResource) -> Bool {
        guard HLSPlaylistSecurity.isAllowedPlaylistURL(resource.URL) else {
            return false
        }
        switch resource.kind {
        case .initialization:
            guard resource.mediaSequence == nil else { return false }
        case .media:
            guard resource.mediaSequence != nil else { return false }
        }
        if let byteRange = resource.byteRange {
            guard
                resource.encryption == nil,
                byteRange.streamRange != nil
            else {
                return false
            }
        }
        guard let encryption = resource.encryption else { return true }
        guard
            HLSPlaylistSecurity.isAllowedPlaylistURL(encryption.keyURL),
            encryption.initializationVector.count
                == HLSAES128Encryption.byteCount
        else {
            return false
        }
        switch encryption.initializationVectorSource {
        case .explicit:
            return true
        case .mediaSequence:
            guard
                resource.kind == .media,
                let mediaSequence = resource.mediaSequence
            else {
                return false
            }
            return encryption.initializationVector
                == derivedInitializationVector(mediaSequence: mediaSequence)
        }
    }

    private static func append(
        _ event: HLSMediaPlaylistEvent,
        to events: inout [HLSMediaPlaylistEvent],
        projectedByteCount: inout Int
    ) throws {
        guard events.count < maximumPlanEvents else {
            throw HLSPlaylistParsingError.tooManyPlanEvents
        }
        guard let next = projectedBytes(
            after: event,
            current: projectedByteCount
        ) else {
            throw HLSPlaylistParsingError.planTooLarge
        }
        events.append(event)
        projectedByteCount = next
    }

    private static func projectedBytes(
        after event: HLSMediaPlaylistEvent,
        current: Int
    ) -> Int? {
        let resourceBytes = event.resource.map {
            let encryptionBytes = $0.encryption.map {
                $0.keyURL.absoluteString.utf8.count
                    + $0.initializationVector.count + 32
            } ?? 0
            return $0.URL.absoluteString.utf8.count
                + ($0.byteRange == nil ? 0 : 32)
                + 8 + encryptionBytes + 160
        } ?? 32
        let addition = current.addingReportingOverflow(resourceBytes)
        guard
            !addition.overflow,
            addition.partialValue <= maximumProjectedPlanBytes
        else {
            return nil
        }
        return addition.partialValue
    }

    private struct ActiveAES128Key {
        let keyURL: URL
        let explicitInitializationVector: Data?
    }

    private static func parseEncryptionDirective(
        _ line: String,
        finalPlaylistURL: URL,
        compatibilityVersion: UInt64
    ) throws -> ActiveAES128Key? {
        let prefix = "#EXT-X-KEY:"
        guard line.hasPrefix(prefix) else {
            throw HLSPlaylistParsingError.malformedEncryption
        }
        let text = String(line.dropFirst(prefix.count))
        let attributes: [String: ParsedAttribute]
        do {
            attributes = try parseRawAttributes(text)
        } catch {
            throw HLSPlaylistParsingError.malformedEncryption
        }
        guard
            let method = attributes["METHOD"],
            method.syntax == .unquoted
        else {
            throw HLSPlaylistParsingError.malformedEncryption
        }
        if method.value == "NONE" {
            guard attributes.count == 1 else {
                throw HLSPlaylistParsingError.malformedEncryption
            }
            return nil
        }
        guard method.value == "AES-128" else {
            throw HLSPlaylistParsingError.encryptionUnsupported
        }
        guard
            Set(attributes.keys).isSubset(
                of: ["METHOD", "URI", "IV", "KEYFORMAT"]
            ),
            let rawKeyURI = attributes["URI"],
            rawKeyURI.syntax == .quoted
        else {
            throw HLSPlaylistParsingError.malformedEncryption
        }
        if let keyFormat = attributes["KEYFORMAT"] {
            guard keyFormat.syntax == .quoted else {
                throw HLSPlaylistParsingError.malformedEncryption
            }
            guard keyFormat.value == "identity" else {
                throw HLSPlaylistParsingError
                    .nonIdentityKeyFormatUnsupported
            }
            guard compatibilityVersion >= 5 else {
                throw HLSPlaylistParsingError
                    .incompatibleEncryptionVersion
            }
        }
        let keyURL = try resolveURI(
            rawKeyURI.value,
            relativeTo: finalPlaylistURL
        )
        let explicitIV: Data?
        if let rawIV = attributes["IV"] {
            guard rawIV.syntax == .unquoted else {
                throw HLSPlaylistParsingError.malformedEncryption
            }
            explicitIV = try parseExplicitInitializationVector(
                rawIV.value
            )
            guard compatibilityVersion >= 2 else {
                throw HLSPlaylistParsingError
                    .incompatibleEncryptionVersion
            }
        } else {
            explicitIV = nil
        }
        return ActiveAES128Key(
            keyURL: keyURL,
            explicitInitializationVector: explicitIV
        )
    }

    private static func parseExplicitInitializationVector(
        _ value: String
    ) throws -> Data {
        let hex = value.dropFirst(2)
        let hexadecimalDigitCount = hex.utf8.count
        guard
            value.hasPrefix("0x") || value.hasPrefix("0X"),
            !hex.isEmpty,
            hexadecimalDigitCount <= HLSAES128Encryption.byteCount * 2,
            hex.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0)
            })
        else {
            throw HLSPlaylistParsingError.invalidInitializationVector
        }
        var normalizedHex = String(
            repeating: "0",
            count: HLSAES128Encryption.byteCount * 2
                - hexadecimalDigitCount
        )
        normalizedHex.append(contentsOf: hex)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(HLSAES128Encryption.byteCount)
        var index = normalizedHex.startIndex
        while index < normalizedHex.endIndex {
            let next = normalizedHex.index(index, offsetBy: 2)
            guard let byte = UInt8(normalizedHex[index..<next], radix: 16) else {
                throw HLSPlaylistParsingError.invalidInitializationVector
            }
            bytes.append(byte)
            index = next
        }
        guard bytes.count == HLSAES128Encryption.byteCount else {
            throw HLSPlaylistParsingError.invalidInitializationVector
        }
        return Data(bytes)
    }

    private static func parseEncryptionCompatibilityVersion(
        in lines: [String]
    ) throws -> UInt64 {
        var parsedVersion: UInt64?
        for line in lines where line.hasPrefix("#EXT-X-VERSION") {
            guard
                parsedVersion == nil,
                line.hasPrefix("#EXT-X-VERSION:"),
                let version = strictNonnegativeUInt64(
                    line.dropFirst("#EXT-X-VERSION:".count)
                ),
                version > 0
            else {
                throw HLSPlaylistParsingError.malformedDirective
            }
            parsedVersion = version
        }
        return parsedVersion ?? 1
    }

    private static func derivedInitializationVector(
        mediaSequence: UInt64
    ) -> Data {
        var bytes = [UInt8](
            repeating: 0,
            count: HLSAES128Encryption.byteCount
        )
        var remaining = mediaSequence
        for index in stride(
            from: HLSAES128Encryption.byteCount - 1,
            through: HLSAES128Encryption.byteCount - 8,
            by: -1
        ) {
            bytes[index] = UInt8(remaining & 0xff)
            remaining >>= 8
        }
        return Data(bytes)
    }

    private static func strictNonnegativeUInt64(
        _ value: Substring
    ) -> UInt64? {
        guard
            !value.isEmpty,
            value.allSatisfy({ $0.isASCII && $0.isNumber })
        else {
            return nil
        }
        return UInt64(value)
    }
    private struct RawByteRange {
        let length: Int64
        let explicitOffset: Int64?
    }

    private static func parseRawByteRange(
        _ value: String
    ) throws -> RawByteRange {
        let components = value.split(
            separator: "@",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard
            (1...2).contains(components.count),
            let length = strictNonnegativeDecimal(components[0]),
            length > 0
        else {
            throw HLSPlaylistParsingError.invalidByteRange
        }
        let offset: Int64?
        if components.count == 2 {
            guard let parsed = strictNonnegativeDecimal(components[1]) else {
                throw HLSPlaylistParsingError.invalidByteRange
            }
            offset = parsed
        } else {
            offset = nil
        }
        return RawByteRange(length: length, explicitOffset: offset)
    }

    private static func resolveByteRange(
        _ raw: RawByteRange,
        resourceURL: URL,
        priorRange: (URL: URL, range: HLSMediaByteRange)?
    ) throws -> HLSMediaByteRange {
        let offset: Int64
        if let explicitOffset = raw.explicitOffset {
            offset = explicitOffset
        } else {
            guard
                let priorRange,
                priorRange.URL.absoluteString == resourceURL.absoluteString,
                let priorStreamRange = priorRange.range.streamRange
            else {
                throw HLSPlaylistParsingError.ambiguousByteRange
            }
            let addition = priorStreamRange.end.addingReportingOverflow(1)
            guard !addition.overflow else {
                throw HLSPlaylistParsingError.invalidByteRange
            }
            offset = addition.partialValue
        }
        let range = HLSMediaByteRange(offset: offset, length: raw.length)
        guard range.streamRange != nil else {
            throw HLSPlaylistParsingError.invalidByteRange
        }
        return range
    }

    private static func strictNonnegativeDecimal(
        _ value: Substring
    ) -> Int64? {
        guard
            !value.isEmpty,
            value.allSatisfy({ $0.isASCII && $0.isNumber }),
            let parsed = Int64(value),
            parsed >= 0
        else {
            return nil
        }
        return parsed
    }

    private static func rejectUnsupportedDirective(_ line: String) throws {
        if line.hasPrefix("#EXT-X-SESSION-KEY") {
            throw HLSPlaylistParsingError.sessionKeyUnsupported
        }
        if line.hasPrefix("#EXT-X-DEFINE")
            || line.hasPrefix("#EXT-X-GAP")
            || line.hasPrefix("#EXT-X-I-FRAMES-ONLY")
            || line.hasPrefix("#EXT-X-PART")
            || line.hasPrefix("#EXT-X-PRELOAD-HINT")
            || line.hasPrefix("#EXT-X-RENDITION-REPORT")
            || line.hasPrefix("#EXT-X-SERVER-CONTROL")
            || line.hasPrefix("#EXT-X-SKIP") {
            throw HLSPlaylistParsingError.unsupportedDirective
        }
    }

    private static func resolveURI(
        _ rawURI: String,
        relativeTo baseURL: URL
    ) throws -> URL {
        try validateURIText(rawURI)
        guard
            !rawURI.hasPrefix("//"),
            let resolved = URL(
                string: rawURI,
                relativeTo: baseURL
            )?.absoluteURL,
            HLSPlaylistSecurity.isAllowedPlaylistURL(resolved)
        else {
            throw HLSPlaylistParsingError.unsafeURI
        }
        return resolved
    }

    private static func validateURIText(_ rawURI: String) throws {
        guard
            !rawURI.isEmpty,
            rawURI.utf8.count <= maximumURIBytes,
            rawURI == rawURI.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawURI.contains("\\"),
            !rawURI.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || $0.value < 0x20
                    || $0.value == 0x7f
            })
        else {
            throw HLSPlaylistParsingError.unsafeURI
        }
    }

    private static func validateStreamAttributes(
        _ attributes: [String: String]
    ) throws {
        guard
            let bandwidth = attributes["BANDWIDTH"],
            let bandwidthValue = UInt64(bandwidth),
            bandwidthValue > 0
        else {
            throw HLSPlaylistParsingError.malformedDirective
        }
        if let average = attributes["AVERAGE-BANDWIDTH"] {
            guard let value = UInt64(average), value > 0 else {
                throw HLSPlaylistParsingError.malformedDirective
            }
        }
        if let resolution = attributes["RESOLUTION"] {
            let parts = resolution.lowercased().split(separator: "x")
            guard
                parts.count == 2,
                let width = UInt64(parts[0]),
                let height = UInt64(parts[1]),
                width > 0,
                height > 0
            else {
                throw HLSPlaylistParsingError.malformedDirective
            }
        }
        if let frameRate = attributes["FRAME-RATE"] {
            guard
                let value = Double(frameRate),
                value.isFinite,
                value > 0
            else {
                throw HLSPlaylistParsingError.malformedDirective
            }
        }
    }

    private static func validateMediaAttributes(
        _ attributes: [String: String]
    ) throws -> HLSMasterVariantKind? {
        guard
            let type = attributes["TYPE"],
            let groupID = attributes["GROUP-ID"],
            !groupID.isEmpty,
            let name = attributes["NAME"],
            !name.isEmpty,
            ["AUDIO", "VIDEO", "SUBTITLES", "CLOSED-CAPTIONS"]
                .contains(type)
        else {
            throw HLSPlaylistParsingError.malformedDirective
        }
        if type == "CLOSED-CAPTIONS", attributes["URI"] != nil {
            throw HLSPlaylistParsingError.malformedDirective
        }
        return switch type {
        case "AUDIO": .audioRendition
        case "VIDEO": .videoRendition
        default: nil
        }
    }

    private static func parseAttributes(
        _ text: String
    ) throws -> [String: String] {
        try parseRawAttributes(text).mapValues { $0.value }
    }

    private enum AttributeValueSyntax: Equatable {
        case quoted
        case unquoted
    }

    private struct ParsedAttribute {
        let value: String
        let syntax: AttributeValueSyntax
    }

    private static func parseRawAttributes(
        _ text: String
    ) throws -> [String: ParsedAttribute] {
        guard !text.isEmpty else {
            throw HLSPlaylistParsingError.malformedDirective
        }
        let characters = Array(text)
        var offset = 0
        var result: [String: ParsedAttribute] = [:]

        while offset < characters.count {
            let keyStart = offset
            while offset < characters.count,
                  isAttributeNameCharacter(characters[offset]) {
                offset += 1
            }
            guard
                offset > keyStart,
                offset < characters.count,
                characters[offset] == "="
            else {
                throw HLSPlaylistParsingError.malformedDirective
            }
            let key = String(characters[keyStart..<offset])
            guard key == key.uppercased(), result[key] == nil else {
                throw HLSPlaylistParsingError.malformedDirective
            }
            offset += 1
            guard offset < characters.count else {
                throw HLSPlaylistParsingError.malformedDirective
            }

            let value: String
            let syntax: AttributeValueSyntax
            if characters[offset] == "\"" {
                syntax = .quoted
                offset += 1
                let valueStart = offset
                while offset < characters.count,
                      characters[offset] != "\"" {
                    offset += 1
                }
                guard offset < characters.count else {
                    throw HLSPlaylistParsingError.malformedDirective
                }
                value = String(characters[valueStart..<offset])
                offset += 1
            } else {
                syntax = .unquoted
                let valueStart = offset
                while offset < characters.count,
                      characters[offset] != "," {
                    offset += 1
                }
                value = String(characters[valueStart..<offset])
            }
            guard !value.isEmpty else {
                throw HLSPlaylistParsingError.malformedDirective
            }
            result[key] = ParsedAttribute(
                value: value,
                syntax: syntax
            )
            if offset < characters.count {
                guard characters[offset] == "," else {
                    throw HLSPlaylistParsingError.malformedDirective
                }
                offset += 1
                guard offset < characters.count else {
                    throw HLSPlaylistParsingError.malformedDirective
                }
            }
        }
        return result
    }

    private static func isAttributeNameCharacter(_ character: Character)
        -> Bool
    {
        character.isASCII
            && (character.isLetter
                || character.isNumber
                || character == "-")
    }
}

enum HLSPlaylistSecurity {
    static func isAllowedPlaylistURL(_ URL: URL) -> Bool {
        let raw = URL.absoluteString
        return YTDLPStreamResolver.isAllowedMediaURL(URL)
            && (URL.port == nil || URL.port == 443)
            && URL.fragment == nil
            && raw == raw.trimmingCharacters(in: .whitespacesAndNewlines)
            && !raw.contains("\\")
            && !raw.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || $0.value < 0x20
                    || $0.value == 0x7f
            })
    }

    static func areAllowedHeaders(_ headers: [String: String]) -> Bool {
        headers.count <= 6
            && Set(headers.keys.map { $0.lowercased() }).count
                == headers.count
            && headers.allSatisfy { key, value in
                !key.unicodeScalars.contains(where: Self.isControlCharacter)
                    && !value.unicodeScalars.contains(
                        where: Self.isControlCharacter
                    )
            }
            && headers.allSatisfy(YTDLPStreamResolver.isAllowedHeader)
    }

    private static func isControlCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7f
    }
}

enum HLSPlaylistParsingError: LocalizedError, Equatable, Sendable {
    case invalidManifest
    case invalidUTF8
    case controlCharacter
    case tooManyLines
    case lineTooLong
    case tooManyVariants
    case tooManyMediaEntries
    case tooManyInitializationSections
    case tooManyPlanEvents
    case planTooLarge
    case malformedDirective
    case mixedPlaylistKinds
    case requestedVariantMissing
    case ambiguousVariant
    case unsafeURI
    case invalidByteRange
    case ambiguousByteRange
    case invalidResourcePlan
    case unsupportedDirective
    case encryptionUnsupported
    case invalidMediaSequence
    case malformedEncryption
    case invalidInitializationVector
    case incompatibleEncryptionVersion
    case encryptedInitializationRequiresExplicitIV
    case encryptedByteRangeUnsupported
    case nonIdentityKeyFormatUnsupported
    case sessionKeyUnsupported

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            "The HLS playlist is invalid."
        case .invalidUTF8:
            "The HLS playlist is not valid UTF-8."
        case .controlCharacter:
            "The HLS playlist contains invalid control characters."
        case .tooManyLines, .lineTooLong, .tooManyVariants,
             .tooManyMediaEntries, .tooManyInitializationSections,
             .tooManyPlanEvents, .planTooLarge:
            "The HLS playlist exceeds Illucet's safety limits."
        case .malformedDirective, .mixedPlaylistKinds, .invalidResourcePlan:
            "The HLS playlist structure is malformed."
        case .requestedVariantMissing:
            "The exact selected HLS variant is unavailable."
        case .ambiguousVariant:
            "The exact selected HLS variant is ambiguous."
        case .unsafeURI:
            "The HLS playlist contains an unsafe URI."
        case .invalidByteRange:
            "The HLS playlist contains an invalid byte range."
        case .ambiguousByteRange:
            "The HLS playlist byte-range offset is ambiguous."
        case .invalidMediaSequence:
            "The HLS media sequence is invalid."
        case .malformedEncryption, .invalidInitializationVector:
            "The HLS encryption metadata is malformed."
        case .incompatibleEncryptionVersion:
            "The HLS playlist version is too low for its encryption attributes."
        case .encryptedInitializationRequiresExplicitIV:
            "Encrypted HLS initialization data requires an explicit IV."
        case .encryptedByteRangeUnsupported:
            "Encrypted HLS byte-range resources are not supported."
        case .nonIdentityKeyFormatUnsupported:
            "The HLS key format is not supported."
        case .sessionKeyUnsupported:
            "HLS session keys are not supported."
        case .unsupportedDirective:
            "The HLS playlist requires unsupported control-plane behavior."
        case .encryptionUnsupported:
            "The HLS encryption method is not supported."
        }
    }
}
