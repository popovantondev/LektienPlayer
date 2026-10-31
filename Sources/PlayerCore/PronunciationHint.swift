import Foundation
import CryptoKit
import Darwin

/// Identifier readings are separate from subtitles and never execute model output.
public struct PronunciationHint: Codable, Equatable, Sendable {
    public let id: Int
    public let source: String
    public let spoken: String

    public init(id: Int, source: String, spoken: String) {
        self.id = id; self.source = source; self.spoken = spoken
    }

    public var isValid: Bool {
        guard !source.isEmpty, source.count <= 80, spoken.count <= 240 else { return false }
        if source.range(of: #"\A[А-Яа-яЁё]+(?:[ -][А-Яа-яЁё]+)+\z"#, options: .regularExpression) != nil {
            // Contextual stress may annotate a phrase, never rewrite its words.
            let scalars = spoken.unicodeScalars
            let plain = String(String.UnicodeScalarView(scalars.filter { $0.value != 0x0301 }))
            guard plain == source, scalars.contains(where: { $0.value == 0x0301 }) else { return false }
            var accents = 0
            var previous: Unicode.Scalar?
            for scalar in spoken.unicodeScalars {
                if scalar.value == 0x0301 {
                    guard let previous, "аеёиоуыэюяАЕЁИОУЫЭЮЯ".unicodeScalars.contains(previous), accents == 0 else { return false }
                    accents += 1
                } else if !CharacterSet.letters.contains(scalar) { accents = 0 }
                previous = scalar
            }
            return true
        }
        return source.count <= 80
            && source.range(of: #"\A[\p{Latin}\p{Greek}–—-]+\z"#, options: .regularExpression) != nil
            && source.range(of: #"[\p{Latin}\p{Greek}]"#, options: .regularExpression) != nil
            && spoken.range(of: #"\A[А-Яа-яЁё]+(?:[ -][А-Яа-яЁё]+)*\z"#, options: .regularExpression) != nil
    }

    public func occurs(in text: String) -> Bool {
        text.range(of: "(?<![\\p{L}\\p{M}\\p{N}])" + NSRegularExpression.escapedPattern(for: source)
            + "(?![\\p{L}\\p{M}\\p{N}])", options: .regularExpression) != nil
    }
}

/// Portable per-video hints. Conflicting readings fall back to the local engine
/// or the explicit user dictionary instead of silently choosing a model guess.
public enum PronunciationHintCache {
    private static func location(video: URL) -> URL {
        let key = SHA256.hash(data: Data(video.lastPathComponent.utf8)).map { String(format: "%02x", $0) }.joined()
        return video.deletingLastPathComponent().appendingPathComponent(".lektien/pronunciation-hints/\(key).json")
    }

    public static func load(video: URL) -> [PronunciationHint] {
        guard let data = try? Data(contentsOf: location(video: video)),
              let stored = try? JSONDecoder().decode([PronunciationHint].self, from: data) else { return [] }
        let groups = Dictionary(grouping: stored.filter(\.isValid), by: { $0.source.lowercased() })
        return groups.values.compactMap { values in
            Set(values.map { $0.spoken.lowercased() }).count == 1 ? values.first : nil
        }.sorted { $0.source < $1.source }
    }

    public static func store(_ response: TranslationResponse, video: URL) throws {
        let rows = try response.validated(for: response.translations.map(\.id))
        let hints = (response.pronunciations ?? []).filter {
            $0.isValid && rows[$0.id].map($0.occurs(in:)) == true
        }
        guard !hints.isEmpty else { return }
        let url = location(video: video)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        var saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([PronunciationHint].self, from: $0) } ?? []
        for hint in hints where !saved.contains(where: { $0.source == hint.source && $0.spoken == hint.spoken }) {
            saved.append(hint)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(saved)
        guard (try? Data(contentsOf: url)) != data else { return }
        try data.write(to: url, options: .atomic)
    }
}
