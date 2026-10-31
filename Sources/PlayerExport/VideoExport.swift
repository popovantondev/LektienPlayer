import Foundation
import PlayerCore
import PlayerMedia

public struct VideoExportRequest: Sendable {
    public enum Container: String, CaseIterable, Sendable { case mp4, mkv }
    public let source: URL
    public let container: Container
    public let originalAudio: [Int]
    public let subtitles: [String]
    /// nil selects Kseniya; other values are original stream indices.
    public let defaultAudio: Int?
    /// The source explicitly selected for German recognition, even when its file tag is missing.
    public let germanAudio: Int?

    public init(source: URL, container: Container, originalAudio: [Int], subtitles: [String], defaultAudio: Int? = nil, germanAudio: Int? = nil) {
        self.source = source; self.container = container; self.originalAudio = originalAudio
        self.subtitles = subtitles; self.defaultAudio = defaultAudio
        self.germanAudio = germanAudio
    }
}

/// Muxes only inside the export's private staging folder; publication belongs to SpeechExport.
public enum VideoExport {
    public static func supportsMP4(_ inspection: MediaInspection) -> Bool {
        guard let video = inspection.streams.first(where: { $0.codec_type == "video" }) else { return false }
        return ["h264", "hevc", "mpeg4", "av1"].contains(video.codec_name ?? "")
    }

    static func add(to directory: URL, request: VideoExportRequest, cancellation: MediaCancellation) throws {
        let original = try MediaInspection.read(request.source, cancellation: cancellation)
        guard let video = original.streams.first(where: { $0.codec_type == "video" }),
              request.container != .mp4 || supportsMP4(original),
              Set(request.originalAudio).count == request.originalAudio.count,
              Set(request.originalAudio).isSubset(of: Set(original.audio.map(\.index))),
              request.defaultAudio == nil || request.originalAudio.contains(request.defaultAudio!),
              request.germanAudio == nil || original.audio.contains(where: { $0.index == request.germanAudio }),
              Set(request.subtitles).count == request.subtitles.count,
              Set(request.subtitles).isSubset(of: ["ru", "de"]) else { throw MediaFailure.invalidOutput }
        let output = directory.appendingPathComponent("video." + request.container.rawValue)
        // Russian is first even when callers supplied the subtitle selection in another order.
        let subtitles = ["ru", "de"].filter { request.subtitles.contains($0) }
        var args = ["-nostdin", "-v", "error", "-n", "-i", request.source.path,
                    "-i", directory.appendingPathComponent("voice.ru.m4a").path]
        for language in subtitles {
            args += ["-i", directory.appendingPathComponent("voice.\(language).srt").path]
        }
        args += ["-map", "0:\(video.index)", "-map", "1:a:0"]
        for index in request.originalAudio { args += ["-map", "0:\(index)"] }
        for index in subtitles.indices { args += ["-map", "\(index + 2):s:0"] }
        args += ["-map_metadata", "0", "-map_chapters", "0", "-c:v", "copy", "-c:a", "copy",
                 "-disposition:a", "0"]
        // Keep compatible originals unchanged; convert only audio that MP4 cannot carry.
        if request.container == .mp4 {
            for (index, sourceIndex) in request.originalAudio.enumerated() {
                let codec = original.audio.first { $0.index == sourceIndex }?.codec_name ?? ""
                if !["aac", "mp3", "ac3", "eac3", "alac"].contains(codec) {
                    args += ["-c:a:\(index + 1)", "aac", "-b:a:\(index + 1)", "192k"]
                }
            }
            args += ["-movflags", "+faststart"]
            if video.codec_name == "hevc" { args += ["-tag:v:0", "hvc1"] }
        }
        let defaultIndex = request.defaultAudio.flatMap { request.originalAudio.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        args += ["-metadata:s:a:0", "language=rus", "-metadata:s:a:0", "title=Kseniya", "-metadata:s:a:0", "handler_name=Kseniya · RU",
                 "-disposition:a:\(defaultIndex)", "default"]
        if let german = request.germanAudio, let index = request.originalAudio.firstIndex(of: german) {
            args += ["-metadata:s:a:\(index + 1)", "language=deu",
                     "-metadata:s:a:\(index + 1)", "title=Deutsch",
                     "-metadata:s:a:\(index + 1)", "handler_name=Deutsch"]
        }
        if !subtitles.isEmpty {
            args += ["-c:s", request.container == .mp4 ? "mov_text" : "srt", "-disposition:s", "0"]
            for (index, language) in subtitles.enumerated() {
                args += ["-metadata:s:s:\(index)", "language=\(language == "ru" ? "rus" : "deu")",
                         "-metadata:s:s:\(index)", "title=\(language.uppercased())",
                         "-metadata:s:s:\(index)", "handler_name=\(language.uppercased())",
                         "-disposition:s:\(index)", language == "ru" ? "default" : "0"]
            }
        }
        args += ["-threads", "1", output.path]
        _ = try LocalMediaProcess.run(MediaRuntime.executable("ffmpeg"), args, directory: directory, cancellation: cancellation)
        let saved = try MediaInspection.read(output, cancellation: cancellation)
        guard saved.streams.filter({ $0.codec_type == "video" }).count == 1,
              saved.audio.count == request.originalAudio.count + 1,
              saved.audio.first?.isRussian == true,
              saved.audio.dropFirst().enumerated().allSatisfy({ offset, stream in
                  let sourceIndex = request.originalAudio[offset]
                  return sourceIndex == request.germanAudio ? stream.isGerman
                    : stream.language == original.audio.first(where: { $0.index == sourceIndex })?.language
              }),
              saved.audio.enumerated().allSatisfy({ $0.element.disposition?["default"] == ($0.offset == defaultIndex ? 1 : 0) }),
              saved.textSubtitles.map(\.language) == subtitles.map({ $0 == "ru" ? "rus" : "deu" }),
              saved.textSubtitles.allSatisfy({ $0.disposition?["default"] == ($0.isRussian ? 1 : 0) }),
              let sourceDuration = original.duration, let savedDuration = saved.duration,
              abs(savedDuration - sourceDuration) < 0.2 else { throw MediaFailure.invalidOutput }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
