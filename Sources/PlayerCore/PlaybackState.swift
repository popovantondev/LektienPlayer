import Foundation

public enum SubtitleLanguage: String, CaseIterable, Sendable, Identifiable {
    case german
    case russian

    public var id: String { rawValue }
}

public struct LocalLecture: Equatable, Sendable {
    public var videoURL: URL
    public var germanSubtitles: SubtitleDocument?
    public var russianSubtitles: SubtitleDocument?
    public var germanSubtitleURL: URL?
    public var russianSubtitleURL: URL?

    public init(videoURL: URL, germanSubtitles: SubtitleDocument? = nil, russianSubtitles: SubtitleDocument? = nil) {
        self.videoURL = videoURL
        self.germanSubtitles = germanSubtitles
        self.russianSubtitles = russianSubtitles
    }

    public func subtitles(for language: SubtitleLanguage) -> SubtitleDocument? {
        switch language {
        case .german: germanSubtitles
        case .russian: russianSubtitles
        }
    }
}

public struct PlaybackSnapshot: Equatable, Sendable {
    public var position: TimeInterval
    public var duration: TimeInterval?
    public var isPlaying: Bool

    public init(position: TimeInterval = 0, duration: TimeInterval? = nil, isPlaying: Bool = false) {
        self.position = max(0, position)
        self.duration = duration
        self.isPlaying = isPlaying
    }
}
