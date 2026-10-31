import XCTest
import PlayerCore
import PlayerSpeech
import PlayerTranslation
@testable import LektienOnlineUebersetzung

final class RecognitionStreamingTests: XCTestCase {
    private let luna = TranslationSettings(model: "gpt-5.6-luna", effort: "medium")
    private let terra = TranslationSettings(model: "gpt-5.6-terra", effort: "medium")

    @MainActor
    func testGrowingSourceTranslatesBeforeCompletionAndResumesCachedWindows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = try SubtitleDocument(cues: [])
        let plan: [SpeechChunk] = (0..<7).map { .init(id: $0, start: Double($0 * 30), end: Double(($0 + 1) * 30), document: empty) }
        let chunks = try plan.map { chunk in
            SpeechChunk(id: chunk.id, start: chunk.start, end: chunk.end, document: try SubtitleDocument(cues: [
                .init(identifier: chunk.id * 1000 + 1, start: 1, end: 8, text: "Ein kurzer deutscher Satz.")
            ]))
        }
        let stream = StreamingTranslationController()
        stream.bufferAhead = 45
        defer { stream.reset() }
        let video = root.appendingPathComponent("sample.mp4")
        stream.startRecognizing(plan: plan, videoURL: video, translation: luna, review: terra, position: 0,
            translate: { cues, _, _ in .init(translations: cues.map { .init(id: $0.id, text: "Короткое предложение.") }) })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(stream.isRunning, stream.errorMessage ?? "")
        XCTAssertTrue(stream.ready.isEmpty)
        stream.supplyRecognized([chunks[0]])
        for _ in 0..<500 where stream.ready.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(stream.ready.map(\.id), [0], (stream.errorMessage ?? "") + " state=" + (stream.status ?? "") + " running=\(stream.isRunning) plan=\(stream.plan.count)")
        XCTAssertNil(stream.completedURL)
        stream.updatePosition(155)
        stream.supplyRecognized(Array(chunks[4...6]))
        for _ in 0..<500 where stream.ready.count < 4 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(Set(stream.ready.map(\.id)), [0, 4, 5, 6])
        XCTAssertEqual(stream.document?.cues.last?.start, 181)
        stream.reset()
        stream.startRecognizing(plan: plan, videoURL: video, translation: luna, review: terra, position: 155,
            translate: { _, _, _ in XCTFail("Ready recognition windows must not be translated again"); throw TranslationFailure.service })
        stream.supplyRecognized([chunks[0]] + Array(chunks[4...6]))
        for _ in 0..<500 where stream.ready.count < 4 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(Set(stream.ready.map(\.id)), [0, 4, 5, 6])
        XCTAssertNil(stream.errorMessage)
    }

    @MainActor
    func testSilentWindowDoesNotCallModelAndCanComplete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = try SubtitleDocument(cues: [])
        let plan = [SpeechChunk(id: 0, start: 0, end: 30, document: empty)]
        let stream = StreamingTranslationController()
        defer { stream.reset() }
        stream.startRecognizing(plan: plan, videoURL: root.appendingPathComponent("sample.mp4"), translation: luna, review: terra, position: 0,
            translate: { _, _, _ in XCTFail("Silence must not consume tokens"); throw TranslationFailure.service })
        stream.supplyRecognized(plan)
        for _ in 0..<500 where stream.completedURL == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(stream.ready.map(\.id), [0])
        XCTAssertNotNil(stream.completedURL)
        XCTAssertNil(stream.errorMessage)
    }

    @MainActor
    func testRecognizedSectionsReachTranslationAndSpeechIncrementally() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = try SubtitleDocument(cues: [])
        let plan = [
            SpeechChunk(id: 0, start: 0, end: 30, document: empty),
            SpeechChunk(id: 1, start: 30, end: 60, document: empty)
        ]
        let stream = StreamingTranslationController()
        let speech = SpeechController()
        defer { stream.reset(); speech.reset() }
        let video = root.appendingPathComponent("telegram.mp4")
        stream.startRecognizing(plan: plan, videoURL: video, translation: luna, review: terra, position: 0,
            translate: { _, _, _ in XCTFail("Recognized silence must stay local"); throw TranslationFailure.service })
        speech.startStreaming(plan: plan, videoURL: video, voice: "kseniya", position: 0)

        stream.supplyRecognized([plan[0]])
        for _ in 0..<100 where stream.ready.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        speech.supply(stream.ready)
        for _ in 0..<100 where speech.prepared.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(stream.ready.map(\.id), [0])
        XCTAssertEqual(speech.prepared.map(\.chunk.id), [0])
        XCTAssertLessThan(speech.prepared.count, plan.count)

        stream.supplyRecognized([plan[1]])
        for _ in 0..<100 where stream.ready.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        speech.supply(stream.ready)
        for _ in 0..<100 where speech.prepared.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(Set(speech.prepared.map(\.chunk.id)), [0, 1])
    }
}
