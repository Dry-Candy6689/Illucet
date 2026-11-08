import Foundation

private struct ParsedWebVTTCue: Equatable, Sendable {
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let payload: [String]
}

struct SubtitleRenderCue: Codable, Equatable, Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let text: String
}

enum WebVTTProcessor {
    static let maximumInputBytes = 2 * 1_024 * 1_024
    static let maximumOutputBytes = 4 * 1_024 * 1_024
    static let maximumLineBytes = 16 * 1_024
    static let maximumCueBytes = 128 * 1_024
    static let maximumCueCount = 20_000

    static func processTransportResponse(
        _ data: Data,
        as kind: SubtitleSidecarKind
    ) throws -> Data {
        do {
            return try process(data, as: kind)
        } catch SubtitlePipelineError.invalidWebVTT {
            throw SubtitlePipelineError.unusableResponse(
                responseClassification(for: data)
            )
        }
    }

    static func process(
        _ data: Data,
        as kind: SubtitleSidecarKind
    ) throws -> Data {
        guard !data.isEmpty, data.count <= maximumInputBytes else {
            throw data.isEmpty
                ? SubtitlePipelineError.invalidWebVTT
                : SubtitlePipelineError.responseTooLarge
        }
        guard var text = String(data: data, encoding: .utf8) else {
            throw SubtitlePipelineError.invalidWebVTT
        }
        if text.first == "\u{feff}" {
            text.removeFirst()
        }
        guard !containsProhibitedControl(text) else {
            throw SubtitlePipelineError.invalidWebVTT
        }
        let trimmedPrefix = text.prefix(256)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard
            !trimmedPrefix.hasPrefix("<html"),
            !trimmedPrefix.hasPrefix("<!doctype"),
            !trimmedPrefix.hasPrefix("{"),
            !trimmedPrefix.hasPrefix("[")
        else {
            throw SubtitlePipelineError.invalidWebVTT
        }

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard
            let first = lines.first,
            first == "WEBVTT"
                || first.hasPrefix("WEBVTT ")
                || first.hasPrefix("WEBVTT\t"),
            lines.allSatisfy({ $0.utf8.count <= maximumLineBytes })
        else {
            throw SubtitlePipelineError.invalidWebVTT
        }

        let parsed = try parse(lines)
        guard !parsed.isEmpty else {
            throw SubtitlePipelineError.invalidWebVTT
        }
        let output: String
        switch kind {
        case .webVTT:
            output = normalizedVTT(lines)
        case .subRip:
            output = renderSRT(parsed)
        }
        guard let encoded = output.data(using: .utf8),
              encoded.count <= maximumOutputBytes
        else {
            throw SubtitlePipelineError.responseTooLarge
        }
        return encoded
    }

    static func renderingCues(_ data: Data) throws -> [SubtitleRenderCue] {
        let normalized = try process(data, as: .webVTT)
        guard let text = String(data: normalized, encoding: .utf8) else {
            throw SubtitlePipelineError.invalidWebVTT
        }
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        return try parse(lines).map { cue in
            let rendered = try plainText(cue.payload)
            return SubtitleRenderCue(
                startSeconds: Double(cue.startMilliseconds) / 1_000,
                endSeconds: Double(cue.endMilliseconds) / 1_000,
                text: rendered
            )
        }
    }

    static func responseClassification(
        for data: Data
    ) -> SubtitleResponseClassification {
        guard !data.isEmpty,
              var text = String(data: data, encoding: .utf8)
        else {
            return data.isEmpty ? .emptyBody : .otherNonWebVTTBody
        }
        if text.first == "\u{feff}" { text.removeFirst() }
        let content = text.drop(while: { $0.isWhitespace })
        guard !content.isEmpty else { return .emptyBody }
        let bounded = String(content.prefix(512))
        let lowercased = bounded.lowercased()
        let htmlTags = [
            "html", "head", "body", "title", "meta", "script", "style",
            "h1", "h2", "h3", "div", "p",
        ]
        let startsWithHTMLTag = htmlTags.contains { tag in
            lowercased.hasPrefix("<\(tag)>")
                || lowercased.hasPrefix("<\(tag) ")
                || lowercased.hasPrefix("<\(tag)/")
        }
        if lowercased.hasPrefix("<!doctype html") || startsWithHTMLTag {
            return .HTMLBody
        }
        if (try? JSONSerialization.jsonObject(
            with: Data(content.utf8),
            options: [.fragmentsAllowed]
        )) != nil {
            return .JSONBody
        }
        if lowercased.hasPrefix("<") {
            return .XMLBody
        }
        let firstLine = String(
            content.prefix { $0 != "\n" && $0 != "\r" }
        )
        if firstLine == "WEBVTT"
            || firstLine.hasPrefix("WEBVTT ")
            || firstLine.hasPrefix("WEBVTT\t") {
            return .webVTTParserRejected
        }
        return .otherNonWebVTTBody
    }

    private static func plainText(_ lines: [String]) throws -> String {
        var output = ""
        for (lineIndex, line) in lines.enumerated() {
            if lineIndex > 0 { output.append("\n") }
            var insideTag = false
            var tag = ""
            for character in line {
                if character == "<" {
                    insideTag = true
                    tag = ""
                    continue
                }
                if insideTag {
                    if character == ">" {
                        if tag.lowercased().hasPrefix("br") {
                            output.append("\n")
                        }
                        insideTag = false
                    } else if tag.count < 256 {
                        tag.append(character)
                    }
                    continue
                }
                output.append(character)
            }
            if insideTag {
                throw SubtitlePipelineError.invalidWebVTT
            }
        }
        output = output
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, output.utf8.count <= 16 * 1_024 else {
            throw SubtitlePipelineError.invalidWebVTT
        }
        return output
    }

