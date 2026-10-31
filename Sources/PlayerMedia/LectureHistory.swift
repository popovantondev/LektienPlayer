import Foundation
import PlayerCore

public struct LectureHistory: Codable, Equatable, Sendable {
    public var position: Double = 0
    public var recognitionStream: Int?
    public var recognitionSubtitle: String?
    public var recognitionSubtitleHash: String?
    private var mediaSize: Int?
    private var mediaModified: Date?
    private var remoteIdentity: String?

    public init() {}

    public static func load(video: URL) -> Self {
        guard let data = try? Data(contentsOf: location(video)), let saved = try? JSONDecoder().decode(Self.self, from: data),
              let values = try? FileManager.default.attributesOfItem(atPath: video.path),
              (values[.size] as? NSNumber)?.intValue == saved.mediaSize, values[.modificationDate] as? Date == saved.mediaModified,
              saved.position.isFinite, saved.position >= 0 else { return .init() }
        return saved
    }

    public static func load(video: URL, remoteIdentity: String) -> Self {
        guard let data = try? Data(contentsOf: location(video)),
              let saved = try? JSONDecoder().decode(Self.self, from: data),
              saved.remoteIdentity == remoteIdentity,
              saved.position.isFinite, saved.position >= 0 else { return .init() }
        return saved
    }

    public func save(video: URL) throws {
        guard position.isFinite, position >= 0 else { throw MediaFailure.invalidOutput }
        var copy = self
        let values = try FileManager.default.attributesOfItem(atPath: video.path)
        copy.mediaSize = (values[.size] as? NSNumber)?.intValue; copy.mediaModified = values[.modificationDate] as? Date
        let destination = Self.location(video)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // This is a replaceable playback pointer, never a subtitle or completed processing result.
        try JSONEncoder().encode(copy).write(to: destination, options: .atomic)
    }

    public func save(video: URL, remoteIdentity: String) throws {
        guard position.isFinite, position >= 0, !remoteIdentity.isEmpty else { throw MediaFailure.invalidOutput }
        var copy = self
        copy.remoteIdentity = remoteIdentity
        let destination = Self.location(video)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(copy).write(to: destination, options: .atomic)
    }

    public func matchesRecognitionSource(subtitle: URL?, content: String?) -> Bool {
        guard recognitionStream != nil else { return false }
        guard let subtitle else { return true }
        guard let content, recognitionSubtitle == subtitle.lastPathComponent else { return false }
        return recognitionSubtitleHash == MediaPublication.hash(Data(content.utf8))
    }

    public func restoredRecognitionSource(video: URL) -> (url: URL, document: SubtitleDocument)? {
        guard recognitionStream != nil, let name = recognitionSubtitle,
              name == (name as NSString).lastPathComponent, !name.isEmpty else { return nil }
        let url = video.deletingLastPathComponent().appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url), let document = try? SRTParser.parse(data: data),
              matchesRecognitionSource(subtitle: url, content: MediaPublication.srt(document)) else { return nil }
        return (url, document)
    }

    private static func location(_ video: URL) -> URL {
        let name = video.lastPathComponent.precomposedStringWithCanonicalMapping
        let key = MediaPublication.hash(Data(name.utf8))
        return video.deletingLastPathComponent().appendingPathComponent(".lektien/library/\(key).json")
    }
}
