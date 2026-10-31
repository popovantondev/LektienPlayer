import Foundation
import PlayerCore

/// A library-local speech dictionary. It never modifies displayed or exported subtitles.
public struct SpeechPronunciation: Sendable {
    public struct Rule: Sendable {
        public let source: String
        public let spoken: String
    }
    public struct InvalidLine: Error, LocalizedError {
        public let line: Int
        public var errorDescription: String? {
            String(format: AppLocalization.text("pronunciation.invalidLine", bundle: SpeechSession.resources), line)
        }
    }
    public let rules: [Rule]

    public init(text: String) throws {
        var parsed: [Rule] = []
        var seen = Set<String>()
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let pair = line.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty,
                  seen.insert(pair[0].lowercased()).inserted else { throw InvalidLine(line: index + 1) }
            // + is editor notation. Only the speech copy receives the accent mark.
            let spoken = pair[1].replacingOccurrences(of: #"\+([аеёиоуыэюяАЕЁИОУЫЭЮЯ])"#,
                with: "$1\u{0301}", options: .regularExpression).precomposedStringWithCanonicalMapping
            guard !spoken.contains("+"), !spoken.contains("=>"),
                  !spoken.contains("<"), !spoken.contains(">"),
                  Self.validAccents(spoken) else { throw InvalidLine(line: index + 1) }
            parsed.append(.init(source: pair[0], spoken: spoken))
        }
        rules = parsed
    }

    private static func validAccents(_ text: String) -> Bool {
        var previous: Unicode.Scalar?
        var accents = 0
        let vowels = Set("аеёиоуыэюяАЕЁИОУЫЭЮЯ".unicodeScalars)
        for scalar in text.unicodeScalars {
            if scalar.value == 0x0301 {
                guard let previous, vowels.contains(previous), accents == 0 else { return false }
                accents += 1
            } else if !CharacterSet.letters.contains(scalar) { accents = 0 }
            previous = scalar
        }
        return true
    }

    public static func fileURL(video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".lektien/pronunciation.txt")
    }

    public static func customText(video: URL) throws -> String {
        let url = fileURL(video: video)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public static func load(video: URL) throws -> SpeechPronunciation {
        try withCustomText(customText(video: video), video: video)
    }

    public static func withCustomText(_ text: String, video: URL? = nil) throws -> SpeechPronunciation {
        let custom = try SpeechPronunciation(text: text)
        let url = SpeechSession.resources.url(forResource: "pronunciation", withExtension: "txt", subdirectory: "Engine")
        let defaults = try SpeechPronunciation(text: url.map { try String(contentsOf: $0, encoding: .utf8) } ?? "")
        let keys = Set(custom.rules.map { $0.source.lowercased() })
        let explicit = custom.rules + defaults.rules.filter { !keys.contains($0.source.lowercased()) }
        let reserved = Set(explicit.map { $0.source.lowercased() })
        let hints = video.map { PronunciationHintCache.load(video: $0) } ?? []
        return .init(rules: explicit + hints.filter { !reserved.contains($0.source.lowercased()) }
            .map { .init(source: $0.source, spoken: $0.spoken) })
    }

    private init(rules: [Rule]) { self.rules = rules }

    public static func save(_ text: String, video: URL) throws {
        _ = try SpeechPronunciation(text: text)
        let url = fileURL(video: video)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    public func apply(to text: String) -> String {
        guard !rules.isEmpty else { return text }
        let ordered = rules.sorted { $0.source.count > $1.source.count }
        let alternatives = ordered.map { NSRegularExpression.escapedPattern(for: $0.source) }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{M}\\p{N}])(?:\(alternatives))(?![\\p{L}\\p{M}\\p{N}])", options: .caseInsensitive) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text),
                  let rule = ordered.first(where: { $0.source.caseInsensitiveCompare(String(text[range])) == .orderedSame }),
                  let outputRange = Range(match.range, in: result) else { continue }
            let actual = String(text[range])
            let replacement: String
            if actual == rule.source {
                replacement = rule.spoken
            } else if actual == actual.uppercased() && actual != actual.lowercased() {
                replacement = rule.spoken.uppercased()
            } else if actual.first?.isUppercase == true {
                replacement = rule.spoken.prefix(1).uppercased() + rule.spoken.dropFirst()
            } else { replacement = rule.spoken }
            result.replaceSubrange(outputRange, with: replacement)
        }
        return result
    }

    /// Change only subtitle text lines; unaffected chunks keep their existing cache key.
    public func prepare(srt: String) -> String {
        var lineInCue = 0
        return srt.components(separatedBy: "\n").map { line in
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lineInCue = 0; return line }
            lineInCue += 1
            return lineInCue > 2 ? apply(to: line) : line
        }.joined(separator: "\n")
    }
}
