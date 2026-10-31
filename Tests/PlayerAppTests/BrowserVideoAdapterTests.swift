import Foundation
import XCTest
import PlayerLAN
import PlayerMedia
@testable import LektienOnlineUebersetzung

@MainActor
final class BrowserVideoAdapterTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var methods: [BrowserVideoAdapter.Method] = []
        func encode(_ input: URL, _ plan: BrowserVideoAdapter.Plan, _ start: Double, _ duration: Double,
                    _ directory: URL, _ cancellation: MediaCancellation) throws -> BrowserVideoAdapter.Output {
            try cancellation.check()
            lock.withLock { methods.append(plan.method) }
            let initialization = directory.appendingPathComponent("init.mp4")
            let segment = directory.appendingPathComponent("part.m4s")
            try Data("init".utf8).write(to: initialization)
            try Data("segment-\(Int(start))".utf8).write(to: segment)
            return .init(initialization: initialization, segment: segment)
        }
        var count: Int { lock.withLock { methods.count } }
    }
    private final class CancellationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var didStart = false
        private var didCancel = false
        func encode(_ input: URL, _ plan: BrowserVideoAdapter.Plan, _ start: Double, _ duration: Double,
                    _ directory: URL, _ cancellation: MediaCancellation) throws -> BrowserVideoAdapter.Output {
            if start == 0 {
                lock.withLock { didStart = true }
                do {
                    while true { try cancellation.check(); Thread.sleep(forTimeInterval: 0.005) }
                } catch { lock.withLock { didCancel = true }; throw error }
            }
            let initialization = directory.appendingPathComponent("init.mp4")
            let segment = directory.appendingPathComponent("part.m4s")
            try Data("init".utf8).write(to: initialization); try Data("new".utf8).write(to: segment)
            return .init(initialization: initialization, segment: segment)
        }
        var started: Bool { lock.withLock { didStart } }
        var cancelled: Bool { lock.withLock { didCancel } }
    }

    private func inspection(container: String = "matroska", video: String = "h264", audio: String? = "aac") throws -> MediaInspection {
        let audioJSON = audio.map { #",{"index":1,"codec_type":"audio","codec_name":"\#($0)"}"# } ?? ""
        let json = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"\#(video)","profile":"High","level":31}\#(audioJSON)],"format":{"duration":"25","format_name":"\#(container)"}}"#
        return try JSONDecoder().decode(MediaInspection.self, from: Data(json.utf8))
    }
    private func source(root: URL, container: String) -> BrowserVideoAdapter.Source {
        .init(id: String(repeating: "a", count: 64), input: root.appendingPathComponent("source.\(container)"),
              directURL: "/media/a/video", container: container,
              cacheRoot: root.appendingPathComponent("cache"), identity: "fixture")
    }

    func testDirectMP4DoesNotStartFFmpeg() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder(), media = try inspection(container: "mov,mp4", video: "h264", audio: "aac")
        let adapter = BrowserVideoAdapter(inspect: { _, _ in media }, encode: recorder.encode)
        let descriptor = await adapter.open(source(root: root, container: "mp4"))
        XCTAssertEqual(descriptor.mode, "direct")
        XCTAssertEqual(descriptor.url, "/media/a/video")
        XCTAssertEqual(recorder.count, 0)
    }

    func testDamagedMediaReturnsOneClearFailureWithoutFFmpeg() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        let adapter = BrowserVideoAdapter(inspect: { _, _ in throw MediaFailure.failed }, encode: recorder.encode)
        let descriptor = await adapter.open(source(root: root, container: "mkv"))
        XCTAssertEqual(descriptor.mode, "failed")
        XCTAssertEqual(descriptor.error, "videoInvalid")
        XCTAssertEqual(recorder.count, 0)
    }

    func testPlansRemuxAudioConversionAndVideoConversion() async throws {
        for (video, audio, expected) in [("h264", "aac", BrowserVideoAdapter.Method.remux),
                                         ("h264", "opus", .audioTranscode), ("hevc", "opus", .transcode)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let recorder = Recorder(), media = try inspection(video: video, audio: audio)
            let adapter = BrowserVideoAdapter(inspect: { _, _ in media }, encode: recorder.encode)
            let descriptor = await adapter.open(source(root: root, container: "mkv"))
            XCTAssertEqual(descriptor.mode, "adapted")
            let response = await adapter.response(for: "/adapted/\(String(repeating: "a", count: 64))/0.media.m4s")
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(recorder.methods, [expected])
        }
    }

    func testPlaylistEndCacheReuseAndPartialFilesAreNotPublished() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder(), media = try inspection()
        let source = source(root: root, container: "mkv")
        var adapter = BrowserVideoAdapter(inspect: { _, _ in media }, encode: recorder.encode)
        _ = await adapter.open(source)
        let playlist = await adapter.response(for: "/adapted/\(source.id)/index.m3u8")
        XCTAssertEqual(playlist.contentType, "application/vnd.apple.mpegurl")
        let text = String(decoding: playlist.data, as: UTF8.self)
        XCTAssertTrue(text.contains("#EXT-X-ENDLIST")); XCTAssertTrue(text.contains("2.media.m4s"))
        let partial = await adapter.response(for: "/adapted/\(source.id)/partial-file.m4s")
        let first = await adapter.response(for: "/adapted/\(source.id)/0.media.m4s")
        XCTAssertEqual(partial.status, 404)
        XCTAssertNotNil(first.file)
        XCTAssertEqual(recorder.count, 1)
        adapter.reset()
        adapter = BrowserVideoAdapter(inspect: { _, _ in media }, encode: recorder.encode)
        _ = await adapter.open(source)
        let reused = await adapter.response(for: "/adapted/\(source.id)/0.media.m4s")
        XCTAssertNotNil(reused.file)
        XCTAssertEqual(recorder.count, 1)
        let pastEnd = await adapter.response(for: "/adapted/\(source.id)/3.media.m4s")
        XCTAssertEqual(pastEnd.status, 422)
    }

    func testSeekCancelsObsoleteFFmpegWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = CancellationRecorder(), media = try inspection()
        let adapter = BrowserVideoAdapter(inspect: { _, _ in media }, encode: recorder.encode)
        let source = source(root: root, container: "mkv")
        _ = await adapter.open(source)
        adapter.update(id: source.id, position: 0)
        for _ in 0..<100 where !recorder.started { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(recorder.started)
        adapter.update(id: source.id, position: 24)
        let latest = await adapter.response(for: "/adapted/\(source.id)/2.media.m4s")
        XCTAssertEqual(latest.status, 200)
        for _ in 0..<100 where !recorder.cancelled { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(recorder.cancelled)
    }

    func testRealFFmpegSegmentOptIn() async throws {
        guard let path = ProcessInfo.processInfo.environment["LEKTIEN_VIDEO_ADAPTATION_TEST"] else {
            throw XCTSkip("Opt-in packaged FFmpeg/fMP4 integration with a small synthetic H.264/AAC fixture")
        }
        let input = URL(fileURLWithPath: path)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = BrowserVideoAdapter.Source(id: String(repeating: "b", count: 64), input: input,
            directURL: "/media/b/video", container: "mkv", cacheRoot: root, identity: "real")
        let adapter = BrowserVideoAdapter()
        let descriptor = await adapter.open(source)
        XCTAssertEqual(descriptor.mode, "adapted")
        let initialization = await adapter.response(for: "/adapted/\(source.id)/0.init.mp4")
        let media = await adapter.response(for: "/adapted/\(source.id)/0.media.m4s")
        XCTAssertEqual(initialization.status, 200); XCTAssertEqual(media.status, 200)
        XCTAssertGreaterThan((try initialization.file?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 100)
        XCTAssertGreaterThan((try media.file?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 100)
    }
}
