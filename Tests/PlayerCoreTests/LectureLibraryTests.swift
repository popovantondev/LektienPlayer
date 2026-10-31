import Foundation
import Testing
@testable import PlayerCore

@Test func findsVideoAndPairedSubtitles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lecture-library-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let video = root.appendingPathComponent("Лекция 01.mp4")
    let german = root.appendingPathComponent("Лекция 01.srt")
    let russian = root.appendingPathComponent("Лекция 01.ru.srt")
    FileManager.default.createFile(atPath: video.path, contents: Data())
    FileManager.default.createFile(atPath: german.path, contents: Data())
    FileManager.default.createFile(atPath: russian.path, contents: Data())

    let lectures = try LectureLibrary.scan(directory: root)
    #expect(lectures.count == 1)
    #expect(lectures[0].videoURL.resolvingSymlinksInPath() == video.resolvingSymlinksInPath())
    #expect(lectures[0].germanSubtitleURL?.resolvingSymlinksInPath() == german.resolvingSymlinksInPath())
    #expect(lectures[0].russianSubtitleURL?.resolvingSymlinksInPath() == russian.resolvingSymlinksInPath())
}

@Test func findsNestedVideosAndLeavesMissingSubtitlesEmpty() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lecture-library-\(UUID().uuidString)", isDirectory: true)
    let nested = root.appendingPathComponent("Курс", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let video = nested.appendingPathComponent("Лекция 02.mkv")
    FileManager.default.createFile(atPath: video.path, contents: Data())

    let lectures = try LectureLibrary.scan(directory: root)
    #expect(lectures.count == 1)
    #expect(lectures[0].germanSubtitleURL == nil)
    #expect(lectures[0].russianSubtitleURL == nil)
}
