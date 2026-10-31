import Foundation
import PlayerCore

/// Request-local IDs keep sparse ASR identifiers out of model bookkeeping.
/// Every output key is required by the schema; timing and persistent IDs stay local.
struct TranslationWireFormat {
    let cueIDs: [Int]

    init(cueIDs: [Int]) throws {
        guard !cueIDs.isEmpty, Set(cueIDs).count == cueIDs.count else { throw TranslationFailure.invalidInput }
        self.cueIDs = cueIDs
    }

    func rows(_ rows: [TranslationResponse.Row]) throws -> [TranslationResponse.Row] {
        let indices = Dictionary(uniqueKeysWithValues: cueIDs.enumerated().map { ($0.element, $0.offset + 1) })
        guard rows.count == cueIDs.count, Set(rows.map(\.id)) == Set(cueIDs) else { throw TranslationFailure.invalidInput }
        return rows.map { .init(id: indices[$0.id]!, text: $0.text) }
    }

    func schema() throws -> Data {
        let ids = Array(1...cueIDs.count)
        let keys = ids.map(String.init)
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["translations", "reviewIDs", "pronunciations"],
            "properties": [
                "translations": ["type": "object", "additionalProperties": false, "required": keys,
                    "properties": Dictionary(uniqueKeysWithValues: keys.map { ($0, ["type": "string", "minLength": 1,
                        "maxLength": 14_000, "pattern": "^[^\\uFFFD]*[^\\s\\uFFFD][^\\uFFFD]*$"] as [String: Any]) })],
                "reviewIDs": ["type": "array", "items": ["type": "integer", "enum": ids]],
                "pronunciations": ["type": "array", "items": ["type": "object", "additionalProperties": false,
                    "required": ["id", "source", "spoken"], "properties": [
                        "id": ["type": "integer", "enum": ids],
                        "source": ["type": "string", "minLength": 1, "maxLength": 80],
                        "spoken": ["type": "string", "minLength": 1, "maxLength": 240]
                    ]]]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
    }

    func decode(_ data: Data) throws -> TranslationResponse {
        struct Answer: Decodable {
            let translations: [String: String]; let reviewIDs: [Int]
            let pronunciations: [PronunciationHint]?
        }
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        let ids = Set(1...cueIDs.count)
        guard Set(answer.translations.keys) == Set(ids.map(String.init)),
              Set(answer.reviewIDs).isSubset(of: ids) else { throw TranslationResponseError.mismatchedCueIDs }
        let response = TranslationResponse(translations: cueIDs.enumerated().map {
            .init(id: $0.element, text: answer.translations[String($0.offset + 1)]!)
        }, reviewIDs: answer.reviewIDs.map { cueIDs[$0 - 1] }, pronunciations: (answer.pronunciations ?? []).compactMap {
            guard ids.contains($0.id), $0.isValid, $0.occurs(in: answer.translations[String($0.id)] ?? "") else { return nil }
            return .init(id: cueIDs[$0.id - 1], source: $0.source, spoken: $0.spoken)
        })
        _ = try response.validated(for: cueIDs)
        return response
    }
}
