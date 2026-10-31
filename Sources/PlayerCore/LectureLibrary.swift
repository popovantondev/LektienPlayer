import Foundation

public struct LibraryLecture: Identifiable, Equatable, Sendable {
    public let videoURL: URL
    public let germanSubtitleURL: URL?
    public let russianSubtitleURL: URL?

    public var id: String { videoURL.path }
    public var title: String { videoURL.deletingPathExtension().lastPathComponent }

    public init(videoURL: URL, germanSubtitleURL: URL?, russianSubtitleURL: URL?) {
        self.videoURL = videoURL
        self.germanSubtitleURL = germanSubtitleURL
        self.russianSubtitleURL = russianSubtitleURL
    }
}

public enum LectureLibraryError: LocalizedError, Equatable {
    case notDirectory
    case unreadableFolder(String)

    public var errorDescription: String? {
        switch self {
        case .notDirectory:
            return AppLocalization.coreText("library.notDirectory")
        case .unreadableFolder(let detail):
            return String(format: AppLocalization.coreText("library.unreadable"), detail)
        }
    }
}

public enum LectureLibrary {
    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mkv", "mov"]

    public static func scan(directory: URL, recursively: Bool = true) throws -> [LibraryLecture] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LectureLibraryError.notDirectory
        }

        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        let urls: [URL]
        if recursively {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: options) else {
                throw LectureLibraryError.unreadableFolder(AppLocalization.coreText("library.noContents"))
            }
            urls = enumerator.compactMap { $0 as? URL }
        } else {
            do {
                urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: options)
            } catch {
                throw LectureLibraryError.unreadableFolder(error.localizedDescription)
            }
        }

        return urls.compactMap { url in
            guard videoExtensions.contains(url.pathExtension.lowercased()), isRegularFile(url) else { return nil }
            return adjacentSubtitles(for: url)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public static func adjacentSubtitles(for video: URL) -> LibraryLecture {
        let attachments = LectureAttachmentLocator.discover(for: video)
        let folder = video.deletingLastPathComponent()
        return LibraryLecture(videoURL: video,
            germanSubtitleURL: attachments.resolved(in: folder, language: .german),
            russianSubtitleURL: attachments.resolved(in: folder, language: .russian))
    }

    /// Refreshes cheap filesystem metadata once when the library is opened. It
    /// never reads video contents or recursively measures caches.
    @discardableResult
    public static func refreshManifest(directory: URL, store: LibraryManifestStore) throws -> LibraryManifest {
        let found = try scan(directory: directory)
        return try store.update { manifest in
            for lecture in found {
                let source = LectureSource.local(path: lecture.videoURL.standardizedFileURL.path)
                let id = LibraryManifestStore.lectureID(for: source)
                var record = manifest.lectures[id] ?? LibraryLectureRecord(id: id, source: source)
                record.source = source
                let discovered = LectureAttachmentLocator.discover(for: lecture.videoURL)
                // Keep an explicit user selection while its file exists; otherwise
                // restore a safe same-folder match.
                if record.attachments.russianAudio == nil || record.attachments.resolved(in: lecture.videoURL.deletingLastPathComponent(), audio: true) == nil {
                    record.attachments.russianAudio = discovered.russianAudio
                }
                if record.attachments.germanSubtitles == nil || record.attachments.resolved(in: lecture.videoURL.deletingLastPathComponent(), language: .german) == nil {
                    record.attachments.germanSubtitles = discovered.germanSubtitles
                }
                if record.attachments.russianSubtitles == nil || record.attachments.resolved(in: lecture.videoURL.deletingLastPathComponent(), language: .russian) == nil {
                    record.attachments.russianSubtitles = discovered.russianSubtitles
                }
                let folder = lecture.videoURL.deletingLastPathComponent()
                let german = record.attachments.resolved(in: folder, language: .german)
                let russian = record.attachments.resolved(in: folder, language: .russian)
                record.status.hasGermanSubtitles = german != nil
                record.status.translated = russian != nil
                record.status.reviewed = russian?.lastPathComponent.lowercased().contains(".reviewed.") == true
                record.status.voiced = record.attachments.resolved(in: folder, audio: true) != nil
                record.status.languages = [record.status.hasGermanSubtitles ? "de" : nil,
                                           record.status.translated ? "ru" : nil,
                                           record.status.voiced ? "ru-audio" : nil].compactMap { $0 }
                if record.status.fullyReady { record.status.state = .complete }
                record.status.updatedAt = Date()
                manifest.lectures[id] = record
            }
        }
    }

    public static func adjacent(to id: String, in ordered: [LibraryLectureRecord], direction: Int) -> LibraryLectureRecord? {
        guard direction != 0, let index = ordered.firstIndex(where: { $0.id == id }) else { return nil }
        let next = index + (direction < 0 ? -1 : 1)
        return ordered.indices.contains(next) ? ordered[next] : nil
    }

    private static func firstRegularFile(_ urls: [URL]) -> URL? {
        urls.first(where: isRegularFile)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
