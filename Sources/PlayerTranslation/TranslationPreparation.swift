import Foundation
import Darwin
import PlayerCore

public struct GlossaryTerm: Codable, Hashable, Sendable {
    public let german: String
    public let russian: String
    public let confirmed: Bool
    public init(german: String, russian: String, confirmed: Bool) {
        self.german = german; self.russian = russian; self.confirmed = confirmed
    }
}

public enum TranslationPreparation {
    public static func context(source: SubtitleDocument, selectedIDs: Set<Int>) -> [TranslationResponse.Row] {
        var contextIDs = Set<Int>()
        for (position, cue) in source.cues.enumerated() where selectedIDs.contains(cue.id) {
            if position > 0 { contextIDs.insert(source.cues[position - 1].id) }
            if position + 1 < source.cues.count { contextIDs.insert(source.cues[position + 1].id) }
        }
        contextIDs.subtract(selectedIDs)
        return source.cues.filter { contextIDs.contains($0.id) }.map { .init(id: $0.id, text: $0.text) }
    }

    public static func matchingTerms(_ glossary: [GlossaryTerm], cues: [SubtitleCue]) -> [GlossaryTerm] {
        let text = cues.map(\.text).joined(separator: " ").precomposedStringWithCanonicalMapping.lowercased()
        return Array(Set(glossary.filter { term in
            guard !term.german.isEmpty, term.german.count <= 80, term.russian.count <= 120 else { return false }
            let normalized = term.german.precomposedStringWithCanonicalMapping.lowercased()
            // Most glossary entries are absent. Only compile word-boundary expressions for literal matches.
            guard text.contains(normalized) else { return false }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: normalized) + "(?![\\p{L}\\p{N}])"
            return text.range(of: pattern, options: .regularExpression) != nil
        })).sorted {
            if ($0.german, $0.russian) != ($1.german, $1.russian) { return ($0.german, $0.russian) < ($1.german, $1.russian) }
            return $0.confirmed && !$1.confirmed
        }
    }

    /// Same source-driven principles as the lecture translator: quantities,
    /// negation, uncertain text, plus a small independent sample. No review-call ceiling.
    public static func reviewSelection(source: SubtitleDocument, draft: SubtitleDocument,
                                       modelFlags: Set<Int> = []) -> Set<Int> {
        guard source.cues.count == draft.cues.count else { return Set(source.cues.map(\.id)) }
        var positions = Set<Int>()
        if !source.cues.isEmpty { positions.insert(min(source.cues.count - 1, 10)) }
        for (index, pair) in zip(source.cues, draft.cues).enumerated() {
            let sourceText = pair.0.text
            let targetText = pair.1.text
            let sourceRisk = sourceText.range(of: #"\d|\b(?:nicht|kein\w*|niemals|Kontraindikation\w*|Nebenwirkung\w*|Wechselwirkung\w*|Schwanger\w*|Stillzeit|Überdos\w*)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            let targetRisk = targetText.range(of: #"неразборчив|нераспознан|непонятно|\[\?\]|\b(?:der|die|das|und|nicht|wird)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
                || targetText.contains("\u{FFFD}")
                || targetText.range(of: "[А-Яа-яЁё]", options: .regularExpression) == nil
                || targetText.count > max(80, sourceText.count * 3)
            if sourceRisk || targetRisk || modelFlags.contains(pair.0.id) {
                positions.formUnion(max(0, index - 1)...min(source.cues.count - 1, index + 1))
            }
        }
        return Set(positions.map { source.cues[$0].id })
    }

    public static func glossaryURL(for video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".lektien/glossary.json")
    }

    public static func loadGlossary(for video: URL) throws -> [GlossaryTerm] {
        let local = glossaryURL(for: video)
        let shared = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LektienPlayer/glossary.json")
        let url = FileManager.default.fileExists(atPath: local.path) ? local : shared
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let terms = try JSONDecoder().decode([GlossaryTerm].self, from: data)
        if url != local {
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = local.deletingLastPathComponent().appendingPathComponent(".glossary-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.synchronize()
            if link(temporary.path, local.path) != 0 && errno != EEXIST {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return terms
    }
}
