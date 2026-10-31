import XCTest
import PlayerMedia
@testable import LektienOnlineUebersetzung

final class TelegramMediaTests: XCTestCase {
    @MainActor
    private final class Fetcher {
        struct Call { let offset: Int64; let length: Int; let completion: @Sendable (Result<Data, Error>) -> Void }
        var calls: [Call] = []
        var cancelled: [UUID] = []
        func fetch(_ id: UUID, _ offset: Int64, _ length: Int,
                   _ completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
            calls.append(.init(offset: offset, length: length, completion: completion))
        }
        func cancel(_ id: UUID) { cancelled.append(id) }
        func complete(_ index: Int, byte: UInt8 = 1) {
            let call = calls[index]
            call.completion(.success(Data(repeating: byte, count: call.length)))
        }
    }

    private var media: TelegramMedia {
        .init(id: 77, fileID: 9, name: "lecture.mp4", size: 5 * 1024 * 1024, type: "mp4")
    }
    func testParsesVideoAndDocumentAttachments() throws {
        let video = TelegramController.parseMedia([
            "id": NSNumber(value: Int64(42)),
            "date": NSNumber(value: Int64(1234)),
            "content": [
                "@type": "messageVideo",
                "video": ["file_name": "lecture.MP4", "video": ["id": 7, "size": 0, "expected_size": 123]]
            ]
        ])
        XCTAssertEqual(video?.name, "lecture.MP4")
        XCTAssertEqual(video?.fileID, 7)
        XCTAssertEqual(video?.type, "mp4")
        XCTAssertEqual(video?.size, 123)

        let subtitle = TelegramController.parseMedia([
            "id": NSNumber(value: Int64(43)),
            "content": [
                "@type": "messageDocument",
                "document": ["file_name": "lecture.ru.srt", "document": ["id": 8, "size": 321]]
            ]
        ])
        XCTAssertEqual(subtitle?.name, "lecture.ru.srt")
        XCTAssertEqual(subtitle?.fileID, 8)
    }

    func testVideoWithoutOriginalFilenameRemainsVisible() throws {
        let item = TelegramController.parseMedia([
            "id": NSNumber(value: Int64(44)),
            "date": NSNumber(value: Int64(5678)),
            "content": [
                "@type": "messageVideo",
                "video": ["file_name": "", "video": ["id": 9, "size": 456]]
            ]
        ])
        XCTAssertEqual(item?.name, "Telegram video 5678.mp4")
        XCTAssertEqual(item?.type, "mp4")
    }

    func testRejectsUnsupportedDocument() {
        let item = TelegramController.parseMedia([
            "id": NSNumber(value: Int64(45)),
            "content": [
                "@type": "messageDocument",
                "document": ["file_name": "notes.pdf", "document": ["id": 10]]
            ]
        ])
        XCTAssertNil(item)
    }

    func testLANEntryContainsNoTelegramOrLocalSecrets() throws {
        let entry = TelegramLANSource.Entry(
            id: String(repeating: "a", count: 64), name: "lecture.mp4",
            audio: false, subtitles: ["de"], source: "telegram"
        )
        let json = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        XCTAssertTrue(json.contains("lecture.mp4"))
        for forbidden in ["fileID", "messageID", "api_id", "api_hash", "session", "token", "/Users/"] {
            XCTAssertFalse(json.contains(forbidden))
        }
    }

