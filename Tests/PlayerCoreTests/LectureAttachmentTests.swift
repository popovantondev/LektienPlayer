import XCTest
@testable import PlayerCore
@testable import PlayerLAN

final class LectureAttachmentTests: XCTestCase {
    func testAutodiscoveryFindsNamedExportSidecars() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("video.mp4")
        for name in ["video.mp4", "voice.ru.m4a", "voice.de.srt", "voice.ru.srt"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        let found = LectureAttachmentLocator.discover(for: video)
        XCTAssertEqual(found.russianAudio, "voice.ru.m4a")
        XCTAssertEqual(found.germanSubtitles, "voice.de.srt")
        XCTAssertEqual(found.russianSubtitles, "voice.ru.srt")
        XCTAssertNotNil(found.resolved(in: root, audio: true))
    }

    func testMissingAttachmentDoesNotResolveAndRejectsPaths() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = LectureAttachments(russianAudio: "missing.m4a", germanSubtitles: "../private.srt")
        XCTAssertNil(attachments.resolved(in: root, audio: true))
        XCTAssertNil(attachments.germanSubtitles)
        XCTAssertNil(LectureAttachmentLocator.reference(for: root.appendingPathComponent("other.m4a"), beside: root.appendingPathComponent("folder/video.mp4"), audio: true))
    }

    func testAttachmentSelectionPersistsWithoutAbsolutePathAndFeedsLANCatalog() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("lesson.mp4")
        try Data("video".utf8).write(to: video)
        try Data("audio".utf8).write(to: root.appendingPathComponent("lesson.ru.m4a"))
        try Data("1\n00:00:00,000 --> 00:00:01,000\nHallo\n".utf8).write(to: root.appendingPathComponent("lesson.de.srt"))
        try Data("1\n00:00:00,000 --> 00:00:01,000\nПривет\n".utf8).write(to: root.appendingPathComponent("lesson.ru.srt"))
        let store = try LibraryManifestStore(url: root.appendingPathComponent("manifest.json"))
        let source = LectureSource.local(path: video.path)
        let id = LibraryManifestStore.lectureID(for: source)
        _ = try store.update { $0.lectures[id] = .init(id: id, source: source, attachments: .init(russianAudio: "lesson.ru.m4a", germanSubtitles: "lesson.de.srt", russianSubtitles: "lesson.ru.srt")) }
        let restarted = try LibraryManifestStore(url: store.url).snapshot()
        let encoded = String(decoding: try JSONEncoder().encode(restarted.lectures[id]?.attachments), as: UTF8.self)
        XCTAssertFalse(encoded.contains(root.path))
        let library = try SharedLibrary(directory: root, manifest: restarted)
        let item = try XCTUnwrap(library.lectures.first)
        XCTAssertTrue(item.audio)
        XCTAssertEqual(item.subtitles, ["ru", "de"])
        XCTAssertEqual(item.attachments?.russianAudio, "lesson.ru.m4a")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(item), as: UTF8.self).contains(root.path))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
