import XCTest
import AVFoundation
import PlayerCore
import PlayerSpeech
import PlayerTranslation
import PlayerExport
@testable import LektienOnlineUebersetzung

final class LongLectureTests: XCTestCase {
    @MainActor
    func testCachedLectureSeeksAndNaturalClipTransitions() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let srt = environment["LEKTIEN_LONG_SRT"], let video = environment["LEKTIEN_LONG_VIDEO"] else {
            throw XCTSkip("Opt-in full lecture playback boundary checks")
        }
        let videoURL = URL(fileURLWithPath: video)
        let source = try SRTParser.parse(data: Data(contentsOf: URL(fileURLWithPath: srt)))
        let plan = try SpeechChunkPlanner.makePlan(source)
        let prepared = try plan.map { chunk in
            let text = TranslationSession.srt(try SpeechChunkPlanner.forSynthesis(chunk.document))
            return PreparedSpeechChunk(chunk: chunk, audioURL: try XCTUnwrap(SpeechSession.cachedAudio(srt: text, videoURL: videoURL, voice: "kseniya")))
        }
        let playback = PlaybackController()
        playback.russianVolume = 0
        playback.player.isMuted = true
        playback.load(url: videoURL)
        defer { playback.pause(); playback.clearVoice(); playback.audioMixer.reset() }
        for _ in 0..<100 where playback.snapshot.duration == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(playback.snapshot.duration)
        XCTAssertFalse(playback.playbackRequested)
        playback.beginSpeech(plan: plan)
        playback.acceptSpeech(prepared)
        var maximumSeek = 0.0
        // Visit every cached clip, alternating forward and backward to exercise stale seek protection.
        let order = Array(stride(from: 0, to: plan.count, by: 2)) + Array(stride(from: 1, to: plan.count, by: 2).reversed())
        for index in order {
            let chunk = plan[index]
            let position = chunk.start + min(0.2, (chunk.end - chunk.start) / 2)
            let started = ProcessInfo.processInfo.systemUptime
            playback.seek(to: position)
            for _ in 0..<100 {
                if playback.voicePlayer?.url == prepared[index].audioURL,
                   abs((playback.voicePlayer?.currentTime ?? -1) - (position - chunk.start)) < 0.1 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            maximumSeek = max(maximumSeek, ProcessInfo.processInfo.systemUptime - started)
            XCTAssertEqual(playback.voicePlayer?.url, prepared[index].audioURL)
            XCTAssertEqual(playback.voicePlayer?.currentTime ?? -1, position - chunk.start, accuracy: 0.1)
            XCTAssertFalse(playback.playbackRequested, "Seeking on manual pause must preserve the pause")
            XCTAssertFalse(playback.voicePlayer?.isPlaying ?? true)
        }
        for index in stride(from: 1, to: plan.count, by: 10) {
            playback.pause()
            playback.seek(to: plan[index].start - 0.2)
            try await Task.sleep(for: .milliseconds(100))
            playback.play()
            for _ in 0..<100 where playback.voicePlayer?.url != prepared[index].audioURL || playback.voicePlayer?.isPlaying != true {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(playback.voicePlayer?.url, prepared[index].audioURL)
            XCTAssertTrue(playback.voicePlayer?.isPlaying == true)
            XCTAssertFalse(playback.waitingForSpeech)
            XCTAssertNil(playback.errorMessage)
        }
        print("Full lecture cached playback: clips=\(plan.count), maximum_seek_seconds=\(maximumSeek), natural_boundaries=\(Array(stride(from: 1, to: plan.count, by: 10)).count)")
    }

    func testPrepareFullLocalLectureAndReuseEveryClip() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let srt = environment["LEKTIEN_LONG_SRT"], let video = environment["LEKTIEN_LONG_VIDEO"] else {
            throw XCTSkip("Opt-in full local lecture preparation")
        }
        let source = try SRTParser.parse(data: Data(contentsOf: URL(fileURLWithPath: srt)))
        let plan = try SpeechChunkPlanner.makePlan(source)
        let started = ProcessInfo.processInfo.systemUptime
        var first = 0.0
        var longest = 0.0
        var overrun = 0.0
        var prepared: [PreparedSpeechChunk] = []
        for (index, chunk) in plan.enumerated() {
            let text = TranslationSession.srt(try SpeechChunkPlanner.forSynthesis(chunk.document))
            let before = ProcessInfo.processInfo.systemUptime
            let result = try SpeechSession.run(srt: text, videoURL: URL(fileURLWithPath: video), voice: "kseniya", cancellation: .init(), progress: { _, _ in })
            let elapsed = ProcessInfo.processInfo.systemUptime - before
            if index == 0 { first = elapsed }
            longest = max(longest, elapsed)
            let audio = try AVAudioPlayer(contentsOf: result.audioURL)
            prepared.append(.init(chunk: chunk, audioURL: result.audioURL))
            overrun = max(overrun, audio.duration - (chunk.end - chunk.start))
            XCTAssertEqual(try SpeechSession.cachedAudio(srt: text, videoURL: URL(fileURLWithPath: video), voice: "kseniya"), result.audioURL)
            if index % 10 == 0 { print("Full lecture preparation: \(index + 1)/\(plan.count)") }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        print("Full lecture: duration=\(plan.last?.end ?? 0), chunks=\(plan.count), first=\(first), total=\(elapsed), slowest=\(longest), maximum_audio_overrun=\(overrun)")
        XCTAssertLessThan(overrun, 0.2, "Speech must fit the interval without silent truncation at the next clip")
        if let destination = environment["LEKTIEN_LONG_EXPORT"] {
            let duration = try await AVURLAsset(url: URL(fileURLWithPath: video)).load(.duration).seconds
            let exportStarted = ProcessInfo.processInfo.systemUptime
            let output = try SpeechExport.save(plan: plan, prepared: prepared, duration: duration, german: nil,
                destination: URL(fileURLWithPath: destination), cancellation: .init())
            let result = try AVAudioFile(forReading: output.appendingPathComponent("voice.ru.m4a"))
            XCTAssertEqual(Double(result.length) / result.processingFormat.sampleRate, duration, accuracy: 0.15)
            let saved = try SRTParser.parse(data: Data(contentsOf: output.appendingPathComponent("voice.ru.srt")))
            XCTAssertEqual(saved.cues.count, source.cues.count)
            XCTAssertEqual(saved.cues.map(\.text), source.cues.map(\.text))
            for (actual, expected) in zip(saved.cues, source.cues) {
                XCTAssertEqual(actual.start, expected.start, accuracy: 0.001)
                XCTAssertEqual(actual.end, expected.end, accuracy: 0.001)
            }
            print("Full lecture export: seconds=\(ProcessInfo.processInfo.systemUptime - exportStarted), video_duration=\(duration), audio_duration=\(Double(result.length) / result.processingFormat.sampleRate), subtitles=\(saved.cues.count)")
        }
    }
}
