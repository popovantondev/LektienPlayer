import Testing
@testable import PlayerCore

@Test func acceptsExactlyOneTranslationForEachCue() throws {
    let response = TranslationResponse(translations: [.init(id: 1, text: "  Привет  "), .init(id: 2, text: "Мир")])
    #expect(try response.validated(for: [1, 2]) == [1: "Привет", 2: "Мир"])
}

@Test func rejectsMissingOrDuplicateCueIDs() {
    let response = TranslationResponse(translations: [.init(id: 1, text: "Первый"), .init(id: 1, text: "Повтор")])
    #expect(throws: TranslationResponseError.mismatchedCueIDs) {
        _ = try response.validated(for: [1, 2])
    }
}
