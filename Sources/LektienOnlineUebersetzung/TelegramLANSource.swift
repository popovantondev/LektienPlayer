import Foundation
import PlayerCore
import PlayerLAN
import PlayerMedia

/// The browser sees opaque IDs from the channel explicitly selected on the Mac.
/// Only one video is active; changing it stops outstanding range reads.
@MainActor
final class TelegramLANSource {
    struct Entry: Encodable {
        let id: String
        let name: String
        let audio: Bool
        let subtitles: [String]
        let source: String
        let status: LecturePreparationStatus?
        let cacheBytes: Int64?
        init(id: String, name: String, audio: Bool, subtitles: [String], source: String,
             status: LecturePreparationStatus? = nil, cacheBytes: Int64? = nil) {
            self.id = id; self.name = name; self.audio = audio; self.subtitles = subtitles
            self.source = source; self.status = status; self.cacheBytes = cacheBytes
        }
    }
    private let controller: TelegramController
    private var selected: TelegramStreamSelection?
    private var selectedChatID: Int64?
    private var selectedID: String?
    private var subtitleStores: [String: TelegramRangeStore] = [:]
    private var subtitleFiles: [String: URL] = [:]
    private var generation = UUID()

    init(controller: TelegramController = .shared) { self.controller = controller }

    static func identifier(_ item: TelegramMedia) -> String {
        MediaPublication.hash(Data("telegram:\(item.id):\(item.fileID):\(item.size):\(item.name)".utf8))
    }
    private func allowed(_ id: String) -> TelegramMedia? {
        guard let chat = controller.lanChatID else { return nil }
        if selectedChatID != chat { stop(); selectedChatID = chat }
        return controller.lanMedia.first { Self.identifier($0) == id && ["mp4", "m4v", "mkv"].contains($0.type) && $0.size > 0 }
    }
    func catalog() -> [Entry] {
        guard let chat = controller.lanChatID else { stop(); return [] }
        if selectedChatID != chat { stop(); selectedChatID = chat }
        let manifest = LibraryQueueController.shared.store.snapshot()
        return controller.lanMedia.filter { ["mp4", "m4v", "mkv"].contains($0.type) && $0.size > 0 }.map { item in
            let languages = ["ru", "de"].filter { subtitleItem(for: item, language: $0) != nil }
            let key = LibraryManifestStore.lectureID(for: .telegram(chatID: chat, messageID: item.id,
                fileID: item.fileID, name: item.name, size: item.size))
            let record = manifest.lectures[key]
            return .init(id: Self.identifier(item), name: item.name, audio: false, subtitles: languages,
                         source: "telegram", status: record?.status, cacheBytes: record?.cacheBytes)
        }
    }
    func activate(_ id: String) throws -> Bool {
        guard let item = allowed(id) else { return false }
        if selectedID == id { return true }
        stop()
        selectedChatID = controller.lanChatID
        let newSelection = try controller.makeStreamSelection(item)
        selected = newSelection; selectedID = id
        return true
    }
    func selection(for id: String) -> TelegramStreamSelection? {
        guard allowed(id) != nil, selectedID == id else { return nil }
        return selected
    }
    func video(_ id: String) throws -> LANResponse {
        guard let selection = selection(for: id), selection.item.size > 0 else { return .init(status: 404) }
        let store = selection.rangeStore
        let type = selection.item.type == "mkv" ? "video/x-matroska" : "video/mp4"
        return .init(media: .init(size: UInt64(selection.item.size), contentType: type) { offset, length in
            guard offset <= Int64.max else { throw TelegramClientError.invalidResponse }
            return try await store.read(offset: Int64(offset), length: length, priority: .playback)
        })
    }
    func subtitleURL(_ id: String, language: String) async throws -> URL? {
        guard ["ru", "de"].contains(language), let video = allowed(id),
              let subtitle = subtitleItem(for: video, language: language),
              let selection = selection(for: id) else { return nil }
        let key = "\(id)-\(language)"
        if let file = subtitleFiles[key] { return file }
        guard (1...5_000_000).contains(subtitle.size) else { throw TelegramClientError.invalidResponse }
        let url = selection.cacheVideoURL.deletingPathExtension().appendingPathExtension("\(language).srt")
        if let data = try? Data(contentsOf: url), let document = try? SRTParser.parse(data: data), !document.cues.isEmpty {
            subtitleFiles[key] = url
            return url
        }
        let token = generation
        let store: TelegramRangeStore
        if let existing = subtitleStores[key] { store = existing }
        else {
            let directory = selection.cacheVideoURL.deletingLastPathComponent()
                .appendingPathComponent("telegram-subtitle-ranges/\(Self.identifier(subtitle))")
            store = try TelegramRangeStore(item: subtitle, directory: directory,
                fetch: { [controller] request, offset, length, completion in
                    controller.requestStreamRange(id: request, fileID: subtitle.fileID, offset: offset, length: length, completion: completion)
                }, cancel: { [controller] request in controller.cancelStreamRange(request) })
            subtitleStores[key] = store
        }
        let bytes = try await store.read(offset: 0, length: Int(subtitle.size), priority: .playback)
        guard token == generation, selectedID == id else { throw CancellationError() }
        let document = try SRTParser.parse(data: bytes)
        guard !document.cues.isEmpty else { throw TelegramClientError.invalidResponse }
        if !FileManager.default.fileExists(atPath: url.path) { try MediaPublication.writeNew(bytes, to: url) }
        subtitleFiles[key] = url
        return url
    }
    func subtitle(_ id: String, language: String) async -> LANResponse {
        do {
            guard let url = try await subtitleURL(id, language: language) else { return .init(status: 404) }
            return .init(data: try SharedLibrary.vtt(SRTParser.parse(data: Data(contentsOf: url))))
        } catch { return .init(status: 422) }
    }
    private func subtitleItem(for video: TelegramMedia, language: String) -> TelegramMedia? {
        let stem = Self.base(video.name)
        return controller.lanMedia.first {
            $0.type == "srt" && Self.base($0.name) == stem &&
            Self.language($0.name) == language
        }
    }
    private static func base(_ name: String) -> String { TelegramController.mediaStem(name) }
    private static func language(_ name: String) -> String {
        let stem = URL(fileURLWithPath: name).deletingPathExtension()
        return stem.pathExtension.lowercased() == "ru" ? "ru" : "de"
    }
    func stop() {
        generation = UUID()
        selected?.stop(); selected = nil; selectedID = nil
        subtitleStores.values.forEach { $0.stop() }; subtitleStores = [:]; subtitleFiles = [:]
        selectedChatID = nil
    }
}
