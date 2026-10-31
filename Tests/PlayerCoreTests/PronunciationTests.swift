import XCTest
import AVFoundation
import PlayerCore
import PlayerSpeech

final class PronunciationTests: XCTestCase {
    func testWholeWordsContextAndLiteralReplacements() throws {
        let rules = try SpeechPronunciation(text: "замок => зам+ок\nстаринный замок => старинный з+амок\nH2S => сероводород")
        XCTAssertEqual(rules.apply(to: "Дверной замок и старинный замок; замоковый и H2S."),
                       "Дверной замо́к и старинный за́мок; замоковый и сероводород.")
        XCTAssertEqual(rules.apply(to: "за́мок"), "за́мок")
        XCTAssertEqual(try SpeechPronunciation(text: "а => б\nб => в").apply(to: "а б"), "б в")
    }

    func testSRTTimingAndUnrelatedTextRemainByteIdentical() throws {
        let srt = "14\n00:00:01,230 --> 00:00:03,340\nЗамок закрыт.\n\n15\n00:00:04,000 --> 00:00:06,000\nОстальной текст.\n"
        let rules = try SpeechPronunciation(text: "замок => зам+ок")
        let changed = rules.prepare(srt: srt)
        let source = try SRTParser.parse(text: srt), output = try SRTParser.parse(text: changed)
        XCTAssertEqual(output.cues.map(\.id), source.cues.map(\.id))
        XCTAssertEqual(output.cues.map(\.start), source.cues.map(\.start))
        XCTAssertEqual(output.cues.map(\.end), source.cues.map(\.end))
        XCTAssertEqual(output.cues[1].text, source.cues[1].text)
        XCTAssertEqual(try SpeechPronunciation(text: "кремний => кр+емний").prepare(srt: srt), srt)
    }

    func testInvalidEditDoesNotReplaceSavedDictionary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("video.mp4")
        let original = "кремний => кремний"
        try SpeechPronunciation.save(original, video: video)
        for invalid in ["замок", "замок =>", "замок => зам+к", "замок => з+ам+ок", "замок => за́мо́к", "замок => за́мок\nЗАМОК => замо́к"] {
            XCTAssertThrowsError(try SpeechPronunciation.save(invalid, video: video))
            XCTAssertEqual(try SpeechPronunciation.customText(video: video), original)
        }
        XCTAssertEqual(try SpeechPronunciation.load(video: video).apply(to: "Кремний"), "Кремний")
    }

    func testRealStressAndSelectiveCacheReuse() throws {
        guard ProcessInfo.processInfo.environment["LEKTIEN_STRESS_AUDIO"] == "1" else { throw XCTSkip("Opt-in local Kseniya pronunciation") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lektien-stress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("sample.mp4")
        let srt = "1\n00:00:00,000 --> 00:00:12,000\nДверной замок закрыт. Вдали виден старинный замок.\n"
        func run(pronunciation: SpeechPronunciation? = nil) throws -> URL {
            try SpeechSession.run(srt: srt, videoURL: video, voice: "kseniya", cancellation: .init(), pronunciation: pronunciation, progress: { _, _ in }).audioURL
        }
        let automatic = try run(pronunciation: .init(text: ""))
        let original = try Data(contentsOf: automatic)
        try SpeechPronunciation.save("дверной замок => дверной зам+ок\nстаринный замок => старинный з+амок", video: video)
        XCTAssertNil(try SpeechSession.cachedAudio(srt: srt, videoURL: video, voice: "kseniya"))
        let corrected = try run()
        XCTAssertNotEqual(corrected, automatic)
        let audio = try AVAudioFile(forReading: corrected)
        XCTAssertGreaterThan(audio.length, 24_000)
        XCTAssertEqual(Double(audio.length) / audio.processingFormat.sampleRate, 12, accuracy: 0.002)
        XCTAssertEqual(try SpeechSession.cachedAudio(srt: srt, videoURL: video, voice: "kseniya"), corrected)
        try SpeechPronunciation.save("дверной замок => дверной зам+ок\nстаринный замок => старинный з+амок\nновое слово => н+овое сл+ово", video: video)
        XCTAssertEqual(try SpeechSession.cachedAudio(srt: srt, videoURL: video, voice: "kseniya"), corrected)
        XCTAssertEqual(try Data(contentsOf: automatic), original)
        print("STRESS_AUTOMATIC=\(automatic.path)\nSTRESS_CORRECTED=\(corrected.path)")
    }

    func testRealKappaIdentifierSpeech() throws {
        guard ProcessInfo.processInfo.environment["LEKTIEN_STRESS_AUDIO"] == "1" else { throw XCTSkip("Opt-in local Kseniya pronunciation") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lektien-kappa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("sample.mp4")
        let srt = "1\n00:00:00,000 --> 00:00:08,000\nПоговорим о подавлении NF-κB.\n"
        let result = try SpeechSession.run(srt: srt, videoURL: video, voice: "kseniya", cancellation: .init(), progress: { _, _ in })
        let audio = try AVAudioFile(forReading: result.audioURL)
        XCTAssertEqual(Double(audio.length) / audio.processingFormat.sampleRate, 8, accuracy: 0.002)
        XCTAssertEqual(try SpeechSession.cachedAudio(srt: srt, videoURL: video, voice: "kseniya"), result.audioURL)
        print("KAPPA_CORRECTED=\(result.audioURL.path)")
    }
}
