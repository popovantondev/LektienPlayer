import Foundation

public struct TranslationResponse: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public let id: Int
        public let text: String

        public init(id: Int, text: String) {
            self.id = id
            self.text = text
        }
    }

    public let translations: [Row]
    public let reviewIDs: [Int]?
    public let pronunciations: [PronunciationHint]?

    public init(translations: [Row], reviewIDs: [Int]? = nil, pronunciations: [PronunciationHint]? = nil) {
        self.translations = translations
        self.reviewIDs = reviewIDs
        self.pronunciations = pronunciations
    }

    public func validated(for cueIDs: [Int]) throws -> [Int: String] {
        try validateIdentifiers(for: cueIDs)
        var result: [Int: String] = [:]
        for row in translations {
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 14_000, !text.contains("\u{FFFD}"),
                  !text.contains("-->"), !text.contains("\n\n"),
                  !text.contains("<speak"), !text.contains("<prosody") else {
                throw TranslationResponseError.invalidText(row.id)
            }
            result[row.id] = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        }
        return result
    }

    public func validateIdentifiers(for cueIDs: [Int]) throws {
        let expected = Set(cueIDs)
        guard !cueIDs.isEmpty, expected.count == cueIDs.count, translations.count == cueIDs.count,
              Set(translations.map(\.id)) == expected else {
            throw TranslationResponseError.mismatchedCueIDs
        }
        guard Set(reviewIDs ?? []).isSubset(of: expected) else { throw TranslationResponseError.mismatchedCueIDs }
    }
}

public enum TranslationResponseError: LocalizedError, Equatable {
    case mismatchedCueIDs
    case invalidText(Int)

    public var errorDescription: String? {
        switch self {
        case .mismatchedCueIDs: return AppLocalization.coreText("translation.mismatchedIDs")
        case .invalidText(let id): return String(format: AppLocalization.coreText("translation.invalidText"), id)
        }
    }
}
