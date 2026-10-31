import Foundation
import XCTest
import PlayerCore
import PlayerTranslation
import PlayerSpeech

final class EconomyTests: XCTestCase {
    func testXeniaCannotReplaceRequestedKseniya() throws {
        XCTAssertThrowsError(try SpeechSession.run(srt: "", videoURL: URL(fileURLWithPath: "/tmp/unused.mp4"),
            voice: "xenia", cancellation: .init(), progress: { _, _ in })) {
                XCTAssertEqual($0 as? SpeechFailure, .unsupportedVoice)
            }
    }

    func testTimingOnlyEditReusesPreparedTextAndRestoresNewTiming() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = TranslationSettings(model: "gpt-5.6-luna", effort: "medium")
        let source = try SubtitleDocument(cues: [.init(identifier: 1, start: 1, end: 3, text: "Das Herz.")])
        _ = try TranslationSession.run(document: source, videoURL: root.appendingPathComponent("a.mp4"), settings: settings,
            cancellation: .init(), translate: { _, _, _ in .init(translations: [.init(id: 1, text: "Сердце.")]) }, progress: { _ in })
        let shifted = try SubtitleDocument(cues: [.init(identifier: 1, start: 2, end: 4, text: "Das Herz.")])
        let reused = try TranslationSession.run(document: shifted, videoURL: root.appendingPathComponent("a.mp4"), settings: settings,
            cancellation: .init(), translate: { _, _, _ in XCTFail("A timing edit needs no model call"); throw TranslationFailure.service }, progress: { _ in })
        XCTAssertEqual(reused.requests, 0)
        XCTAssertEqual(reused.document.cues[0].start, 2)
        XCTAssertEqual(reused.document.cues[0].end, 4)
    }

    func testSelectiveReviewPreservesOtherCuesAndReusesCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try SubtitleDocument(cues: (1...100).map {
            .init(identifier: $0, start: Double($0 * 3), end: Double($0 * 3 + 2),
                  text: $0 == 50 ? "Nicht mehr als 5 mg." : "Heute sprechen wir über das Herz.")
        })
        let draft = try SubtitleDocument(cues: source.cues.map {
            .init(identifier: $0.id, start: $0.start, end: $0.end, text: "Сегодня мы говорим о сердце.")
        })
        let selected = TranslationPreparation.reviewSelection(source: source, draft: draft, modelFlags: [80])
        XCTAssertEqual(selected, [11, 49, 50, 51, 79, 80, 81])
        let settings = TranslationSettings(model: "gpt-5.6-terra", effort: "medium")
        let video = root.appendingPathComponent("sample.mp4")
        let first = try TranslationSession.run(document: source, videoURL: video, settings: settings,
            cancellation: .init(), reviewDraft: draft, reviewIDs: selected,
            translate: { cues, _, _ in
                XCTAssertEqual(Set(cues.map(\.id)), selected)
                return .init(translations: cues.map { .init(id: $0.id, text: $0.id == 50 ? "Не более пяти миллиграммов." : "Сегодня мы говорим о сердце.") })
            }, progress: { _ in })
        XCTAssertEqual(first.requests, 1)
        XCTAssertEqual(first.reviewedCues, 7)
        XCTAssertEqual(first.document.cues.count, 100)
        XCTAssertEqual(first.document.cues[49].text, "Не более пяти миллиграммов.")
        XCTAssertEqual(first.document.cues[90], draft.cues[90])
        let second = try TranslationSession.run(document: source, videoURL: video, settings: settings,
            cancellation: .init(), reviewDraft: draft, reviewIDs: selected,
            translate: { _, _, _ in XCTFail("Finished review must not consume another request"); throw TranslationFailure.service },
            progress: { _ in })
        XCTAssertEqual(second.requests, 0)
        XCTAssertEqual(second.cached, 1)
    }

    func testGlossaryKeepsOnlyRelevantWholeTermsWithoutPromotingSuggestions() throws {
        let terms: [GlossaryTerm] = [.init(german: "Herz", russian: "сердце", confirmed: false),
            .init(german: "Herzinfarkt", russian: "инфаркт", confirmed: true),
            .init(german: "Lunge", russian: "лёгкое", confirmed: true)]
        let result = TranslationPreparation.matchingTerms(terms, cues: [.init(identifier: 1, start: 0, end: 1, text: "Das HERZ.")])
        XCTAssertEqual(result, [terms[0]])
        XCTAssertThrowsError(try TranslationResponse(translations: [.init(id: 1, text: "Сердце")], reviewIDs: [999]).validated(for: [1]))
    }

    func testLiveSileroAndCompletedAudioCacheOnlyWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["LEKTIEN_SPEECH_SMOKE"] == "1" else { throw XCTSkip("Opt-in local synthesis") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let srt = "1\n00:00:00,500 --> 00:00:08,000\nСердце перекачивает кровь. Доза — 5 мг.\n"
        let first = try SpeechSession.run(srt: srt, videoURL: root.appendingPathComponent("sample.mp4"), voice: "kseniya", cancellation: .init(), progress: { _, _ in })
        XCTAssertEqual(try SpeechSession.cachedAudio(srt: srt, videoURL: root.appendingPathComponent("sample.mp4"), voice: "kseniya"), first.audioURL)
        XCTAssertNil(try SpeechSession.cachedAudio(srt: srt + "Другой текст", videoURL: root.appendingPathComponent("sample.mp4"), voice: "kseniya"))
        let data = try Data(contentsOf: first.audioURL)
        XCTAssertGreaterThan(data.count, 100_000)
        XCTAssertTrue(data.dropFirst(44).contains { $0 != 0 })
        let modified = try FileManager.default.attributesOfItem(atPath: first.audioURL.path)[.modificationDate] as? Date
        let second = try SpeechSession.run(srt: srt, videoURL: root.appendingPathComponent("sample.mp4"), voice: "kseniya", cancellation: .init(), progress: { _, _ in XCTFail("Cached audio must not synthesize again") })
        XCTAssertEqual(first.audioURL, second.audioURL)
        XCTAssertEqual(modified, try FileManager.default.attributesOfItem(atPath: second.audioURL.path)[.modificationDate] as? Date)
    }

    func testLiveSpeechCancellationDoesNotPublishPartialAudio() throws {
        guard ProcessInfo.processInfo.environment["LEKTIEN_SPEECH_SMOKE"] == "1" else { throw XCTSkip("Opt-in local synthesis") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let control = SpeechCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { control.cancel() }
        let start = Date()
        XCTAssertThrowsError(try SpeechSession.run(srt: "1\n00:00:00,000 --> 00:00:20,000\nСегодня мы проверяем остановку подготовки русской речи.\n",
            videoURL: root.appendingPathComponent("cancel.mp4"), voice: "kseniya", cancellation: control, progress: { _, _ in })) {
                XCTAssertEqual($0 as? SpeechFailure, .stopped)
            }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        XCTAssertFalse(files.contains { $0.lastPathComponent == "audio.wav" || $0.lastPathComponent.hasPrefix("pending-") })
    }
}
