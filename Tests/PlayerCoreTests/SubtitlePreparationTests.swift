import Testing
@testable import PlayerCore

@Test func keepsCueBoundariesWhenPreparingTranslationParts() throws {
    let document = try SubtitleDocument(cues: [
        .init(identifier: 1, start: 0, end: 1, text: String(repeating: "a", count: 30)),
        .init(identifier: 2, start: 1, end: 2, text: String(repeating: "b", count: 30)),
        .init(identifier: 3, start: 2, end: 3, text: String(repeating: "c", count: 30))
    ])

    let plan = try SubtitlePreparer.makePlan(document: document, preferredCharacterLimit: 150, hardCharacterLimit: 180)
    #expect(plan.segments.map(\.cueIDs) == [[1], [2], [3]])
    #expect(plan.cueCount == 3)
    #expect(plan.oversizedCueIDs.isEmpty)
}

@Test func reportsCueThatCannotBeSplitWithoutBreakingTiming() throws {
    let document = try SubtitleDocument(cues: [
        .init(identifier: 7, start: 0, end: 2, text: String(repeating: "x", count: 200))
    ])

    let plan = try SubtitlePreparer.makePlan(document: document, preferredCharacterLimit: 100, hardCharacterLimit: 150)
    #expect(plan.segments.map(\.cueIDs) == [[7]])
    #expect(plan.oversizedCueIDs == [7])
}
