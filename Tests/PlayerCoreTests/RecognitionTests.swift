import AVFoundation
import XCTest
import PlayerCore
import PlayerMedia
import PlayerSpeech
@testable import PlayerTranscription

final class RecognitionTests: XCTestCase {
    func testTerminologyPromptIsLocalAndSubjectSpecific() {
        let it = RecognitionSession.initialPrompt(for: URL(fileURLWithPath: "/lectures/Umschulung-Windows-01.mkv"))
        XCTAssertTrue(it.contains("Active Directory"))
        XCTAssertTrue(it.contains("Hyper-V"))
        let general = RecognitionSession.initialPrompt(for: URL(fileURLWithPath: "/lectures/Medizin-Vortrag.mkv"))
        XCTAssertTrue(general.contains("keine Sätze auslassen"))
        XCTAssertFalse(general.contains("Active Directory"))
    }

    func testPlanIsStableAtSeeksAndKeepsShortFinalInterval() throws {
        let plan = try RecognitionChunk.plan(duration: 91.25)
        XCTAssertEqual(plan.map(\.start), [0, 30, 60, 90])
        XCTAssertEqual(plan.last?.end, 91.25)
        XCTAssertThrowsError(try RecognitionChunk.plan(duration: .infinity))
        XCTAssertThrowsError(try RecognitionChunk.plan(duration: -1))
        let document = try SubtitleDocument(cues: [.init(identifier: 1, start: 62, end: 65, text: "Guten Tag.")])
        XCTAssertEqual(try plan[2].withDocument(document).document.cues.first?.id, 2001)
        XCTAssertThrowsError(try plan[1].withDocument(document))
    }

    func testOverlapKeepsWholeWordsOnlyInTheirOwnedWindow() throws {
        let data = Data(#"{"transcription":[{"text":"Hallo zusammen guten Tag.","offsets":{"from":0,"to":5000},"tokens":[{"text":"Hallo","offsets":{"from":0,"to":1200},"id":1},{"text":" zusammen","offsets":{"from":1200,"to":2000},"id":2},{"text":" guten","offsets":{"from":2300,"to":3500},"id":3},{"text":" Tag","offsets":{"from":3500,"to":4400},"id":4},{"text":".","offsets":{"from":4400,"to":4500},"id":5}]}]}"#.utf8)
        let plan = try RecognitionChunk.plan(duration: 60)
        let first = try RecognitionOutput.parse(data, chunk: plan[0], inputStart: 28)
        let second = try RecognitionOutput.parse(data, chunk: plan[1], inputStart: 28)
        XCTAssertEqual(first.document.cues.map(\.text), ["Hallo zusammen"])
        XCTAssertEqual(second.document.cues.map(\.text), ["guten Tag."])
        XCTAssertLessThanOrEqual(first.document.cues[0].end, 30)
        XCTAssertGreaterThanOrEqual(second.document.cues[0].start, 30)
    }

    func testFinalFractionalMillisecondSurvivesSRTCacheRoundTrip() throws {
        let chunk = try RecognitionChunk.plan(duration: 31.1236)[1]
        let document = try SubtitleDocument(cues: [.init(identifier: 1001, start: 30, end: 31.1236, text: "Ende.")])
        let reloaded = try SRTParser.parse(data: Data(MediaPublication.srt(document).utf8))
        XCTAssertEqual(try chunk.withDocument(reloaded).document.cues[0].end, 31.1236)
    }

    func testHistoryRestoresCollisionSuffixAndRejectsEditedResult() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("sample.mp4")
        let document = try SubtitleDocument(cues: [.init(identifier: 1001, start: 30, end: 32, text: "Hallo.")])
        let url = directory.appendingPathComponent("sample.de.1.srt")
        let content = MediaPublication.srt(document)
        try Data(content.utf8).write(to: url)
        var history = LectureHistory()
        history.recognitionStream = 1; history.recognitionSubtitle = url.lastPathComponent
        history.recognitionSubtitleHash = MediaPublication.hash(Data(content.utf8))
        XCTAssertEqual(history.restoredRecognitionSource(video: video)?.url, url)
        try Data(content.replacingOccurrences(of: "Hallo", with: "Anders").utf8).write(to: url)
        XCTAssertNil(history.restoredRecognitionSource(video: video))
        history.recognitionSubtitle = "../sample.de.1.srt"
        XCTAssertNil(history.restoredRecognitionSource(video: video))
    }

