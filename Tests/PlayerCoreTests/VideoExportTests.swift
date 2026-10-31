import AVFoundation
import XCTest
import PlayerCore
import PlayerMedia
import PlayerSpeech
@testable import PlayerExport

final class VideoExportTests: XCTestCase {
    func testSelectedAudioSubtitlesAndDefaultTrackWithoutReencodingVideo() throws {
        guard ProcessInfo.processInfo.environment["LEKTIEN_RUNTIME_DIRECTORY"] != nil else { throw XCTSkip("Opt-in local muxer") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let ffmpeg = try MediaRuntime.executable("ffmpeg")
        let source = root.appendingPathComponent("source.mp4")
        _ = try LocalMediaProcess.run(ffmpeg, ["-nostdin", "-v", "error", "-n",
            "-f", "lavfi", "-i", "color=c=blue:s=160x90:r=10:d=3",
            "-f", "lavfi", "-i", "sine=frequency=330:duration=3",
            "-f", "lavfi", "-i", "sine=frequency=660:duration=3",
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "mpeg4", "-c:a", "aac",
            "-metadata:s:a:0", "language=und", "-metadata:s:a:1", "language=eng", source.path], directory: root, cancellation: .init())
        let originalBytes = try Data(contentsOf: source)
        let original = try MediaInspection.read(source, cancellation: .init())
        let english = try XCTUnwrap(original.audio.first { $0.language == "eng" })
        let germanAudio = try XCTUnwrap(original.audio.first { $0.language == "und" })
        let clip = try speech(root: root)
        let german = try SubtitleDocument(cues: [.init(identifier: 1, start: 0.25, end: 2, text: "Guten Tag.")])
        func packetHash(_ url: URL) throws -> Data {
            try LocalMediaProcess.run(ffmpeg, ["-v", "error", "-i", url.path, "-map", "0:v:0", "-c:v", "copy", "-f", "hash", "-hash", "sha256", "pipe:1"],
                directory: root, cancellation: .init())
        }
        let sourceHash = try packetHash(source)
        for container in VideoExportRequest.Container.allCases {
            let request = VideoExportRequest(source: source, container: container, originalAudio: [english.index], subtitles: ["ru", "de"], defaultAudio: english.index)
            let saved = try SpeechExport.save(plan: [clip.chunk], prepared: [clip], duration: 3, german: german,
                destination: root.appendingPathComponent("result-" + container.rawValue), cancellation: .init(), video: request)
            let video = saved.appendingPathComponent("video." + container.rawValue)
            let info = try MediaInspection.read(video, cancellation: .init())
            XCTAssertEqual(info.audio.map(\.language), ["rus", "eng"])
            XCTAssertEqual(info.audio.map { $0.disposition?["default"] }, [0, 1])
            XCTAssertEqual(info.textSubtitles.map(\.language), ["rus", "deu"])
            XCTAssertEqual(info.textSubtitles.map { $0.disposition?["default"] }, [1, 0])
            XCTAssertEqual(try packetHash(video), sourceHash)
            let subtitles = try MediaInspection.extractSubtitles(video, stream: info.textSubtitles[0], cancellation: .init())
            XCTAssertEqual(subtitles.cues.map(\.text), ["Пример."])
            XCTAssertEqual(subtitles.cues[0].start, 0.25, accuracy: 0.001)
            XCTAssertEqual(try Data(contentsOf: source), originalBytes)
            let defaultSaved = try SpeechExport.save(plan: [clip.chunk], prepared: [clip], duration: 3, german: german,
                destination: root.appendingPathComponent("default-" + container.rawValue), cancellation: .init(),
                video: .init(source: source, container: container, originalAudio: [germanAudio.index], subtitles: ["de", "ru"], germanAudio: germanAudio.index))
            let defaultVideo = defaultSaved.appendingPathComponent("video." + container.rawValue)
            let defaults = try MediaInspection.read(defaultVideo, cancellation: .init())
            XCTAssertEqual(defaults.audio.map(\.language), ["rus", "deu"])
            XCTAssertEqual(defaults.audio.map { $0.disposition?["default"] }, [1, 0])
            XCTAssertEqual(defaults.textSubtitles.map(\.language), ["rus", "deu"])
            XCTAssertEqual(defaults.textSubtitles.map { $0.disposition?["default"] }, [1, 0])
            XCTAssertEqual(try packetHash(defaultVideo), sourceHash)
        }
        let russianOnly = try SpeechExport.save(plan: [clip.chunk], prepared: [clip], duration: 3, german: nil,
            destination: root.appendingPathComponent("russian"), cancellation: .init(),
            video: .init(source: source, container: .mp4, originalAudio: [], subtitles: []))
        let info = try MediaInspection.read(russianOnly.appendingPathComponent("video.mp4"), cancellation: .init())
        XCTAssertEqual(info.audio.map(\.language), ["rus"])
        XCTAssertEqual(info.audio[0].disposition?["default"], 1)
        XCTAssertTrue(info.textSubtitles.isEmpty)
        let invalidDestination = root.appendingPathComponent("invalid")
        XCTAssertThrowsError(try SpeechExport.save(plan: [clip.chunk], prepared: [clip], duration: 3, german: nil,
            destination: invalidDestination, cancellation: .init(),
            video: .init(source: source, container: .mp4, originalAudio: [999], subtitles: [])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidDestination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".lektien-export-") })
    }

    private func speech(root: URL) throws -> PreparedSpeechChunk {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 72_000))
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<72_000 { buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * .pi * 440 / 12_000) * 0.2) }
        let url = root.appendingPathComponent("voice.caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        let document = try SubtitleDocument(cues: [.init(identifier: 1, start: 0.25, end: 2, text: "Пример.")])
        return .init(chunk: .init(id: 0, start: 0, end: 3, document: document), audioURL: url)
    }
}
