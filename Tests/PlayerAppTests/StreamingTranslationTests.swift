import XCTest
import Combine
import PlayerCore
import PlayerSpeech
import PlayerTranslation
@testable import LektienOnlineUebersetzung

private final class RecordedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, [Int])] = []
    var calls: [(String, [Int])] { lock.withLock { values } }
    func append(_ model: String, _ ids: [Int]) { lock.withLock { values.append((model, ids)) } }
}

final class StreamingTranslationTests: XCTestCase {
    private let luna = TranslationSettings(model: "gpt-5.6-luna", effort: "medium")
    private let terra = TranslationSettings(model: "gpt-5.6-terra", effort: "medium")

    @MainActor
    func testWholePreparationPrioritizesViewingPositionThenFillsEarlierAndLaterWindows() async throws {
        let root = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try document(count: 100)
        let records = RecordedRequests()
        let stream = StreamingTranslationController()
        defer { stream.reset() }
        stream.bufferAhead = 60
        stream.start(source: source, videoURL: root.appendingPathComponent("whole.mp4"), translation: luna, review: terra, position: 500,
            translate: { cues, settings, _ in
                records.append(settings.model, cues.map(\.id))
                return .init(translations: cues.map { .init(id: $0.id, text: "Это пример предложения.") })
            })
        stream.prepareWholeLecture = true
        for _ in 0..<500 where stream.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(stream.errorMessage)
        XCTAssertNotNil(stream.completedURL)
        XCTAssertEqual(stream.ready.count, stream.plan.count)
        XCTAssertGreaterThan(records.calls.first?.1.first ?? 0, 40, "The viewing position takes priority over earlier missing text")
        XCTAssertTrue(stream.ready.contains { $0.id == stream.plan.first?.id })
        XCTAssertTrue(stream.ready.contains { $0.id == stream.plan.last?.id })
    }

    @MainActor
    func testPausedPositionKeepsPreparingUntilRequestedTenMinuteReserve() async throws {
        let root = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try document(count: 200)
        let records = RecordedRequests()
        let stream = StreamingTranslationController()
        defer { stream.reset() }
        stream.bufferAhead = 600
        stream.start(source: source, videoURL: root.appendingPathComponent("paused.mp4"), translation: luna, review: terra, position: 0,
            translate: { cues, settings, _ in
                records.append(settings.model, cues.map(\.id))
                return .init(translations: cues.map { .init(id: $0.id, text: "Это пример предложения.") })
            })
        for _ in 0..<300 where (stream.ready.map(\.end).max() ?? 0) < 600 || stream.activeRange != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(stream.errorMessage)
        XCTAssertGreaterThanOrEqual(stream.ready.map(\.end).max() ?? 0, 600)
        XCTAssertLessThan(stream.ready.count, stream.plan.count)
        let count = records.calls.count
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(records.calls.count, count, "A full reserve must stop consuming requests even on pause")
        stream.bufferAhead = 900
        for _ in 0..<300 where (stream.ready.map(\.end).max() ?? 0) < 900 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(records.calls.count, count, "Increasing reserve on pause must resume without play or seek")
    }

    @MainActor
    func testSeekReprioritizesBothStagesAndRestartUsesSavedWindows() async throws {
        let root = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try document(count: 100)
        let records = RecordedRequests()
        let stream = StreamingTranslationController()
        defer { stream.reset() }
        stream.start(source: source, videoURL: root.appendingPathComponent("sample.mp4"), translation: luna, review: terra, position: 0,
            translate: { cues, settings, control in
                records.append(settings.model, cues.map(\.id))
                for _ in 0..<15 { try control.check(); Thread.sleep(forTimeInterval: 0.01) }
                return .init(translations: cues.map { .init(id: $0.id, text: "Это пример предложения.") })
            })
        for _ in 0..<100 where records.calls.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(records.calls.first?.1.first, 1)
        stream.updatePosition(500)
        for _ in 0..<300 where stream.ready.isEmpty || stream.activeRange != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(stream.errorMessage)
        let target = try XCTUnwrap(stream.plan.first { $0.start <= 500 && 500 < $0.end })
        XCTAssertTrue(stream.ready.contains { $0.id == target.id })
        XCTAssertLessThan(stream.ready.count, stream.plan.count)
        XCTAssertEqual(records.calls.dropFirst().first?.0, "gpt-5.6-luna", "An obsolete first packet must not be reviewed before the new position")
        XCTAssertGreaterThan(records.calls.dropFirst().first?.1.first ?? 0, 50)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sample.ru.reviewed.srt").path), "A partial lecture must never be published as complete")
        stream.stop()
        for _ in 0..<100 where stream.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        let count = records.calls.count
        stream.start(source: source, videoURL: root.appendingPathComponent("sample.mp4"), translation: luna, review: terra, position: 500,
            translate: { _, _, _ in XCTFail("Restart at a prepared position must use cache"); throw TranslationFailure.service })
        for _ in 0..<100 where stream.ready.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(stream.errorMessage)
        XCTAssertTrue(stream.ready.contains { $0.id == target.id })
        XCTAssertEqual(records.calls.count, count)
    }