    func testRealEmbeddedTextExtractionSelectsTheRequestedTrack() throws {
        guard let path = ProcessInfo.processInfo.environment["LEKTIEN_EMBEDDED_FIXTURE"] else { throw XCTSkip("Opt-in embedded subtitle extraction") }
        let video = URL(fileURLWithPath: path)
        let control = MediaCancellation()
        let media = try MediaInspection.read(video, cancellation: control)
        let german = try XCTUnwrap(media.textSubtitles.first(where: \.isGerman))
        let russian = try XCTUnwrap(media.textSubtitles.first(where: \.isRussian))
        let de = try MediaInspection.extractSubtitles(video, stream: german, cancellation: control)
        let ru = try MediaInspection.extractSubtitles(video, stream: russian, cancellation: control)
        XCTAssertFalse(de.cues.isEmpty); XCTAssertFalse(ru.cues.isEmpty)
        XCTAssertNotEqual(de.cues.map(\.text), ru.cues.map(\.text))
        control.cancel()
        XCTAssertThrowsError(try MediaInspection.read(video, cancellation: control))
    }

    func testSilenceIsAValidCompletedSectionWithReusableAudio() throws {
        let chunk = try RecognitionChunk.plan(duration: 30)[0]
        let parsed = try RecognitionOutput.parse(Data(#"{"transcription":[]}"#.utf8), chunk: chunk, inputStart: 0)
        XCTAssertTrue(parsed.document.cues.isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("sample.mp4")
        let first = try SpeechSession.silentAudio(duration: 30, videoURL: video)
        let second = try SpeechSession.silentAudio(duration: 30, videoURL: video)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first).count, 44 + 30 * 24_000 * 2)
    }

    func testDigitalSilenceGateKeepsEvenVeryQuietSamplesAndSupportsCancellation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].update(repeating: 0, count: 32_000)
        func write(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name + ".caf")
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        }
        let silent = try write("silence")
        XCTAssertTrue(try RecognitionSession.isDigitalSilence(silent, cancellation: .init()))
        buffer.floatChannelData![0][31_999] = 0.000_000_1
        XCTAssertFalse(try RecognitionSession.isDigitalSilence(write("quiet"), cancellation: .init()))
        let control = MediaCancellation(); control.cancel()
        XCTAssertThrowsError(try RecognitionSession.isDigitalSilence(silent, cancellation: control))
    }

    func testPaddedWordTimingsCannotRewindIntoThePreviousSentence() throws {
        let input = Data(#"{"transcription":[{"text":"Wer bist du?","offsets":{"from":16000,"to":22890},"tokens":[]},{"text":"Ich bin hier.","offsets":{"from":22890,"to":32000},"tokens":[{"id":1,"text":" Ich","offsets":{"from":20680,"to":21500}},{"id":2,"text":" bin","offsets":{"from":22000,"to":23200}},{"id":3,"text":" hier.","offsets":{"from":23200,"to":29700}}]}]}"#.utf8)
        let chunk = try RecognitionChunk.plan(duration: 60)[0]
        let output = try RecognitionOutput.parse(input, chunk: chunk, inputStart: 0)
        XCTAssertEqual(output.document.cues.count, 2)
        XCTAssertEqual(output.document.cues[1].start, 22.89, accuracy: 0.001)
        XCTAssertEqual(output.document.cues[1].text, "Ich bin hier.")
    }

    func testCompressedTokenClockFailsInsteadOfLosingBoundaryWords() throws {
        let input = Data(#"{"transcription":[{"text":" Noch ein Satz.","offsets":{"from":26540,"to":32000},"tokens":[{"id":1,"text":" Noch","offsets":{"from":20500,"to":21900}},{"id":2,"text":" ein","offsets":{"from":21900,"to":23000}},{"id":3,"text":" Satz.","offsets":{"from":23000,"to":25420}}]}]}"#.utf8)
        let chunk = try RecognitionChunk.plan(duration: 60)[0]
        XCTAssertThrowsError(try RecognitionOutput.parse(input, chunk: chunk, inputStart: 0))
    }

    func testOriginalClockPreservesWordsAfterPauseAtWindowBoundary() throws {
        let input = Data(#"{"transcription":[{"text":" Ende. Danach weiter.","offsets":{"from":27840,"to":32000},"tokens":[{"id":1,"text":" Ende.","offsets":{"from":27840,"to":29100}},{"id":2,"text":" Danach","offsets":{"from":30800,"to":31400}},{"id":3,"text":" weiter.","offsets":{"from":31400,"to":32000}}]}]}"#.utf8)
        let plan = try RecognitionChunk.plan(duration: 60)
        XCTAssertEqual(try RecognitionOutput.parse(input, chunk: plan[0], inputStart: 0).document.cues.map(\.text), ["Ende."])
        XCTAssertEqual(try RecognitionOutput.parse(input, chunk: plan[1], inputStart: 0).document.cues.map(\.text), ["Danach weiter."])
    }

    func testSpeechOverlapPreparationDoesNotChangeDisplayedSubtitles() throws {
        let source = try SubtitleDocument(cues: [.init(identifier: 1, start: 0, end: 4, text: "Первая реплика."),
            .init(identifier: 2, start: 3, end: 6, text: "Вторая реплика."),
            .init(identifier: 3, start: 8, end: 10, text: "Следующая.")])
        let speech = try SpeechChunkPlanner.forSynthesis(source)
        XCTAssertEqual(source.cues.count, 3)
        XCTAssertEqual(source.cues[1].start, 3)
        XCTAssertEqual(speech.cues.count, 2)
        XCTAssertEqual(speech.cues[0].end, 6)
        XCTAssertEqual(speech.cues[0].text, "Первая реплика. Вторая реплика.")
    }

    func testPublicationPreservesExistingSourceAndRenumbersSRT() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("sample.de.srt")
        try Data("original".utf8).write(to: original)
        let document = try SubtitleDocument(cues: [.init(identifier: 1001, start: 30, end: 34, text: "Guten Tag.")])
        let saved = try MediaPublication.subtitles(document, video: directory.appendingPathComponent("sample.mp4"), language: "de")
        XCTAssertNotEqual(saved, original)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
        XCTAssertEqual(try SRTParser.parse(data: Data(contentsOf: saved)).cues.first?.id, 1)
        XCTAssertEqual(try MediaPublication.subtitles(document, video: directory.appendingPathComponent("sample.mp4"), language: "de"), saved)
    }

    func testTextTrackDetectionExcludesBitmapSubtitles() throws {
        let data = Data(#"{"streams":[{"index":2,"codec_type":"subtitle","codec_name":"mov_text","tags":{"language":"deu"}},{"index":3,"codec_type":"subtitle","codec_name":"hdmv_pgs_subtitle","tags":{"language":"deu"}}]}"#.utf8)
        let media = try JSONDecoder().decode(MediaInspection.self, from: data)
        XCTAssertEqual(media.textSubtitles.map(\.id), [2])
        XCTAssertTrue(media.textSubtitles[0].isGerman)
    }

    func testHistoryRestoresPositionAndRejectsChangedMediaOrSubtitles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("sample.mp4")
        try Data("original".utf8).write(to: video)
        var history = LectureHistory()
        history.position = 185.2; history.recognitionStream = 2
        history.recognitionSubtitle = "sample.de.srt"
        history.recognitionSubtitleHash = MediaPublication.hash(Data("source".utf8))
        try history.save(video: video)
        let loaded = LectureHistory.load(video: video)
        XCTAssertEqual(loaded.position, 185.2)
        XCTAssertTrue(loaded.matchesRecognitionSource(subtitle: directory.appendingPathComponent("sample.de.srt"), content: "source"))
        XCTAssertFalse(loaded.matchesRecognitionSource(subtitle: directory.appendingPathComponent("sample.de.srt"), content: "edited"))
        try Data("different recording".utf8).write(to: video)
        XCTAssertNil(LectureHistory.load(video: video).recognitionStream)
        XCTAssertEqual(LectureHistory.load(video: video).position, 0)
    }

    func testRemoteHistoryUsesStableIdentityWithoutCompleteVideoFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let placeholder = directory.appendingPathComponent("telegram/lecture.mp4")
        var history = LectureHistory()
        history.position = 91.5; history.recognitionStream = 4
        try history.save(video: placeholder, remoteIdentity: "telegram-item-42")
        XCTAssertEqual(LectureHistory.load(video: placeholder, remoteIdentity: "telegram-item-42").position, 91.5)
        XCTAssertNil(LectureHistory.load(video: placeholder, remoteIdentity: "other-item").recognitionStream)
        XCTAssertFalse(FileManager.default.fileExists(atPath: placeholder.path))
    }

    func testRealRecognitionUsesCacheAndHandlesSeek() throws {
        guard let path = ProcessInfo.processInfo.environment["LEKTIEN_RECOGNITION_FIXTURE"] else { throw XCTSkip("Opt-in local recognition") }
        let video = URL(fileURLWithPath: path)
        let control = MediaCancellation()
        let info = try MediaInspection.read(video, cancellation: control)
        let duration = try XCTUnwrap(info.duration)
        let audio = try XCTUnwrap(info.audio.first)
        let started = ProcessInfo.processInfo.systemUptime
        let session = try RecognitionSession(video: video, streamIndex: audio.index, duration: duration, cancellation: control)
        let plan = try RecognitionChunk.plan(duration: duration)
        let last = try session.recognize(try XCTUnwrap(plan.last), cancellation: control)
        let first = try session.recognize(plan[0], cancellation: control)
        XCTAssertFalse(first.document.cues.isEmpty)
        XCTAssertEqual(try session.cached(plan[0]), first)
        XCTAssertEqual(try session.cached(try XCTUnwrap(plan.last)), last)
        print("Recognition fixture: \(duration) s; preparation \(ProcessInfo.processInfo.systemUptime - started) s; \(first.document.cues.count) initial cues")
    }
}
