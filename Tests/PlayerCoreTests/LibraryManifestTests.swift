import Foundation
import XCTest
@testable import PlayerCore
@testable import PlayerTranslation

final class LibraryManifestTests: XCTestCase {
    private func temporaryStore() throws -> (URL, LibraryManifestStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try LibraryManifestStore(url: root.appendingPathComponent("manifest.json")))
    }

    func testStatusAndLanguageTracksPersistWithoutReadingVideoContents() throws {
        let (root, store) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("lecture.mp4")
        try Data(repeating: 7, count: 32).write(to: video)
        try Data("de".utf8).write(to: root.appendingPathComponent("lecture.de.srt"))
        try Data("ru".utf8).write(to: root.appendingPathComponent("lecture.ru.reviewed.srt"))
        try Data("audio".utf8).write(to: root.appendingPathComponent("lecture.ru.m4a"))
        let manifest = try LectureLibrary.refreshManifest(directory: root, store: store)
        let status = try XCTUnwrap(manifest.lectures.values.first?.status)
        XCTAssertTrue(status.hasGermanSubtitles)
        XCTAssertTrue(status.translated)
        XCTAssertTrue(status.reviewed)
        XCTAssertTrue(status.voiced)
        XCTAssertEqual(Set(status.languages), Set(["de", "ru", "ru-audio"]))
        XCTAssertTrue(status.fullyReady)
    }

    func testQueueReorderRemoveAndRestartRequireExplicitAutoContinue() async throws {
        let (root, store) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let ids = ["a", "b", "c"]
        _ = try store.update { value in
            for id in ids { value.lectures[id] = .init(id: id, source: .local(path: "/\(id).mp4")) }
        }
        let queue = PersistentPreparationQueue(store: store) { _ in }
        try await queue.add(ids)
        try await queue.move(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.snapshot().queue.map(\.lectureID), ["c", "a", "b"])
        let remove = store.snapshot().queue[1].id
        try await queue.remove(remove)
        XCTAssertEqual(store.snapshot().queue.map(\.lectureID), ["c", "b"])
        _ = try store.update { $0.queueRunning = true; $0.queue[0].state = .running }
        _ = PersistentPreparationQueue(store: try LibraryManifestStore(url: store.url)) { _ in }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(try LibraryManifestStore(url: store.url).snapshot().queueRunning)
        XCTAssertEqual(try LibraryManifestStore(url: store.url).snapshot().queue.first?.state, .waiting)
    }

    func testAutoContinueRestoresOrderAndRunsSequentiallyAfterPriorityClears() async throws {
        let (root, store) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.update { value in
            for id in ["a", "b"] { value.lectures[id] = .init(id: id, source: .local(path: "/\(id).mp4")) }
            value.queue = [PreparationQueueItem(lectureID: "a"), PreparationQueueItem(lectureID: "b")]
            value.autoContinue = true
        }
        let recorder = LockedRecorder()
        let queue = PersistentPreparationQueue(store: store) { lecture in
            recorder.begin(lecture.id); try await Task.sleep(for: .milliseconds(20)); recorder.end()
        }
        await queue.setInteractive(true)
        try await queue.start()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(recorder.values.isEmpty)
        await queue.setInteractive(false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(recorder.values, ["a", "b"])
        XCTAssertEqual(recorder.maximumConcurrent, 1)
        XCTAssertTrue(store.snapshot().queue.isEmpty)
    }

    func testCorruptManifestRecoversLastGoodRevision() throws {
        let (root, store) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.update { $0.autoContinue = true }
        _ = try store.update { $0.cache.selectedRoot = "portable/cache" }
        try Data("broken".utf8).write(to: store.url)
        let recovered = try LibraryManifestStore(url: store.url).snapshot()
        XCTAssertTrue(recovered.autoContinue)
        XCTAssertNil(recovered.cache.selectedRoot) // backup is the previous valid revision
    }

    func testCacheUsageAndCleanupPlanExcludeOriginalsAndExports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-plan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent(".lektien")
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("speech"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("library"), withIntermediateDirectories: true)
        try Data(count: 11).write(to: cache.appendingPathComponent("speech/a.wav"))
        try Data(count: 5).write(to: cache.appendingPathComponent("library/history.json"))
        try Data(count: 100).write(to: root.appendingPathComponent("original.mp4"))
        try Data(count: 7).write(to: root.appendingPathComponent("original.de.srt"))
        let usage = DerivedCacheInspector.usage(at: cache)
        XCTAssertEqual(usage.totalBytes, 16)
        XCTAssertEqual(DerivedCacheInspector.safeCleanupPlan(at: cache).map(\.lastPathComponent), ["speech"])
    }

    func testPortableCacheRootAndCleanupNeverTouchDurableFiles() throws {
        let (root, store) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library")
        let cache = library.appendingPathComponent("derived")
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("speech"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("library"), withIntermediateDirectories: true)
        try Data([1]).write(to: cache.appendingPathComponent("speech/clip.wav"))
        try Data([2]).write(to: cache.appendingPathComponent("library/history.json"))
        try Data([3]).write(to: library.appendingPathComponent("original.mp4"))
        _ = try store.update { manifest in
            manifest.lectures["local"] = .init(id: "local", source: .local(path: "lecture.mp4"), cacheBytes: 1)
            manifest.lectures["telegram"] = .init(id: "telegram", source: .telegram(chatID: 1, messageID: 2, fileID: 3, name: "remote.mp4", size: 4), cacheBytes: 9)
        }
        let relative = try XCTUnwrap(DerivedCacheLocation.relativePath(from: library, to: cache))
        XCTAssertEqual(relative, "derived")
        XCTAssertNil(DerivedCacheLocation.relativePath(from: library, to: root))
        _ = try store.update { $0.cache.selectedRoot = relative }
        let encoded = try String(decoding: JSONEncoder().encode(store.snapshot()), as: UTF8.self)
        XCTAssertFalse(encoded.contains(library.path))
        DerivedCacheLocation.configure(libraryRoot: library, relativeRoot: relative)
        XCTAssertEqual(DerivedCacheLocation.directory(for: library.appendingPathComponent("original.mp4"), category: "speech"), cache.appendingPathComponent("speech"))
        _ = try DerivedCacheInspector.cleanup(at: cache, store: store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("speech").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("library/history.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("original.mp4").path))
        XCTAssertEqual(store.snapshot().lectures["local"]?.cacheBytes, 0)
        XCTAssertEqual(store.snapshot().lectures["telegram"]?.cacheBytes, 9)
    }

    func testManifestRejectsAbsoluteCacheRoot() throws {
        let (_, store) = try temporaryStore()
        XCTAssertThrowsError(try store.update { $0.cache.selectedRoot = "/private/cache" })
        XCTAssertThrowsError(try store.update { $0.cache.selectedRoot = "../cache" })
    }

    func testModelWorkerGateAllowsOnlyOneWorkerAndReuseSkipsIt() async throws {
        let recorder = LockedRecorder()
        let calls = (0..<3).map { _ in Task.detached {
            let cancellation = TranslationCancellation()
            return try ModelWorkerGate.withWorker(cancellation) {
                recorder.begin("request"); Thread.sleep(forTimeInterval: 0.02); recorder.end(); return 1
            }
        }}
        for call in calls { _ = try await call.value }
        XCTAssertEqual(recorder.maximumConcurrent, 1)
        let cacheHit = true
        if !cacheHit { _ = try ModelWorkerGate.withWorker(TranslationCancellation()) { recorder.begin("unexpected"); recorder.end() } }
        XCTAssertEqual(recorder.values.count, 3)
    }
}

private final class LockedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var concurrent = 0
    private var maximum = 0
    private var recorded: [String] = []
    var values: [String] { lock.withLock { recorded } }
    var maximumConcurrent: Int { lock.withLock { maximum } }
    func begin(_ value: String) { lock.withLock { concurrent += 1; maximum = max(maximum, concurrent); recorded.append(value) } }
    func end() { lock.withLock { concurrent -= 1 } }
}
