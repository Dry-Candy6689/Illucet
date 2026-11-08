import Foundation

enum SubtitleFilenamePlanner {
    static let maximumFilenameBytes = 240

    static func filenames(
        mediaURL: URL,
        sidecars: [PreparedSubtitleSidecar]
    ) throws -> [String] {
        let base = safeBaseName(
            mediaURL.deletingPathExtension().lastPathComponent
        )
        return try filenames(
            base: base,
            sidecars: sidecars,
            alwaysIncludeIdentity: false
        )
    }

    static func filenames(
        title: String,
        sidecars: [PreparedSubtitleSidecar]
    ) throws -> [String] {
        try filenames(
            base: safeBaseName(title),
            sidecars: sidecars,
            alwaysIncludeIdentity: true
        )
    }

    private static func filenames(
        base: String,
        sidecars: [PreparedSubtitleSidecar],
        alwaysIncludeIdentity: Bool
    ) throws -> [String] {
        guard !base.isEmpty else {
            throw SubtitlePipelineError.invalidSelection
        }

        var reserved: Set<String> = []
        var results: [String] = []
        for sidecar in sidecars {
            let language = safeLanguage(sidecar.selection.language)
            let origin = sidecar.selection.automatic ? "auto" : "manual"
            let identity = String(sidecar.selection.trackID.suffix(8))
                + "-"
                + String(sidecar.selection.formatID.suffix(8))
            let identityComponent = alwaysIncludeIdentity
                ? ".\(identity)"
                : ""
            let suffix =
                ".\(language).\(origin)\(identityComponent).\(sidecar.kind.rawValue)"
            var stem = boundedStem(base, suffix: suffix)
            var filename = "\(stem)\(suffix)"
            var key = collisionKey(filename)
            if reserved.contains(key) {
                let identitySuffix =
                    ".\(language).\(origin).\(identity).\(sidecar.kind.rawValue)"
                stem = boundedStem(base, suffix: identitySuffix)
                filename = "\(stem)\(identitySuffix)"
                key = collisionKey(filename)
            }
            if reserved.contains(key) {
                let exactIdentity = identity
                    + "-"
                    + stableIdentityDigest(sidecar.selection)
                let exactIdentitySuffix =
                    ".\(language).\(origin).\(exactIdentity).\(sidecar.kind.rawValue)"
                stem = boundedStem(base, suffix: exactIdentitySuffix)
                filename = "\(stem)\(exactIdentitySuffix)"
                key = collisionKey(filename)
            }
            guard
                filename.utf8.count <= maximumFilenameBytes,
                reserved.insert(key).inserted,
                isSafe(filename)
            else {
                throw SubtitlePipelineError.invalidSelection
            }
            results.append(filename)
        }
        return results
    }

    static func collisionKey(_ filename: String) -> String {
        filename.precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    private static func safeBaseName(_ value: String) -> String {
        let sanitized = FilenameSystem.sanitizeComponent(
            value.precomposedStringWithCanonicalMapping
        )
        return reservedName(sanitized) ? "media-\(sanitized)" : sanitized
    }

    private static func safeLanguage(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        var scalars: [Unicode.Scalar] = []
        var previousWasSeparator = false
        for scalar in normalized.unicodeScalars {
            let isAllowed = CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-" || scalar == "_"
            if isAllowed {
                scalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                scalars.append("-")
                previousWasSeparator = true
            }
        }
        var result = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-. _"))
        if result.isEmpty { result = "und" }
        result = String(result.prefix(32))
        return reservedName(result) ? "lang-\(result)" : result
    }

    private static func boundedStem(
        _ stem: String,
        suffix: String
    ) -> String {
        let maximumStemBytes = max(1, maximumFilenameBytes - suffix.utf8.count)
        var result = ""
        for character in stem {
            let candidate = result + String(character)
            if candidate.utf8.count > maximumStemBytes { break }
            result = candidate
        }
        return result.trimmingCharacters(
            in: CharacterSet(charactersIn: ". ")
        )
    }

    private static func stableIdentityDigest(
        _ selection: SubtitleTrackSelection
    ) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in selection.trackID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        hash ^= 0xff
        hash &*= 0x100000001b3
        for byte in selection.formatID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let hexadecimal = String(hash, radix: 16, uppercase: false)
        return String(repeating: "0", count: 16 - hexadecimal.count)
            + hexadecimal
    }

    private static func reservedName(_ value: String) -> Bool {
        let stem = value.split(separator: ".").first.map(String.init) ?? value
        let upper = stem.uppercased()
        let fixed: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        if fixed.contains(upper) { return true }
        for prefix in ["COM", "LPT"] {
            if upper.count == 4,
               upper.hasPrefix(prefix),
               let digit = upper.last?.wholeNumberValue,
               (1...9).contains(digit) {
                return true
            }
        }
        return false
    }

    private static func isSafe(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.unicodeScalars.contains {
                $0.value < 0x20 || $0.value == 0x7f
            }
            && !reservedName(value)
    }
}
