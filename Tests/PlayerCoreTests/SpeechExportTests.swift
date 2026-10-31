import AVFoundation
import XCTest
import PlayerCore
import PlayerMedia
import PlayerSpeech
import PlayerExport

final class SpeechExportTests: XCTestCase {
    func testAbsoluteTimingTailAndCollisionPreserveExistingResults() throws {
        guard ProcessInfo.processInfo.environment["LEKTIEN_RUNTIME_DIRECTORY"] != nil else {
            throw XCTSkip("Opt-in bundled media encoder")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try clip(root: root, id: 0, start: 1, end: 3, length: 0.5)
        let second = try clip(root: root, id: 1, start: 4, end: 5, length: 0.5)
        let target = root.appendingPathComponent("result")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let marker = target.appendingPathComponent("preserve.txt")
        try Data("existing".utf8).write(to: marker)
        let output = try SpeechExport.save(plan: [first.chunk, second.chunk], prepared: [second, first], duration: 6,
            german: nil, destination: target, cancellation: .init())
        XCTAssertNotEqual(output, target)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "existing")
        let audio = try AVAudioFile(forReading: output.appendingPathComponent("voice.ru.m4a"))
        XCTAssertEqual(Double(audio.length) / audio.processingFormat.sampleRate, 6, accuracy: 0.06)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: buffer)
        func rms(_ time: Double) -> Double {
            let start = Int(time * audio.processingFormat.sampleRate)
            let samples = buffer.floatChannelData![0]
            return sqrt((start..<(start + 1200)).reduce(0.0) { $0 + Double(samples[$1] * samples[$1]) } / 1200)
        }
        for time in [0.2, 2.0, 3.5, 5.5] { XCTAssertLessThan(rms(time), 0.001, "Gap at \(time) must remain silent") }
        for time in [1.15, 4.15] { XCTAssertGreaterThan(rms(time), 0.1, "Speech must start at its absolute time") }
        let subtitles = try SRTParser.parse(data: Data(contentsOf: output.appendingPathComponent("voice.ru.srt")))
        XCTAssertEqual(subtitles.cues.map(\.start), [1, 4])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".lektien-export") })
    }

    func testIncompleteOverlongAndCancelledExportNeverPublishes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let clip = try clip(root: root, id: 0, start: 0, end: 1, length: 2)
        let destination = root.appendingPathComponent("result")
        XCTAssertThrowsError(try SpeechExport.save(plan: [clip.chunk], prepared: [], duration: 3,
            german: nil, destination: destination, cancellation: .init()))
        XCTAssertThrowsError(try SpeechExport.save(plan: [clip.chunk], prepared: [clip], duration: 3,
            german: nil, destination: destination, cancellation: .init()))
        let control = MediaCancellation(); control.cancel()
        XCTAssertThrowsError(try SpeechExport.save(plan: [clip.chunk], prepared: [clip], duration: 3,
            german: nil, destination: destination, cancellation: control)) { XCTAssertEqual($0 as? MediaFailure, .stopped) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".lektien-export") })
    }

    private func clip(root: URL, id: Int, start: Double, end: Double, length: Double) throws -> PreparedSpeechChunk {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length * 24_000)))
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 24_000) * 0.4) }
        let url = root.appendingPathComponent("\(id).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        let doc = try SubtitleDocument(cues: [.init(identifier: id + 1, start: 0, end: min(0.5, end - start), text: "Пример.")])
        return .init(chunk: .init(id: id, start: start, end: end, document: doc), audioURL: url)
    }
}