    private static func parse(
        _ lines: [String]
    ) throws -> [ParsedWebVTTCue] {
        var index = 1
        while index < lines.count, !lines[index].isEmpty {
            guard !lines[index].contains("-->") else {
                throw SubtitlePipelineError.invalidWebVTT
            }
            index += 1
        }
        while index < lines.count, lines[index].isEmpty { index += 1 }

        var cues: [ParsedWebVTTCue] = []
        while index < lines.count {
            var block: [String] = []
            while index < lines.count, !lines[index].isEmpty {
                block.append(lines[index])
                index += 1
            }
            while index < lines.count, lines[index].isEmpty { index += 1 }
            guard !block.isEmpty else { continue }

            if isMetadataBlock(block[0]) { continue }
            let timestampIndex: Int
            if block[0].contains("-->") {
                timestampIndex = 0
            } else {
                guard block.count >= 2,
                      !block[0].trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty,
                      block[0].utf8.count <= 512,
                      block[1].contains("-->")
                else {
                    throw SubtitlePipelineError.invalidWebVTT
                }
                timestampIndex = 1
            }
            let timing = try parseTiming(block[timestampIndex])
            let payload = Array(block.dropFirst(timestampIndex + 1))
            let payloadBytes = payload.reduce(0) {
                $0 + $1.utf8.count + 1
            }
            guard
                !payload.isEmpty,
                payloadBytes <= maximumCueBytes,
                cues.count < maximumCueCount
            else {
                throw SubtitlePipelineError.invalidWebVTT
            }
            cues.append(
                ParsedWebVTTCue(
                    startMilliseconds: timing.0,
                    endMilliseconds: timing.1,
                    payload: payload
                )
            )
        }
        return cues
    }

    private static func parseTiming(
        _ line: String
    ) throws -> (Int64, Int64) {
        guard let arrow = line.range(of: "-->"),
              line[arrow.upperBound...].range(of: "-->") == nil
        else {
            throw SubtitlePipelineError.invalidWebVTT
        }
        let startText = line[..<arrow.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let remainder = line[arrow.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        guard !startText.isEmpty, !remainder.isEmpty else {
            throw SubtitlePipelineError.invalidWebVTT
        }
        let endText = remainder.split(
            whereSeparator: { $0 == " " || $0 == "\t" }
        ).first.map(String.init) ?? ""
        let start = try timestampMilliseconds(startText)
        let end = try timestampMilliseconds(endText)
        guard end > start else {
            throw SubtitlePipelineError.invalidWebVTT
        }
        return (start, end)
    }

    private static func timestampMilliseconds(
        _ value: String
    ) throws -> Int64 {
        let components = value.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard components.count == 2 || components.count == 3 else {
            throw SubtitlePipelineError.invalidWebVTT
        }
        let hourText = components.count == 3 ? components[0] : "0"
        let minuteText = components[components.count - 2]
        let secondParts = components.last?.split(
            separator: ".",
            omittingEmptySubsequences: false
        ) ?? []
        guard
            secondParts.count == 2,
            minuteText.count == 2,
            secondParts[0].count == 2,
            secondParts[1].count == 3,
            !hourText.isEmpty,
            hourText.count <= 4,
            let hours = Int64(hourText),
            let minutes = Int64(minuteText),
            let seconds = Int64(secondParts[0]),
            let milliseconds = Int64(secondParts[1]),
            hours >= 0,
            minutes >= 0 && minutes < 60,
            seconds >= 0 && seconds < 60,
            milliseconds >= 0 && milliseconds < 1_000
        else {
            throw SubtitlePipelineError.invalidWebVTT
        }
        let hourMilliseconds = hours.multipliedReportingOverflow(
            by: 3_600_000
        )
        let minuteMilliseconds = minutes.multipliedReportingOverflow(
            by: 60_000
        )
        guard
            !hourMilliseconds.overflow,
            !minuteMilliseconds.overflow
        else {
            throw SubtitlePipelineError.invalidWebVTT
        }
        let first = hourMilliseconds.partialValue.addingReportingOverflow(
            minuteMilliseconds.partialValue
        )
        let second = seconds.multipliedReportingOverflow(by: 1_000)
        let third = first.partialValue.addingReportingOverflow(
            second.partialValue
        )
        let fourth = third.partialValue.addingReportingOverflow(milliseconds)
        guard
            !first.overflow,
            !second.overflow,
            !third.overflow,
            !fourth.overflow
        else {
            throw SubtitlePipelineError.invalidWebVTT
        }
        return fourth.partialValue
    }

    private static func renderSRT(
        _ cues: [ParsedWebVTTCue]
    ) -> String {
        cues.enumerated().map { offset, cue in
            "\(offset + 1)\n"
                + "\(SRTTimestamp(cue.startMilliseconds)) --> "
                + "\(SRTTimestamp(cue.endMilliseconds))\n"
                + cue.payload.joined(separator: "\n")
        }.joined(separator: "\n\n") + (cues.isEmpty ? "" : "\n")
    }

    private static func SRTTimestamp(_ milliseconds: Int64) -> String {
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(
            format: "%02lld:%02lld:%02lld,%03lld",
            hours,
            minutes,
            seconds,
            remainder
        )
    }

    private static func normalizedVTT(_ lines: [String]) -> String {
        var result = lines
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n") + "\n"
    }

    private static func isMetadataBlock(_ line: String) -> Bool {
        let first = line.split(
            whereSeparator: { $0 == " " || $0 == "\t" }
        ).first?.uppercased() ?? ""
        return first == "NOTE" || first == "STYLE" || first == "REGION"
    }

    private static func containsProhibitedControl(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            ($0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t")
                || $0.value == 0x7f
        }
    }
}
