import XCTest
import PlayerCore

final class AdjacentSubtitleTests: XCTestCase {
    func testRussianAssembledVideoFindsBothOriginalSidecars() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let german = root.appendingPathComponent("lesson.srt")
        let russian = root.appendingPathComponent("lesson.ru.srt")
        try Data().write(to: german)
        try Data().write(to: russian)
        let result = LectureLibrary.adjacentSubtitles(for: root.appendingPathComponent("lesson.ru.mp4"))
        XCTAssertEqual(result.germanSubtitleURL, german)
        XCTAssertEqual(result.russianSubtitleURL, russian)
        let reviewed = root.appendingPathComponent("lesson.ru.reviewed.srt")
        try Data().write(to: reviewed)
        XCTAssertEqual(LectureLibrary.adjacentSubtitles(for: root.appendingPathComponent("lesson.ru.mp4")).russianSubtitleURL, reviewed)
        let explicit = root.appendingPathComponent("lesson.de.srt")
        try Data().write(to: explicit)
        XCTAssertEqual(LectureLibrary.adjacentSubtitles(for: root.appendingPathComponent("lesson.mp4")).germanSubtitleURL, explicit)
    }
}