    @MainActor
    func testSpeechPlaysWhileNextWindowTranslatesAndOpeningVideoDoesNotAutoplay() async throws {
        guard let path = ProcessInfo.processInfo.environment["LEKTIEN_STREAM_FIXTURE"] else { throw XCTSkip("Opt-in local voice and synthetic video") }
        let root = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try document(count: 25)
        let records = RecordedRequests()
        let playback = PlaybackController()
        let speech = SpeechController()
        let stream = StreamingTranslationController()
        var subscriptions = Set<AnyCancellable>()
        defer { stream.reset(); speech.reset(); playback.pause(); playback.clearVoice(); playback.audioMixer.reset(); subscriptions.removeAll() }
        playback.load(url: URL(fileURLWithPath: path))
        XCTAssertFalse(playback.playbackRequested)
        XCTAssertEqual(playback.player.rate, 0)
        stream.$ready.sink { speech.supply($0) }.store(in: &subscriptions)
        speech.$prepared.sink { playback.acceptSpeech($0) }.store(in: &subscriptions)
        stream.start(source: source, videoURL: root.appendingPathComponent("sample.mp4"), translation: luna, review: terra, position: 0,
            translate: { cues, settings, control in
                records.append(settings.model, cues.map(\.id))
                if settings.model == "gpt-5.6-luna", (cues.first?.id ?? 0) > 1 {
                    for _ in 0..<100 { try control.check(); Thread.sleep(forTimeInterval: 0.1) }
                }
                return .init(translations: cues.map { .init(id: $0.id, text: "Сердце перекачивает кровь.") })
            })
        speech.startStreaming(plan: stream.plan, videoURL: root.appendingPathComponent("sample.mp4"), voice: "kseniya", position: 0)
        playback.startWithSpeech(plan: stream.plan)
        XCTAssertTrue(playback.waitingForSpeech)
        XCTAssertEqual(playback.player.rate, 0)
        for _ in 0..<120 where playback.voicePlayer?.isPlaying != true { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(playback.voicePlayer?.isPlaying == true, speech.status)
        XCTAssertFalse(playback.waitingForSpeech)
        XCTAssertNotNil(stream.activeRange, "Next translation must run concurrently with ready speech")
        XCTAssertLessThan(stream.ready.count, stream.plan.count)
        XCTAssertEqual(records.calls.prefix(3).map { $0.0 }, ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-luna"])
        playback.pause()
        XCTAssertFalse(playback.voicePlayer?.isPlaying ?? true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(playback.playbackRequested, "Background preparation must preserve a user pause")
        stream.stop(); speech.stop()
        for _ in 0..<100 where stream.isRunning || speech.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    }

    @MainActor
    func testLegacyPartsFeedNewWindowsWithoutRepeatingTranslation() async throws {
        let root = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try SubtitleDocument(cues: (0..<100).map {
            .init(identifier: $0 + 1, start: Double($0 * 8), end: Double($0 * 8 + 6),
                  text: String(repeating: "Beispiel ", count: 20) + ".")
        })
        let video = root.appendingPathComponent("sample.mp4")
        XCTAssertThrowsError(try TranslationSession.run(document: source, videoURL: video, settings: luna, cancellation: .init(),
            translate: { cues, _, _ in
                guard cues.first?.id == 1 else { throw TranslationFailure.stopped }
                return .init(translations: cues.map { .init(id: $0.id, text: "Это пример предложения.") })
            }, progress: { _ in }))
        let records = RecordedRequests()
        let stream = StreamingTranslationController()
        defer { stream.reset() }
        stream.start(source: source, videoURL: video, translation: luna, review: terra, position: 0,
            translate: { cues, settings, _ in
                records.append(settings.model, cues.map(\.id))
                return .init(translations: cues.map { .init(id: $0.id, text: "Это пример предложения.") })
            })
        for _ in 0..<100 where stream.ready.isEmpty || stream.activeRange != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(stream.errorMessage)
        XCTAssertFalse(stream.ready.isEmpty)
        XCTAssertFalse(records.calls.isEmpty)
        XCTAssertTrue(records.calls.allSatisfy { $0.0 == "gpt-5.6-terra" }, "Old completed translation must not be sent to Luna again")
        stream.stop()
        for _ in 0..<100 where stream.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    }

    @MainActor
    func testLegacyBoundaryRequestsOnlyMissingRowsAndPersistsAssembledWindow() async throws {
        let root = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try SubtitleDocument(cues: (0..<100).map {
            .init(identifier: $0 + 1, start: Double($0 * 8), end: Double($0 * 8 + 6), text: String(repeating: "Beispiel ", count: 20) + ".")
        })
        let video = root.appendingPathComponent("sample.mp4")
        XCTAssertThrowsError(try TranslationSession.run(document: source, videoURL: video, settings: luna, cancellation: .init(),
            translate: { cues, _, _ in
                guard cues.first?.id == 1 else { throw TranslationFailure.stopped }
                return .init(translations: cues.map { .init(id: $0.id, text: "Это готовый перевод.") })
            }, progress: { _ in }))
        let old = try XCTUnwrap(TranslationSession.cachedPartial(document: source, videoURL: video, settings: luna))
        let oldIDs = Set(old.0.cues.map(\.id))
        let records = RecordedRequests()
        let stream = StreamingTranslationController()
        defer { stream.reset() }
        stream.start(source: source, videoURL: video, translation: luna, review: terra, position: 300,
            translate: { cues, settings, _ in
                records.append(settings.model, cues.map(\.id))
                return .init(translations: cues.map { .init(id: $0.id, text: "Это пример предложения.") })
            })
        for _ in 0..<150 where stream.ready.isEmpty || stream.activeRange != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(stream.errorMessage)
        let translations = records.calls.filter { $0.0 == "gpt-5.6-luna" }
        XCTAssertFalse(translations.isEmpty)
        XCTAssertTrue(translations.allSatisfy { oldIDs.isDisjoint(with: Set($0.1)) })
        stream.stop()
        for _ in 0..<100 where stream.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        stream.start(source: source, videoURL: video, translation: luna, review: terra, position: 300,
            translate: { _, _, _ in XCTFail("Assembled windows must persist across restart"); throw TranslationFailure.service })
        for _ in 0..<100 where stream.ready.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(stream.errorMessage)
        XCTAssertFalse(stream.ready.isEmpty)
    }

    @MainActor
    func testLiveBufferedPrefixOnlyWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["LEKTIEN_LIVE_BUFFER_SMOKE"] == "1",
              let path = ProcessInfo.processInfo.environment["LEKTIEN_STREAM_FIXTURE"] else {
            throw XCTSkip("Opt-in: one Luna request, one Terra request, local Kseniya, synthetic text")
        }
        let root = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try SubtitleDocument(cues: [
            .init(identifier: 1, start: 0, end: 4, text: "Heute sprechen wir über das Herz."),
            .init(identifier: 2, start: 6, end: 10, text: "Das Herz pumpt Blut durch den Körper."),
            .init(identifier: 3, start: 12, end: 16, text: "Damit ist dieses kurze Beispiel beendet.")])
        let playback = PlaybackController()
        let speech = SpeechController()
        let stream = StreamingTranslationController()
        var subscriptions = Set<AnyCancellable>()
        defer { subscriptions.removeAll(); stream.reset(); speech.reset(); playback.pause(); playback.clearVoice(); playback.audioMixer.reset() }
        playback.load(url: URL(fileURLWithPath: path))
        stream.$ready.sink { speech.supply($0) }.store(in: &subscriptions)
        speech.$prepared.sink { playback.acceptSpeech($0) }.store(in: &subscriptions)
        stream.start(source: source, videoURL: root.appendingPathComponent("sample.mp4"), translation: luna, review: terra, position: 0)
        speech.startStreaming(plan: stream.plan, videoURL: root.appendingPathComponent("sample.mp4"), voice: "kseniya", position: 0)
        playback.startWithSpeech(plan: stream.plan)
        XCTAssertTrue(playback.waitingForSpeech)
        for _ in 0..<600 where playback.voicePlayer?.isPlaying != true && stream.errorMessage == nil && speech.errorMessage == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(stream.errorMessage)
        XCTAssertNil(speech.errorMessage)
        XCTAssertTrue(playback.voicePlayer?.isPlaying == true, "\(stream.status ?? "") / \(speech.status)")
        XCTAssertFalse(playback.waitingForSpeech)
        let output = try XCTUnwrap(stream.completedURL)
        let russian = try SRTParser.parse(data: Data(contentsOf: output))
        XCTAssertEqual(russian.cues.map(\.id), [1, 2, 3])
        XCTAssertEqual(russian.cues.map(\.start), [0, 6, 12])
        XCTAssertTrue(russian.cues[0].text.lowercased().contains("серд"))
        XCTAssertTrue(stream.status?.contains("запросов: 2") == true)
    }

    private func temporaryLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".lektien"), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: root.appendingPathComponent(".lektien/glossary.json"))
        return root
    }
    private func document(count: Int) throws -> SubtitleDocument {
        try SubtitleDocument(cues: (0..<count).map {
            .init(identifier: $0 + 1, start: Double($0 * 8), end: Double($0 * 8 + 6), text: "Das ist ein Beispielsatz.")
        })
    }
}
