import Foundation

public struct SubtitleCue: Equatable, Sendable, Identifiable {
    public let identifier: Int
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public var id: Int { identifier }

    public init(identifier: Int, start: TimeInterval, end: TimeInterval, text: String) {
        self.identifier = identifier
        self.start = start
        self.end = end
        self.text = text
    }

    public func contains(_ time: TimeInterval) -> Bool {
        start <= time && time < end
    }
}

public struct SubtitleDocument: Equatable, Sendable {
    public let cues: [SubtitleCue]

    public init(cues: [SubtitleCue]) throws {
        guard cues.enumerated().allSatisfy({ index, cue in
            cue.identifier > 0 && cue.start.isFinite && cue.end.isFinite && cue.end < 1_000_000_000 && cue.start >= 0 && cue.end > cue.start &&
            (index == 0 || cues[index - 1].start <= cue.start)
        }) else {
            throw SubtitleError.invalidCueOrder
        }
        self.cues = cues
    }

    public func text(at time: TimeInterval) -> String? {
        let matches = cues.filter { $0.contains(time) }
        guard !matches.isEmpty else { return nil }
        return matches.map(\.text).joined(separator: "\n")
    }
}

public enum SubtitleError: LocalizedError, Equatable {
    case unreadableText
    case invalidBlock(Int)
    case invalidTimestamp(Int)
    case invalidCueOrder

    public var errorDescription: String? {
        switch self {
        case .unreadableText: return AppLocalization.coreText("subtitle.unreadable")
        case let .invalidBlock(number): return String(format: AppLocalization.coreText("subtitle.block"), number)
        case let .invalidTimestamp(number): return String(format: AppLocalization.coreText("subtitle.timestamp"), number)
        case .invalidCueOrder: return AppLocalization.coreText("subtitle.order")
        }
    }
}

public enum SRTParser {
    public static func parse(data: Data) throws -> SubtitleDocument {
        let text: String
        if let decoded = String(data: data, encoding: .utf8) {
            text = decoded
        } else if let decoded = String(data: data, encoding: .windowsCP1251) {
            text = decoded
        } else {
            throw SubtitleError.unreadableText
        }
        return try parse(text: text)
    }

    public static func parse(text: String) throws -> SubtitleDocument {
        let withoutBOM = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let normalized = withoutBOM
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n[ \t]*\n(?:[ \t]*\n)*", with: "\n\n", options: .regularExpression)
        guard !normalized.isEmpty else { return try SubtitleDocument(cues: []) }

        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        for (offset, block) in blocks.enumerated() {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.count >= 3, let identifier = Int(lines[0].trimmingCharacters(in: .whitespaces)) else {
                throw SubtitleError.invalidBlock(offset + 1)
            }
            let parts = lines[1].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTimestamp(parts[0]),
                  let end = parseTimestamp(parts[1]) else {
                throw SubtitleError.invalidTimestamp(identifier)
            }
            guard end > start else {
                throw SubtitleError.invalidTimestamp(identifier)
            }
            let cueText = lines.dropFirst(2).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cueText.isEmpty else { throw SubtitleError.invalidBlock(identifier) }
            cues.append(SubtitleCue(identifier: identifier, start: start, end: end, text: cueText))
        }
        return try SubtitleDocument(cues: cues)
    }

    private static func parseTimestamp(_ value: String) -> TimeInterval? {
        let pieces = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
        guard pieces.count == 3,
              let hours = Double(pieces[0]),
              let minutes = Double(pieces[1]),
              let seconds = Double(pieces[2]),
              hours.isFinite, minutes.isFinite, seconds.isFinite,
              hours >= 0, hours.rounded(.towardZero) == hours,
              minutes >= 0, minutes < 60, minutes.rounded(.towardZero) == minutes,
              seconds >= 0, seconds < 60 else { return nil }
        let result = hours * 3600 + minutes * 60 + seconds
        return result.isFinite ? result : nil
    }
}
