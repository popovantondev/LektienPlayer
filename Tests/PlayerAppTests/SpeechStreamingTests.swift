import XCTest
import PlayerCore
import PlayerSpeech
@testable import LektienOnlineUebersetzung

final class SpeechStreamingTests: XCTestCase {
    @MainActor
    func testPronunciationReloadReusesUnchangedAudio() async throws {
        guard ProcessInfo.processInfo.environment["LEKTIEN_STRESS_AUDIO"] == "1" else { throw XCTSkip("Opt-in local pronunciation reload") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("sample.mp4")
        let chunks = try ["Дверной замок закрыт.", "Это проверка речи."].enumerated().map { index, text in
            SpeechChunk(id: index, start: Double(index * 8), end: Double((index + 1) * 8),
                document: try SubtitleDocument(cues: [.init(identifier: index + 1, start: 0, end: 8, text: text)]))
        }
        let speech = SpeechController()
        defer { speech.reset() }
        speech.startStreaming(plan: chunks, videoURL: video, voice: "kseniya", position: 0)
        speech.supply(chunks)
        for _ in 0..<300 where speech.prepared.count < 2 && speech.errorMessage == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(speech.errorMessage)
        let old = Dictionary(uniqueKeysWithValues: speech.prepared.map { ($0.chunk.id, $0.audioURL) })
        XCTAssertEqual(old.count, 2)
        try SpeechPronunciation.save("дверной замок => дверн+ой зам+ок", video: video)
        speech.reloadPronunciation(videoURL: video, voice: "kseniya", position: 0)
        for _ in 0..<300 where speech.prepared.count < 2 && speech.errorMessage == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(speech.errorMessage)
        let new = Dictionary(uniqueKeysWithValues: speech.prepared.map { ($0.chunk.id, $0.audioURL) })
        XCTAssertEqual(new.count, 2)
        XCTAssertNotEqual(new[0], old[0])
        XCTAssertEqual(new[1], old[1])
        XCTAssertEqual(speech.plan, chunks)
    }

    @MainActor
    func testRealSpeechStartsBeforeWholeLectureAndSeekReprioritizes() async throws {
        guard let path = ProcessInfo.processInfo.environment["LEKTIEN_STREAM_FIXTURE"] else { throw XCTSkip("Opt-in local streaming test") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try SubtitleDocument(cues: (0..<25).map {
            .init(identifier: $0 + 1, start: Double($0 * 8), end: Double($0 * 8 + 6), text: "Сердце перекачивает кровь. Это проверка русской речи.")
        })
        let playback = PlaybackController()
        playback.load(url: URL(fileURLWithPath: path))
        playback.play()
        let speech = SpeechController()
        speech.bufferAhead = 60
        defer { speech.stop(); playback.player.pause(); playback.clearVoice() }
        speech.start(document: source, videoURL: root.appendingPathComponent("sample.mp4"), voice: "kseniya", position: 0)
        playback.beginSpeech(plan: speech.plan)
        XCTAssertTrue(playback.waitingForSpeech)
        for _ in 0..<150 where speech.prepared.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(speech.prepared.isEmpty, speech.status)
        XCTAssertLessThan(speech.prepared.count, speech.plan.count, "First buffer must be playable before entire lecture")
        playback.acceptSpeech(speech.prepared)
        XCTAssertFalse(playback.waitingForSpeech)
        XCTAssertGreaterThan(playback.speechBufferSeconds, 8)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(playback.voicePlayer?.isPlaying == true)
        playback.togglePlayback()
        XCTAssertFalse(playback.voicePlayer?.isPlaying ?? true)
        playback.seek(to: 150)
        speech.updatePosition(150)
        try await Task.sleep(for: .milliseconds(200))
        playback.togglePlayback()
        XCTAssertTrue(playback.waitingForSpeech)
        let desired = try XCTUnwrap(speech.plan.first { $0.start <= 150 && 150 < $0.end })
        for _ in 0..<150 where !speech.prepared.contains(where: { $0.chunk.id == desired.id }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(speech.prepared.contains { $0.chunk.id == desired.id }, speech.status)
        playback.acceptSpeech(speech.prepared)
        XCTAssertFalse(playback.waitingForSpeech)
        XCTAssertEqual(playback.voicePlayer?.currentTime ?? -1, 150 - desired.start, accuracy: 0.5)
        speech.stop()
        for _ in 0..<50 where speech.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(speech.isRunning)
        let cachedIDs = Set(speech.prepared.map { $0.chunk.id })
        speech.start(document: source, videoURL: root.appendingPathComponent("sample.mp4"), voice: "kseniya", position: 150)
        for _ in 0..<50 where speech.prepared.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(cachedIDs.isSubset(of: Set(speech.prepared.map { $0.chunk.id })), "All completed ranges must reappear, including distant cached chunks")
        speech.stop()
        for _ in 0..<50 where speech.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(speech.isRunning)
    }
}
