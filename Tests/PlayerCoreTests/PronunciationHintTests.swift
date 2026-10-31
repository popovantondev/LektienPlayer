import Foundation
import XCTest
import PlayerCore
import PlayerSpeech
@testable import PlayerTranslation

final class PronunciationHintTests: XCTestCase {
    func testContextualStressCannotRewriteWordsOrMoveNumbers() throws {
        let hint = PronunciationHint(id: 1, source: "дверной замок", spoken: "дверной замо́к")
        XCTAssertTrue(hint.isValid)
        for spoken in ["старинный за́мок", "дверной за́мо́к", "дверной зам́ок", "дверной замок"] {
            XCTAssertFalse(PronunciationHint(id: 1, source: hint.source, spoken: spoken).isValid)
        }
        XCTAssertFalse(PronunciationHint(id: 1, source: "замок", spoken: "замо́к").isValid)
        let url = try video()
        try PronunciationHintCache.store(.init(translations: [.init(id: 1, text: "дверной замок закрыт")], pronunciations: [hint]), video: url)
        // Built-in context rules and manual edits still take priority.
        try SpeechPronunciation.save("дверной замок => дверн+ой зам+ок", video: url)
        XCTAssertEqual(try SpeechPronunciation.load(video: url).apply(to: "дверной замок закрыт"), "дверно́й замо́к закрыт")
    }
    private func video() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lektien-hints-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("sample.mp4")
    }

    func testOnlyValidatedIdentifierHintsCanAffectSpeech() throws {
        let wire = try TranslationWireFormat(cueIDs: [24001])
        let reply = try wire.decode(Data(#"{"translations":{"1":"Обсудим TNF-α и NF-κB."},"reviewIDs":[],"pronunciations":[{"id":1,"source":"TNF-α","spoken":"тэ эн эф альфа"},{"id":1,"source":"NF-κB","spoken":"эн эф каппа бэ"},{"id":-1,"source":"NF-κB","spoken":"плохо"},{"id":1,"source":"Обсудим","spoken":"другая фраза"},{"id":1,"source":"ATP","spoken":"эй ти пи"},{"id":1,"source":"NF-κB","spoken":"<speak>текст</speak>"}]}"#.utf8))
        XCTAssertEqual(reply.pronunciations?.map(\.id), [24001, 24001])
        let url = try video()
        try PronunciationHintCache.store(reply, video: url)
        let rules = try SpeechPronunciation.load(video: url)
        XCTAssertEqual(rules.apply(to: "Обсудим TNF-α и NF-κB."), "Обсудим тэ эн эф альфа и эн эф каппа бэ.")
        XCTAssertEqual(rules.apply(to: "XTNF-α TNF-αextra"), "XTNF-α TNF-αextra")
        XCTAssertEqual(reply.translations[0].text, "Обсудим TNF-α и NF-κB.")
        XCTAssertTrue(PronunciationHintCache.load(video: url.deletingLastPathComponent().appendingPathComponent("other.mp4")).isEmpty)
        for (source, spoken) in [("NF-κB\n", "каппа"), ("NF-κB", "каппа\n"), ("NF-κB", "κ"), ("NF-κB", "каппа 2"), ("H₂O₂", "вода"), ("H+", "водород")] {
            XCTAssertFalse(PronunciationHint(id: 1, source: source, spoken: spoken).isValid)
        }
    }

    func testHintsResumeWithoutRequestsAndManualDictionaryWins() throws {
        let url = try video()
        let source = try SubtitleDocument(cues: [.init(identifier: 902, start: 0, end: 8, text: "Wir sprechen über TNF-α.")])
        let settings = TranslationSettings(model: "gpt-5.6-luna", effort: "medium")
        let first = try TranslationSession.run(document: source, videoURL: url, settings: settings, cancellation: .init(),
            publishAlongsideVideo: false, translate: { _, _, _ in
                .init(translations: [.init(id: 902, text: "Поговорим о TNF-α.")],
                    pronunciations: [.init(id: 902, source: "TNF-α", spoken: "тэ эн эф альфа")])
            }, progress: { _ in })
        let srt = try Data(contentsOf: first.subtitleURL)
        let resumed = try TranslationSession.run(document: source, videoURL: url, settings: settings, cancellation: .init(),
            publishAlongsideVideo: false, translate: { _, _, _ in XCTFail("Cached hints must not need a model request"); throw TranslationFailure.service }, progress: { _ in })
        XCTAssertEqual(resumed.requests, 0)
        XCTAssertEqual(try Data(contentsOf: resumed.subtitleURL), srt)
        XCTAssertEqual(try SpeechPronunciation.load(video: url).apply(to: first.document.cues[0].text), "Поговорим о тэ эн эф альфа.")
        try SpeechPronunciation.save("TNF-α => ти эн эф альфа", video: url)
        XCTAssertEqual(try SpeechPronunciation.load(video: url).apply(to: first.document.cues[0].text), "Поговорим о ти эн эф альфа.")
    }

    func testConflictingGuessesFallBackAndOldRepliesStillDecode() throws {
        let url = try video()
        for spoken in ["тэ эн эф альфа", "ти эн эф альфа"] {
            try PronunciationHintCache.store(.init(translations: [.init(id: 1, text: "TNF-α")],
                pronunciations: [.init(id: 1, source: "TNF-α", spoken: spoken)]), video: url)
        }
        XCTAssertTrue(PronunciationHintCache.load(video: url).isEmpty)
        let old = try JSONDecoder().decode(TranslationResponse.self, from: Data(#"{"translations":[{"id":1,"text":"Привет"}]}"#.utf8))
        XCTAssertNil(old.pronunciations)
        XCTAssertEqual(try old.validated(for: [1])[1], "Привет")
    }

    func testLiveHintsAndVoiceOnlyWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["LEKTIEN_LIVE_PRONUNCIATION"] == "1" else { throw XCTSkip("Opt-in single synthetic translation and local voice") }
        let url = try video()
        let cues: [SubtitleCue] = [
            .init(identifier: 24001, start: 0, end: 8, text: "Wir sprechen über NF-κB und TNF-α."),
            .init(identifier: 24002, start: 8, end: 16, text: "H₂O₂ ist Wasserstoffperoxid. Verwechseln Sie es nicht mit Wasser."),
            .init(identifier: 24003, start: 16, end: 30, text: "Das Schloss an der Tür ist verschlossen. Das alte Schloss steht auf dem Hügel.")
        ]
        let settings = TranslationSettings(model: "gpt-5.6-luna", effort: "medium")
        let client = CodexClient(executable: try XCTUnwrap(CodexClient.installedExecutable()))
        let result = try TranslationSession.run(document: .init(cues: cues), videoURL: url, settings: settings, cancellation: .init(),
            publishAlongsideVideo: false, translate: { cues, settings, control in
                try client.translate(cues: cues, settings: settings, cancellation: control)
            }, progress: { _ in })
        XCTAssertEqual(result.requests, 1)
        let hints = PronunciationHintCache.load(video: url)
        XCTAssertTrue(hints.contains { $0.source == "NF-κB" })
        XCTAssertTrue(hints.contains { $0.source == "TNF-α" })
        XCTAssertTrue(hints.contains { $0.spoken.unicodeScalars.contains(where: { $0.value == 0x0301 }) }, "The homographs should receive a contextual stress hint")
        let text = TranslationSession.srt(result.document)
        let audio = try SpeechSession.run(srt: text, videoURL: url, voice: "kseniya", cancellation: .init(), progress: { _, _ in })
        XCTAssertEqual(try SpeechSession.cachedAudio(srt: text, videoURL: url, voice: "kseniya"), audio.audioURL)
        XCTAssertEqual(try String(contentsOf: result.subtitleURL, encoding: .utf8), text)
        print("SYNTHETIC_HINTS=\(hints)\nSYNTHETIC_TRANSLATION=\(text)")
    }
}
