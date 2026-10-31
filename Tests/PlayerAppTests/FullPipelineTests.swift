import AVFoundation
import Combine
import Foundation
import XCTest
import PlayerCore
import PlayerMedia
import PlayerSpeech
import PlayerTranslation
import PlayerTranscription
import PlayerExport
@testable import LektienOnlineUebersetzung

/// Explicit local acceptance runs. Ordinary verification never sends lecture text to a service.
final class FullPipelineTests: XCTestCase {
    private let luna = TranslationSettings(model: "gpt-5.6-luna", effort: "medium")
    private let terra = TranslationSettings(model: "gpt-5.6-terra", effort: "medium")

    @MainActor
    func testCompleteLectureRecognitionTranslationSpeechAndCacheRestart() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LEKTIEN_FULL_PIPELINE"] == "1", let videoPath = env["LEKTIEN_LONG_VIDEO"] else {
            throw XCTSkip("Opt-in complete lecture recognition with live translation")
        }
        let video = URL(fileURLWithPath: videoPath)
        let recognition = RecognitionController()
        let stream = StreamingTranslationController()
        let speech = SpeechController()
        let playback = PlaybackController()
        playback.volume = 0; playback.russianVolume = 0
        var subscriptions = Set<AnyCancellable>()
        defer { subscriptions.removeAll(); recognition.reset(); stream.reset(); speech.reset(); playback.pause(); playback.clearVoice(); playback.audioMixer.reset() }
        recognition.$ready.sink { chunks in
            stream.supplyRecognized(chunks.compactMap { chunk in
                guard let document = try? SubtitleDocument(cues: chunk.document.cues.map {
                    .init(identifier: $0.id, start: $0.start - chunk.start, end: $0.end - chunk.start, text: $0.text)
                }) else { return nil }
                return .init(id: chunk.id, start: chunk.start, end: chunk.end, document: document)
            })
        }.store(in: &subscriptions)
        stream.$ready.sink { speech.supply($0) }.store(in: &subscriptions)
        speech.$prepared.sink { playback.acceptSpeech($0) }.store(in: &subscriptions)
        playback.load(url: video)
        for _ in 0..<200 where playback.snapshot.duration == nil { try await Task.sleep(for: .milliseconds(50)) }
        let duration = try XCTUnwrap(playback.snapshot.duration)
        let media = try MediaInspection.read(video, cancellation: .init())
        let audioIndex = try XCTUnwrap(media.audio.first?.index)
        let started = ProcessInfo.processInfo.systemUptime
        stream.bufferAhead = 420; speech.bufferAhead = 360
        recognition.bufferAhead = 450
        recognition.start(video: video, streamIndex: audioIndex, duration: duration, position: 0)
        let cachedOnly: TranslationSession.Translate?
        if env["LEKTIEN_FULL_CACHE_ONLY"] == "1" {
            cachedOnly = { _, _, _ in
                XCTFail("Cached-only verification must make zero model calls")
                throw TranslationFailure.service
            }
        } else { cachedOnly = nil }
        stream.startRecognizing(plan: recognition.speechPlan, videoURL: video, translation: luna, review: terra, position: 0, translate: cachedOnly)
        speech.startStreaming(plan: stream.plan, videoURL: video, voice: "kseniya", position: 0)
        recognition.prepareWholeLecture = true; stream.prepareWholeLecture = true; speech.prepareWholeLecture = true
        playback.startWithSpeech(plan: stream.plan)
        var firstAudio: Double?
        var pausedAt: Double?
        var preparedAtPause = 0
        var pauseFinished = false
        var seekStarted: Double?
        var seekWait: Double?
        var returned = false
        var minimumBuffer = Double.infinity
        var maximumDrift = 0.0
        var stalls = 0
        var wasWaiting = true
        var nextReport = 0.0
        let limit = Double(env["LEKTIEN_FULL_DEADLINE"] ?? "7200") ?? 7200
        while true {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if let stopPath = env["LEKTIEN_FULL_STOP_FILE"], FileManager.default.fileExists(atPath: stopPath) {
                report("stopped", ["elapsed": elapsed])
                throw XCTSkip("Explicit acceptance stop; completed caches are preserved")
            }
            if elapsed > limit { XCTFail("Acceptance run exceeded its explicit deadline; completed caches are preserved"); break }
            if let error = recognition.errorMessage ?? stream.errorMessage ?? speech.errorMessage ?? playback.errorMessage {
                report("failed", ["elapsed": elapsed, "error": error]); XCTFail(error); break
            }
            let position = playback.snapshot.position
            recognition.updatePosition(position); stream.updatePosition(position); speech.updatePosition(position)
            if playback.voicePlayer?.isPlaying == true {
                if firstAudio == nil { firstAudio = elapsed; report("first_audio", ["elapsed": elapsed]) }
                minimumBuffer = min(minimumBuffer, playback.speechBufferSeconds)
                if let chunk = speech.prepared.first(where: { $0.audioURL == playback.voicePlayer?.url }),
                   position >= chunk.chunk.start, position < chunk.chunk.end {
                    maximumDrift = max(maximumDrift, abs((playback.voicePlayer?.currentTime ?? 0) - (position - chunk.chunk.start)))
                }
            }
            if let firstAudio, pausedAt == nil, elapsed - firstAudio > 5 {
                playback.pause(); pausedAt = elapsed
                preparedAtPause = speech.prepared.count
                stream.bufferAhead = 660; speech.bufferAhead = 600
                recognition.bufferAhead = 690
                report("manual_pause", ["elapsed": elapsed, "ready": speech.prepared.count])
            }
            if let pausedAt, !pauseFinished, elapsed - pausedAt >= 20 {
                XCTAssertFalse(playback.playbackRequested)
                XCTAssertFalse(playback.voicePlayer?.isPlaying ?? true)
                report("pause_buffer", ["before": preparedAtPause, "after": speech.prepared.count])
                pauseFinished = true
                stream.bufferAhead = 420; speech.bufferAhead = 360
                recognition.bufferAhead = 450
                playback.seek(to: duration / 2)
                recognition.updatePosition(duration / 2)
                stream.updatePosition(duration / 2); speech.updatePosition(duration / 2)
                playback.play(); seekStarted = elapsed
            }
            if let seekStarted, seekWait == nil, playback.voicePlayer?.isPlaying == true,
               position > duration / 2 - 1 {
                seekWait = elapsed - seekStarted
                report("seek_ready", ["wait": seekWait!, "buffer": playback.speechBufferSeconds])
            }
            if let seekStarted, let seekWait, !returned, elapsed - seekStarted - seekWait > 5 {
                playback.seek(to: 0); recognition.updatePosition(0); stream.updatePosition(0); speech.updatePosition(0); returned = true
            }
            if firstAudio != nil && playback.playbackRequested && playback.waitingForSpeech && !wasWaiting { stalls += 1 }
            wasWaiting = playback.waitingForSpeech
            if elapsed >= nextReport {
                report("progress", ["elapsed": elapsed, "translated": stream.ready.count, "spoken": speech.prepared.count,
                    "recognized": recognition.ready.count,
                    "total": speech.plan.count, "requests": stream.requestCount, "cache_hits": stream.cacheHitCount,
                    "position": position, "buffer": playback.speechBufferSeconds])
                nextReport = elapsed + 20
            }
            if stream.completedURL != nil, speech.prepared.count == speech.plan.count, returned { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        playback.pause()
        XCTAssertNotNil(stream.completedURL)
        XCTAssertEqual(speech.prepared.count, speech.plan.count)
        guard let translated = stream.document, stream.completedURL != nil, let source = recognition.document else { return }
        XCTAssertNotNil(recognition.completedURL)
        XCTAssertEqual(translated.cues.map(\.id), source.cues.map(\.id))
        XCTAssertEqual(translated.cues.map(\.start), source.cues.map(\.start))
        XCTAssertEqual(translated.cues.map(\.end), source.cues.map(\.end))
        var overrun = 0.0
        for prepared in speech.prepared {
            let audio = try AVAudioFile(forReading: prepared.audioURL)
            overrun = max(overrun, Double(audio.length) / audio.processingFormat.sampleRate - (prepared.chunk.end - prepared.chunk.start))
        }
        XCTAssertLessThan(overrun, 0.002)
        XCTAssertLessThan(maximumDrift, 0.3, "Voice must stay synchronized with video while playing")
        report("complete", ["elapsed": ProcessInfo.processInfo.systemUptime - started, "duration": duration,
            "first_audio": firstAudio ?? -1, "seek_wait": seekWait ?? -1, "minimum_buffer": minimumBuffer.isFinite ? minimumBuffer : -1,
            "maximum_drift": maximumDrift, "buffer_wait_entries_including_seek": stalls, "maximum_overrun": overrun,
            "requests": stream.requestCount, "cache_hits": stream.cacheHitCount, "clips": speech.prepared.count])

        let expected = Set(speech.prepared.map { $0.chunk.id })
        recognition.start(video: video, streamIndex: audioIndex, duration: duration, position: duration / 2)
        stream.startRecognizing(plan: recognition.speechPlan, videoURL: video, translation: luna, review: terra, position: duration / 2,
            translate: { _, _, _ in XCTFail("Completed lecture restart must make zero model calls"); throw TranslationFailure.service })
        speech.startStreaming(plan: stream.plan, videoURL: video, voice: "kseniya", position: duration / 2)
        for _ in 0..<600 where stream.completedURL == nil || speech.prepared.count < expected.count {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(stream.requestCount, 0)
        XCTAssertEqual(recognition.ready.count, recognition.plan.count)
        XCTAssertEqual(Set(speech.prepared.map { $0.chunk.id }), expected)
        XCTAssertNil(stream.errorMessage); XCTAssertNil(speech.errorMessage)
        report("restart", ["requests": stream.requestCount, "cache_hits": stream.cacheHitCount, "clips": speech.prepared.count])

        if let destination = env["LEKTIEN_FULL_EXPORT"] {
            let exportStarted = ProcessInfo.processInfo.systemUptime
            let plan = speech.plan; let clips = speech.prepared
            let videoRequest = env["LEKTIEN_FULL_EXPORT_VIDEO"] == "1"
                ? VideoExportRequest(source: video, container: .mp4, originalAudio: [audioIndex], subtitles: ["ru", "de"], germanAudio: audioIndex)
                : nil
            let output = try await Task.detached {
                try SpeechExport.save(plan: plan, prepared: clips, duration: duration, german: source,
                    destination: URL(fileURLWithPath: destination), cancellation: .init(), video: videoRequest)
            }.value
            let audio = try AVAudioFile(forReading: output.appendingPathComponent("voice.ru.m4a"))
            let audioDuration = Double(audio.length) / audio.processingFormat.sampleRate
            XCTAssertEqual(audioDuration, duration, accuracy: 0.15)
            for (name, document) in [("voice.de.srt", source), ("voice.ru.srt", translated)] {
                let saved = try SRTParser.parse(data: Data(contentsOf: output.appendingPathComponent(name)))
                XCTAssertEqual(saved.cues.map(\.text), document.cues.map(\.text))
                XCTAssertEqual(saved.cues.count, document.cues.count)
                for (original, exported) in zip(document.cues, saved.cues) {
                    XCTAssertEqual(exported.start, original.start, accuracy: 0.00051)
                    XCTAssertEqual(exported.end, original.end, accuracy: 0.00051)
                }
            }
            report("export", ["seconds": ProcessInfo.processInfo.systemUptime - exportStarted,
                "audio_duration": audioDuration, "source_cues": source.cues.count, "translated_cues": translated.cues.count])
        }
    }

    func testRecognitionSamplesAcrossLocalLecture() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LEKTIEN_ASR_SAMPLES"] == "1", let path = env["LEKTIEN_LONG_VIDEO"] else { throw XCTSkip("Opt-in local recognition samples") }
        let video = URL(fileURLWithPath: path)
        let control = MediaCancellation()
        let media = try MediaInspection.read(video, cancellation: control)
        let duration = try XCTUnwrap(media.duration)
        let stream = try XCTUnwrap(media.audio.first)
        let started = ProcessInfo.processInfo.systemUptime
        let session = try RecognitionSession(video: video, streamIndex: stream.index, duration: duration, cancellation: control)
        report("recognition_setup", ["seconds": ProcessInfo.processInfo.systemUptime - started])
        let plan = try RecognitionChunk.plan(duration: duration)
        let indices = [min(5, plan.count - 1), plan.count / 3, plan.count * 2 / 3, max(0, plan.count - 11)]
        for index in Set(indices).sorted() {
            let chunk = plan[index]
            let cached = try session.cached(chunk) != nil
            let start = ProcessInfo.processInfo.systemUptime
            let result = try session.recognize(chunk, cancellation: control)
            XCTAssertFalse(result.document.cues.isEmpty)
            XCTAssertTrue(result.document.cues.allSatisfy { $0.start >= chunk.start && $0.end <= chunk.end })
            XCTAssertEqual(try session.cached(chunk)?.document, result.document)
            report("recognition_sample", ["start": chunk.start, "end": chunk.end,
                "seconds": ProcessInfo.processInfo.systemUptime - start, "cached": cached, "cues": result.document.cues.count])
        }
    }

    private func report(_ event: String, _ values: [String: Any]) {
        var values = values; values["event"] = event
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            let line = Data((text + "\n").utf8)
            FileHandle.standardOutput.write(line)
            if let path = ProcessInfo.processInfo.environment["LEKTIEN_FULL_REPORT"] {
                if !FileManager.default.fileExists(atPath: path) {
                    FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                if let handle = FileHandle(forWritingAtPath: path) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line)
                }
            }
        }
    }
}
