import XCTest
import PlayerCore
import PlayerTranslation

final class TranslationWindowCacheTests: XCTestCase {
    func testWindowCacheDoesNotPublishPartialLectureAndInvalidatesChangedContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try SubtitleDocument(cues: [
            .init(identifier: 1, start: 0, end: 2, text: "Einleitung."),
            .init(identifier: 2, start: 2, end: 4, text: "Das Herz."),
            .init(identifier: 3, start: 4, end: 6, text: "Abschluss.")])
        let window = try SubtitleDocument(cues: [source.cues[1]])
        let settings = TranslationSettings(model: "gpt-5.6-luna", effort: "medium")
        let video = root.appendingPathComponent("sample.mp4")
        XCTAssertNil(try TranslationSession.cachedDocument(document: window, videoURL: video, settings: settings, contextDocument: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Cache lookup must not create directories")
        let result = try TranslationSession.run(document: window, videoURL: video, settings: settings, cancellation: .init(),
            contextDocument: source, publishAlongsideVideo: false,
            translate: { _, _, _ in .init(translations: [.init(id: 2, text: "Сердце.")], reviewIDs: [2]) }, progress: { _ in })
        XCTAssertTrue(result.subtitleURL.path.contains("/.lektien/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sample.ru.srt").path))
        let cached = try XCTUnwrap(TranslationSession.cachedDocument(document: window, videoURL: video, settings: settings, contextDocument: source))
        XCTAssertEqual(cached.0, result.document)
        XCTAssertEqual(cached.1, [2])
        let changed = try SubtitleDocument(cues: [
            .init(identifier: 1, start: 0, end: 2, text: "Andere Einleitung."), source.cues[1], source.cues[2]])
        XCTAssertNil(try TranslationSession.cachedDocument(document: window, videoURL: video, settings: settings, contextDocument: changed))
    }
}
