import Foundation
import PlayerCore

public struct MediaStream: Decodable, Identifiable, Equatable, Sendable {
    public let index: Int
    public let codec_type: String?
    public let codec_name: String?
    public let profile: String?
    public let level: Int?
    public let pix_fmt: String?
    public let tags: [String: String]?
    public let disposition: [String: Int]?
    public var id: Int { index }
    public var language: String { tags?["language"]?.lowercased() ?? "und" }
    public var title: String { tags?["title"] ?? "\(language.uppercased()) · \(index + 1)" }
    public var isGerman: Bool { ["de", "deu", "ger"].contains(language) }
    public var isRussian: Bool { ["ru", "rus"].contains(language) }
    public var isTextSubtitle: Bool {
        codec_type == "subtitle" && ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"].contains(codec_name ?? "")
    }
}

public struct MediaInspection: Decodable, Sendable {
    public struct Format: Decodable, Sendable { public let duration: String?; public let format_name: String? }
    public let streams: [MediaStream]
    public let format: Format?
    public var duration: Double? { format?.duration.flatMap(Double.init) }
    public var audio: [MediaStream] { streams.filter { $0.codec_type == "audio" } }
    public var textSubtitles: [MediaStream] { streams.filter(\.isTextSubtitle) }

    public static func read(_ video: URL, cancellation: MediaCancellation) throws -> Self {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lektien-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = try LocalMediaProcess.run(MediaRuntime.executable("ffprobe"),
            ["-v", "error", "-show_entries", "format=duration,format_name:stream=index,codec_type,codec_name,profile,level,pix_fmt:stream_tags=language,title:stream_disposition=default", "-of", "json", inputArgument(video)],
            directory: temporary, cancellation: cancellation)
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public static func extractSubtitles(_ video: URL, stream: MediaStream, cancellation: MediaCancellation) throws -> SubtitleDocument {
        guard stream.isTextSubtitle else { throw MediaFailure.invalidOutput }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lektien-subtitle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = try LocalMediaProcess.run(MediaRuntime.executable("ffmpeg"),
            ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", inputArgument(video), "-map", "0:\(stream.index)", "-f", "srt", "-c:s", "srt", "pipe:1"],
            directory: temporary, cancellation: cancellation)
        return try SRTParser.parse(data: data)
    }

    private static func inputArgument(_ url: URL) -> String {
        url.isFileURL ? url.path : url.absoluteString
    }
}
