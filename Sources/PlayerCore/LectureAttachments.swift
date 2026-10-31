import Foundation

public enum LectureAttachmentLocator {
    public static func discover(for video: URL) -> LectureAttachments {
        let folder = video.deletingLastPathComponent()
        var base = video.deletingPathExtension()
        if ["ru", "de"].contains(base.pathExtension.lowercased()) { base.deletePathExtension() }
        let exported = video.lastPathComponent.lowercased() == "video.mp4"
        func first(_ urls: [URL], extensions: Set<String>) -> String? {
            urls.first { url in
                extensions.contains(url.pathExtension.lowercased()) &&
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }?.lastPathComponent
        }
        return .init(
            russianAudio: first([base.appendingPathExtension("ru.m4a"), base.appendingPathExtension("ru.wav"),
                                exported ? folder.appendingPathComponent("voice.ru.m4a") : folder.appendingPathComponent(".missing")], extensions: ["m4a", "wav"]),
            germanSubtitles: first([base.appendingPathExtension("de.srt"), base.appendingPathExtension("srt"),
                                   exported ? folder.appendingPathComponent("voice.de.srt") : folder.appendingPathComponent(".missing")], extensions: ["srt"]),
            russianSubtitles: first([base.appendingPathExtension("ru.reviewed.srt"), base.appendingPathExtension("ru.srt"),
                                    exported ? folder.appendingPathComponent("voice.ru.srt") : folder.appendingPathComponent(".missing")], extensions: ["srt"])
        )
    }

    public static func reference(for url: URL, beside video: URL, audio: Bool = false) -> String? {
        guard url.deletingLastPathComponent().standardizedFileURL == video.deletingLastPathComponent().standardizedFileURL,
              (audio ? ["m4a", "wav"].contains(url.pathExtension.lowercased()) : url.pathExtension.lowercased() == "srt") else { return nil }
        return LectureAttachments.safeName(url.lastPathComponent)
    }
}
