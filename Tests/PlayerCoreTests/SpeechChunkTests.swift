import XCTest
import PlayerCore
import PlayerSpeech

final class SpeechChunkTests: XCTestCase {
    func testChunkTimingAndSeekPriorityWithoutPreparingWholeLecture() throws {
        let source = try SubtitleDocument(cues: (0..<25).map {
            .init(identifier: $0 + 1, start: Double($0 * 8), end: Double($0 * 8 + 6), text: "Это цельная фраза.")
        })
        let plan = try SpeechChunkPlanner.makePlan(source)
        XCTAssertGreaterThan(plan.count, 3)
        XCTAssertEqual(plan.first?.end, 16)
        XCTAssertEqual(plan.flatMap { $0.document.cues.map(\.id) }, source.cues.map(\.id))
        for chunk in plan {
            for cue in chunk.document.cues {
                XCTAssertEqual(cue.start + chunk.start, source.cues[cue.id - 1].start)
                XCTAssertEqual(cue.end + chunk.start, source.cues[cue.id - 1].end)
            }
        }
        XCTAssertEqual(SpeechChunkPlanner.needed(plan, at: 0, prepared: []).map(\.id), [0, 1])
        let nearEnd = SpeechChunkPlanner.needed(plan, at: 150, prepared: [])
        XCTAssertGreaterThan(nearEnd.first!.id, 1)
        XCTAssertEqual(SpeechChunkPlanner.bufferedSeconds(plan, at: 4, prepared: [0, 2]), 12)
        XCTAssertEqual(SpeechChunkPlanner.bufferedSeconds(plan, at: 4, prepared: [0, 1]), 60)
    }
}
