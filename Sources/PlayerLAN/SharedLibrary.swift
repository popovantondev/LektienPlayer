import Foundation
import CryptoKit
import PlayerCore

public struct SharedLecture: Codable, Sendable {
    public let id: String
    public let name: String
    public let audio: Bool
    public let subtitles: [String]
    public let status: LecturePreparationStatus?
    public let cacheBytes: Int64?
    /// File names only; used by browsers to identify the selected sidecars.
    public let attachments: LectureAttachments?
    public init(id: String, name: String, audio: Bool, subtitles: [String],
                status: LecturePreparationStatus? = nil, cacheBytes: Int64? = nil,
                attachments: LectureAttachments? = nil) {
        self.id = id; self.name = name; self.audio = audio; self.subtitles = subtitles
        self.status = status; self.cacheBytes = cacheBytes
        self.attachments = attachments
    }
}

/// Explicit file allowlist: URLs and credentials are never part of the catalog.
public struct SharedLibrary: Sendable {
    public let root: URL
    public let lectures: [SharedLecture]
    let files: [String: URL]

    /// Library used when LAN sharing has only a remote source.
    public static func empty() -> SharedLibrary {
        SharedLibrary(root: URL(fileURLWithPath: "/"), lectures: [], files: [:])
    }

    private init(root: URL, lectures: [SharedLecture], files: [String: URL]) {
        self.root = root
        self.lectures = lectures
        self.files = files
    }

    public init(directory: URL, manifest: LibraryManifest? = nil) throws {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        self.root = root
        var entries: [SharedLecture] = []
        var allowed: [String: URL] = [:]
        for lecture in try LectureLibrary.scan(directory: root) {
            guard ["mp4", "m4v", "mkv"].contains(lecture.videoURL.pathExtension.lowercased()), Self.contains(lecture.videoURL, in: root) else { continue }
            let relative = String(lecture.videoURL.path.dropFirst(root.path.count))
            let id = SHA256.hash(data: Data(relative.utf8)).map { String(format: "%02x", $0) }.joined()
            let manifestID = LibraryManifestStore.lectureID(for: .local(path: lecture.videoURL.standardizedFileURL.path))
            let record = manifest?.lectures[manifestID]
            allowed["/media/\(id)/video"] = lecture.videoURL
            let parent = lecture.videoURL.deletingLastPathComponent()
            var base = lecture.videoURL.deletingPathExtension()
            if ["ru", "de"].contains(base.pathExtension) { base.deletePathExtension() }
            let exported = lecture.videoURL.lastPathComponent == "video.mp4"
            let selected = record?.attachments
            let voice = [selected?.resolved(in: parent, audio: true), base.appendingPathExtension("ru.m4a"), exported ? parent.appendingPathComponent("voice.ru.m4a") : nil]
                .compactMap { $0 }.first { Self.regular($0, in: root) }
            if let voice { allowed["/media/\(id)/audio"] = voice }
            var languages: [String] = []
            for (language, candidate) in [("ru", selected?.resolved(in: parent, language: .russian) ?? lecture.russianSubtitleURL), ("de", selected?.resolved(in: parent, language: .german) ?? lecture.germanSubtitleURL)] {
                let file = candidate ?? (exported ? parent.appendingPathComponent("voice.\(language).srt") : nil)
                if let file, Self.regular(file, in: root) {
                    allowed["/media/\(id)/\(language).vtt"] = file
                    languages.append(language)
                }
            }
            entries.append(.init(id: id, name: exported && voice != nil ? parent.lastPathComponent : lecture.title,
                                 audio: voice != nil, subtitles: languages, status: record?.status, cacheBytes: record?.cacheBytes,
                                 attachments: record?.attachments))
        }
        lectures = entries
        files = allowed
    }

    static func contains(_ url: URL, in root: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.path + "/")
    }
    static func regular(_ url: URL, in root: URL) -> Bool {
        contains(url, in: root) && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    public func file(for path: String) -> URL? {
        guard let url = files[path], Self.regular(url, in: root) else { return nil }
        return url
    }

    static func vtt(_ url: URL) throws -> Data {
        try vtt(SRTParser.parse(text: String(contentsOf: url, encoding: .utf8)))
    }
    public static func vtt(_ document: SubtitleDocument) -> Data {
        func time(_ seconds: Double) -> String {
            let ms = Int64((seconds * 1000).rounded())
            return String(format: "%02lld:%02lld:%02lld.%03lld", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        let body = document.cues.map { cue in
            let text = cue.text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            return "\(time(cue.start)) --> \(time(cue.end))\n\(text)\n"
        }.joined(separator: "\n")
        return Data(("WEBVTT\n\n" + body).utf8)
    }
}

struct HTTPByteRange: Equatable {
    let start: UInt64
    let count: UInt64
    static func parse(_ header: String?, size: UInt64) throws -> HTTPByteRange {
        guard let header else { return .init(start: 0, count: size) }
        guard size > 0, header.hasPrefix("bytes=") else { throw RangeError.invalid }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw RangeError.invalid }
        if parts[0].isEmpty {
            guard let suffix = UInt64(parts[1]), suffix > 0 else { throw RangeError.invalid }
            let count = min(suffix, size)
            return .init(start: size - count, count: count)
        }
        guard let start = UInt64(parts[0]), start < size else { throw RangeError.invalid }
        let end: UInt64
        if parts[1].isEmpty { end = size - 1 }
        else {
            guard let requested = UInt64(parts[1]), requested >= start else { throw RangeError.invalid }
            end = min(requested, size - 1)
        }
        return .init(start: start, count: end - start + 1)
    }
    enum RangeError: Error { case invalid }
}