    @MainActor
    func testPlaybackRangeTakesPriorityAfterCurrentRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = Fetcher()
        let store = try TelegramRangeStore(item: media, directory: root, fetch: fetcher.fetch)
        let first = Task { try await store.read(offset: 0, length: 8, priority: .preparation) }
        await Task.yield()
        let background = Task { try await store.read(offset: 1024 * 1024, length: 8, priority: .preparation) }
        let playback = Task { try await store.read(offset: 2 * 1024 * 1024, length: 8, priority: .playback) }
        for _ in 0..<20 where fetcher.calls.count < 1 { await Task.yield() }
        fetcher.complete(0)
        for _ in 0..<20 where fetcher.calls.count < 2 { await Task.yield() }
        XCTAssertEqual(fetcher.calls.map(\.offset), [Int64(0), Int64(2 * 1024 * 1024)])
        fetcher.complete(1)
        for _ in 0..<20 where fetcher.calls.count < 3 { await Task.yield() }
        fetcher.complete(2)
        _ = try await (first.value, playback.value, background.value)
    }

    @MainActor
    func testStoredRangeIsReusedWithoutDownloadingWholeVideo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFetcher = Fetcher()
        let store = try TelegramRangeStore(item: media, directory: root, fetch: firstFetcher.fetch)
        let request = Task { try await store.read(offset: 123, length: 64, priority: .preparation) }
        for _ in 0..<20 where firstFetcher.calls.isEmpty { await Task.yield() }
        XCTAssertEqual(firstFetcher.calls.first?.length, 1024 * 1024)
        XCTAssertLessThan(firstFetcher.calls.first!.length, Int(media.size))
        firstFetcher.complete(0, byte: 7)
        let firstData = try await request.value
        XCTAssertEqual(firstData, Data(repeating: 7, count: 64))
        let restartedFetcher = Fetcher()
        let restarted = try TelegramRangeStore(item: media, directory: root, fetch: restartedFetcher.fetch)
        let restartedData = try await restarted.read(offset: 123, length: 64, priority: .playback)
        XCTAssertEqual(restartedData, Data(repeating: 7, count: 64))
        XCTAssertTrue(restartedFetcher.calls.isEmpty)
    }

    @MainActor
    func testSelectingAnotherTelegramVideoRejectsLateRangeResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = Fetcher()
        let store = try TelegramRangeStore(item: media, directory: root, fetch: fetcher.fetch)
        let request = Task { try await store.read(offset: 0, length: 32, priority: .preparation) }
        for _ in 0..<20 where fetcher.calls.isEmpty { await Task.yield() }
        store.stop()
        do { _ = try await request.value; XCTFail("Stopped range must fail") }
        catch { XCTAssertEqual(error as? MediaFailure, .stopped) }
        fetcher.complete(0)
        await Task.yield()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("0.bin").path))
    }

    @MainActor
    func testCancelledPreparationRequestStopsTDLibAndUnblocksPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = Fetcher()
        let store = try TelegramRangeStore(item: media, directory: root, fetch: fetcher.fetch, cancel: fetcher.cancel)
        let obsolete = Task { try await store.read(offset: 0, length: 8, priority: .preparation) }
        for _ in 0..<20 where fetcher.calls.isEmpty { await Task.yield() }
        obsolete.cancel()
        let playback = Task { try await store.read(offset: 2 * 1024 * 1024, length: 8, priority: .playback) }
        for _ in 0..<20 where fetcher.calls.count < 2 { await Task.yield() }
        XCTAssertEqual(fetcher.cancelled.count, 1)
        XCTAssertEqual(fetcher.calls.map(\.offset), [0, Int64(2 * 1024 * 1024)])
        do { _ = try await obsolete.value; XCTFail("Cancelled range must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        fetcher.complete(1, byte: 9)
        let playbackData = try await playback.value
        XCTAssertEqual(playbackData, Data(repeating: 9, count: 8))
        fetcher.complete(0)
        await Task.yield()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("0.bin").path))
    }

    @MainActor
    func testRepeatedSeekRangesReuseCompletedBlocksAndIgnoreCancelledLateReplies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = Fetcher()
        let store = try TelegramRangeStore(item: media, directory: root, fetch: fetcher.fetch, cancel: fetcher.cancel)
        let block: Int64 = 1024 * 1024
        let first = Task { try await store.read(offset: 123, length: 64, priority: .playback) }
        for _ in 0..<100 where fetcher.calls.count < 1 { await Task.yield() }
        fetcher.complete(0, byte: 3)
        let firstData = try await first.value
        XCTAssertEqual(firstData, Data(repeating: 3, count: 64))
        for _ in 0..<3 {
            let repeated = try await store.read(offset: 456, length: 32, priority: .playback)
            XCTAssertEqual(repeated, Data(repeating: 3, count: 32))
        }
        XCTAssertEqual(fetcher.calls.count, 1)

        let obsolete = Task { try await store.read(offset: block + 10, length: 32, priority: .playback) }
        for _ in 0..<100 where fetcher.calls.count < 2 { await Task.yield() }
        obsolete.cancel()
        do { _ = try await obsolete.value; XCTFail("Cancelled seek must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        let latest = Task { try await store.read(offset: 3 * block + 20, length: 48, priority: .playback) }
        for _ in 0..<100 where fetcher.calls.count < 3 { await Task.yield() }
        fetcher.complete(1, byte: 9)
        fetcher.complete(2, byte: 7)
        let latestData = try await latest.value
        XCTAssertEqual(latestData, Data(repeating: 7, count: 48))
        XCTAssertEqual(fetcher.cancelled.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(block).bin").path))
        let repeatedLatest = try await store.read(offset: 3 * block + 100, length: 16, priority: .playback)
        XCTAssertEqual(repeatedLatest, Data(repeating: 7, count: 16))
        XCTAssertEqual(fetcher.calls.map(\.offset), [0, block, 3 * block])
    }

    @MainActor
    func testFFprobeReadsTelegramMediaThroughLoopbackRanges() async throws {
        guard ProcessInfo.processInfo.environment["LEKTIEN_RUNTIME_DIRECTORY"] != nil else {
            throw XCTSkip("Opt-in packaged FFmpeg integration")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        let ffmpeg = try MediaRuntime.executable("ffmpeg")
        let generator = Process()
        generator.executableURL = ffmpeg
        generator.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-c:a", "aac", source.path]
        try generator.run()
        generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)
        let bytes = try Data(contentsOf: source)
        let item = TelegramMedia(id: 12, fileID: 34, name: "source.mp4", size: Int64(bytes.count), type: "mp4")
        var fetched: [(offset: Int64, length: Int)] = []
        let store = try TelegramRangeStore(item: item, directory: root.appendingPathComponent("ranges")) { _, offset, length, completion in
            fetched.append((offset, length))
            completion(.success(bytes[Int(offset)..<Int(offset) + length]))
        }
        let server = TelegramMediaServer(store: store)
        let url = try await server.start()
        defer { server.stop() }
        let inspection = try await Task.detached { try MediaInspection.read(url, cancellation: MediaCancellation()) }.value
        XCTAssertNotNil(inspection.duration)
        XCTAssertEqual(inspection.audio.count, 1)
        let extracted = root.appendingPathComponent("section.wav")
        let decoder = Process()
        decoder.executableURL = ffmpeg
        decoder.arguments = ["-hide_banner", "-loglevel", "error", "-ss", "2", "-i", url.absoluteString,
                             "-t", "1", "-map", "0:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", extracted.path]
        try await Task.detached { try decoder.run(); decoder.waitUntilExit() }.value
        XCTAssertEqual(decoder.terminationStatus, 0)
        XCTAssertGreaterThan((try Data(contentsOf: extracted)).count, 16_000)
        XCTAssertFalse(fetched.isEmpty)
    }
}
