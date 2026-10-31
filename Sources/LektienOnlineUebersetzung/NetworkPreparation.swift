import Foundation
import Combine
import CryptoKit
import PlayerCore
import PlayerLAN
import PlayerMedia
import PlayerSpeech
import PlayerTranslation

/// One remote viewer uses the existing cache-backed workers. No second model
/// implementation or browser credentials are introduced.
@MainActor
final class NetworkPreparation {
    private let library: SharedLibrary
    private let telegram: TelegramLANSource?
    private let inspectMedia: @Sendable (URL, MediaCancellation) throws -> MediaInspection
    private let recognition = RecognitionController()
    private let translation = StreamingTranslationController()
    private let speech = SpeechController()
    private let videoAdapter: BrowserVideoAdapter
    private var task: Task<Void, Never>?
    private var cancellation: MediaCancellation?
    private var generation = UUID()
    private var id: String?
    private var source: Int?
    private var position = 0.0
    private var duration = 0.0
    private var state = "idle"
    private var german: SubtitleDocument?
    private var russian: SubtitleDocument?
    private var files: [String: URL] = [:]
    private var history = LectureHistory()
    private var inspections: [String: MediaInspection] = [:]
    var failure: (String) -> Void = { _ in }
    var macBusy: () -> Bool = { false }
    var viewerActivity: () -> Void = {}

    init(library: SharedLibrary, telegram: TelegramLANSource? = nil,
         inspectMedia: @escaping @Sendable (URL, MediaCancellation) throws -> MediaInspection = { try MediaInspection.read($0, cancellation: $1) },
         videoAdapter: BrowserVideoAdapter? = nil) {
        self.library = library; self.telegram = telegram; self.inspectMedia = inspectMedia
        self.videoAdapter = videoAdapter ?? BrowserVideoAdapter(inspect: inspectMedia)
    }

    struct Source: Encodable { let id: Int; let kind: String; let title: String }
    struct Sources: Encodable { let items: [Source]; let selected: Int? }
    struct Clip: Codable { let start: Double; let end: Double; let url: String }
    struct Cue: Codable { let start: Double; let end: Double; let text: String }
    struct Snapshot: Codable {
        let state: String
        let duration: Double
        let speechEnd: Double
        let requests: Int
        let clips: [Clip]
        let recognized: [[Double]]
        let translated: [[Double]]
        let russian: [Cue]
        let german: [Cue]
    }

    private func inspect(_ id: String, mediaURL: URL) async throws -> MediaInspection {
        if let inspection = inspections[id] { return inspection }
        let control = MediaCancellation()
        cancellation = control
        let token = generation
        let read = inspectMedia
        let result = try await Task.detached(priority: .utility) { try read(mediaURL, control) }.value
        try control.check()
        guard generation == token else { throw MediaFailure.stopped }
        inspections[id] = result
        cancellation = nil
        return result
    }

    private func activeVideo(_ requested: String) -> (URL, TelegramStreamSelection?)? {
        if let selection = telegram?.selection(for: requested) { return (selection.cacheVideoURL, selection) }
        guard let video = library.file(for: "/media/\(requested)/video") else { return nil }
        return (video, nil)
    }

    private func browserSource(_ requested: String) async throws -> BrowserVideoAdapter.Source? {
        guard let (video, selection) = activeVideo(requested) else { return nil }
        if let selection {
            let input = try await selection.preparationURL()
            return .init(id: requested, input: input, directURL: "/telegram/\(requested)/video", container: selection.item.type,
                         cacheRoot: video.deletingLastPathComponent().appendingPathComponent("browser-video", isDirectory: true),
                         identity: selection.rangeStore.identity)
        }
        let values = try video.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fingerprint = MediaPublication.hash(Data("\(requested):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)".utf8))
        return .init(id: requested, input: video, directURL: "/media/\(requested)/video", container: video.pathExtension,
                     cacheRoot: DerivedCacheLocation.directory(for: video, category: "browser-video"),
                     identity: fingerprint)
    }

    func handle(_ path: String, body: Data?) async -> LANResponse {
        if path == "/api/library" {
            let manifest = LibraryQueueController.shared.store.snapshot()
            let entries = library.lectures.map { entry -> SharedLecture in
                guard let video = library.file(for: "/media/\(entry.id)/video") else { return entry }
                let key = LibraryManifestStore.lectureID(for: .local(path: video.standardizedFileURL.path))
                let record = manifest.lectures[key]
                return .init(id: entry.id, name: entry.name, audio: entry.audio, subtitles: entry.subtitles,
                             status: record?.status, cacheBytes: record?.cacheBytes)
            }
            return .json(entries)
        }
        if path == "/api/telegram" { return .json(telegram?.catalog() ?? []) }
        if path == "/api/telegram/select" {
            struct Choice: Decodable { let id: String? }
            guard let body, let choice = try? JSONDecoder().decode(Choice.self, from: body), let telegram else { return .init(status: 400) }
            guard let selectedID = choice.id else {
                if id != nil { stop(); id = nil; files = [:] }
                videoAdapter.reset()
                telegram.stop()
                return .init(status: 204)
            }
            guard selectedID.count == 64, selectedID.allSatisfy(\.isHexDigit) else { return .init(status: 400) }
            if telegram.selection(for: selectedID) == nil {
                stop(); id = nil; files = [:]; inspections = [:]; videoAdapter.reset()
            }
            do { return try telegram.activate(selectedID) ? .init(status: 204) : .init(status: 404) }
            catch { return .init(status: 422) }
        }
        if path == "/api/video/position" {
            guard let body, let command = try? JSONDecoder().decode(LANPreparationCommand.self, from: body), command.isValid else { return .init(status: 400) }
            videoAdapter.update(id: command.id, position: command.position)
            viewerActivity()
            return .init(status: 204)
        }
        if path.hasPrefix("/api/video/") {
            let requested = String(path.dropFirst("/api/video/".count))
            guard requested.count == 64, requested.allSatisfy(\.isHexDigit) else { return .init(status: 404) }
            do {
                guard let source = try await browserSource(requested) else { return .init(status: 404) }
                return .json(await videoAdapter.open(source))
            } catch { return .json(BrowserVideoAdapter.Descriptor(mode: "failed", url: nil, duration: 0, segmentDuration: nil, mimeType: nil, error: "videoInvalid")) }
        }
        if path.hasPrefix("/adapted/") { return await videoAdapter.response(for: path) }
        if path.hasPrefix("/telegram/") {
            let parts = path.split(separator: "/")
            guard parts.count == 3, parts[0] == "telegram" else { return .init(status: 404) }
            let requested = String(parts[1])
            guard requested.count == 64, requested.allSatisfy(\.isHexDigit) else { return .init(status: 404) }
            if parts[2] == "video" {
                do { return try telegram?.video(requested) ?? .init(status: 404) }
                catch { return .init(status: 404) }
            }
            if parts[2] == "de.vtt" || parts[2] == "ru.vtt" {
                return await telegram?.subtitle(requested, language: String(parts[2].prefix(2))) ?? .init(status: 404)
            }
            return .init(status: 404)
        }
        if path.hasPrefix("/prepared/") {
            guard let url = files[path] else { return .init(status: 404) }
            return .init(file: url, fileRoot: url.deletingLastPathComponent())
        }
        if path.hasPrefix("/api/sources/") {
            let requested = String(path.dropFirst("/api/sources/".count))
            guard let (video, selection) = activeVideo(requested) else { return .init(status: 404) }
            do {
                let mediaURL = try await selection?.preparationURL() ?? video
                let inspection = try await inspect(requested, mediaURL: mediaURL)
                var items: [Source] = []
                for (code, language) in [(-2, "ru"), (-1, "de")] {
                    if (try? await telegram?.subtitleURL(requested, language: language)) != nil ||
                        library.file(for: "/media/\(requested)/\(language).vtt") != nil {
                        items.append(.init(id: code, kind: language, title: language.uppercased() + " · SRT"))
                    }
                }
                items += inspection.textSubtitles.filter { $0.isGerman || $0.isRussian }.map {
                    .init(id: $0.index, kind: $0.isRussian ? "ru" : "de", title: "SRT · " + $0.title)
                }
                items += inspection.audio.map { .init(id: $0.index, kind: "audio", title: $0.title) }
                let saved: Int?
                if let selection { saved = LectureHistory.load(video: video, remoteIdentity: selection.rangeStore.identity).recognitionStream }
                else { saved = LectureHistory.load(video: video).recognitionStream }
                let preferred = saved.flatMap { value in items.first { $0.id == value }?.id }
                    ?? items.first(where: { $0.kind == "ru" })?.id
                    ?? items.first(where: { $0.kind == "de" })?.id
                    ?? inspection.audio.first(where: \.isGerman)?.index ?? items.first?.id
                return .json(Sources(items: items, selected: preferred))
            } catch { return .init(status: 422) }
        }
        if path.hasPrefix("/api/preparation/") {
            guard String(path.dropFirst("/api/preparation/".count)) == id else { return .json(["state": "idle"]) }
            return .json(snapshot())
        }
        guard let body, let command = try? JSONDecoder().decode(LANPreparationCommand.self, from: body), command.isValid else { return .init(status: 400) }
        guard let (video, selection) = activeVideo(command.id) else { return .init(status: 400) }
        if path == "/api/stop" {
            guard command.id == id else { return .init(status: 409) }
            stop(); return .init(status: 204)
        }
        if path == "/api/position" {
            guard command.id == id else { return .init(status: 409) }
            viewerActivity()
            update(command); return .init(status: 204)
        }
        guard path == "/api/prepare" else { return .init(status: 404) }
        guard !macBusy() else { return .init(status: 409) }
        guard let selected = command.source else { return .init(status: 400) }
        if id == command.id, source == selected, state == "preparing" || state == "ready" {
            update(command); return .init(status: 202)
        }
        let requestGeneration = generation
        let inspection: MediaInspection
        let mediaURL: URL
        do {
            mediaURL = try await selection?.preparationURL() ?? video
            inspection = try await inspect(command.id, mediaURL: mediaURL)
        }
        catch { return .init(status: requestGeneration == generation ? 422 : 409) }
        let remoteGerman = selected == -1 ? try? await telegram?.subtitleURL(command.id, language: "de") : nil
        let remoteRussian = selected == -2 ? try? await telegram?.subtitleURL(command.id, language: "ru") : nil
        let validSource = selected == -1 && (remoteGerman != nil || library.file(for: "/media/\(command.id)/de.vtt") != nil)
            || selected == -2 && (remoteRussian != nil || library.file(for: "/media/\(command.id)/ru.vtt") != nil)
            || inspection.streams.contains { $0.index == selected && ($0.codec_type == "audio" || $0.isTextSubtitle && ($0.isGerman || $0.isRussian)) }
        guard let length = inspection.duration, length.isFinite, length > 0, validSource else { return .init(status: 400) }
        guard requestGeneration == generation, !macBusy() else { return .init(status: 409) }
        if id == command.id, source == selected, state == "preparing" || state == "ready" {
            update(command); return .init(status: 202)
        }
        stop()
        id = command.id; source = selected; duration = length; german = nil; russian = nil; files = [:]
        recognition.reset(); translation.reset(); speech.reset()
        state = "preparing"
        if let selection { history = LectureHistory.load(video: video, remoteIdentity: selection.rangeStore.identity) }
        else { history = LectureHistory.load(video: video) }
        history.recognitionStream = selected >= 0 && inspection.audio.contains(where: { $0.index == selected }) ? selected : nil
        update(command)
        let token = generation
        let control = MediaCancellation(); cancellation = control
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if let stream = inspection.audio.first(where: { $0.index == selected }) {
                    recognition.start(video: video, streamIndex: stream.index, duration: length, position: position,
                        mediaURL: selection?.currentPreparationURL, mediaIdentity: selection?.rangeStore.identity)
                    translation.startRecognizing(plan: recognition.speechPlan, videoURL: video,
                        translation: settings(review: false), review: settings(review: true), position: position)
                    speech.startStreaming(plan: translation.plan, videoURL: video, voice: "kseniya", position: position)
                } else {
                    let external = selected < 0 ? (try await telegram?.subtitleURL(command.id, language: selected == -2 ? "ru" : "de")
                        ?? library.file(for: "/media/\(command.id)/\(selected == -2 ? "ru" : "de").vtt")) : nil
                    let stream = inspection.textSubtitles.first { $0.index == selected }
                    let document = try await Task.detached(priority: .utility) {
                        if let external { return try SRTParser.parse(data: Data(contentsOf: external)) }
                        guard let stream else { throw MediaFailure.invalidOutput }
                        return try MediaInspection.extractSubtitles(mediaURL, stream: stream, cancellation: control)
                    }.value
                    guard generation == token, !Task.isCancelled else { return }
                    guard !document.cues.isEmpty else { throw MediaFailure.invalidOutput }
                    let isRussian = selected == -2 || stream?.isRussian == true
                    if external == nil {
                        _ = try await Task.detached { try MediaPublication.subtitles(document, video: video, language: isRussian ? "ru" : "de") }.value
                    }
                    guard generation == token, !Task.isCancelled else { return }
                    if isRussian {
                        russian = document
                        speech.start(document: document, videoURL: video, voice: "kseniya", position: position)
                    } else {
                        german = document
                        translation.start(source: document, videoURL: video, translation: settings(review: false), review: settings(review: true), position: position)
                        speech.startStreaming(plan: translation.plan, videoURL: video, voice: "kseniya", position: position)
                    }
                }
                var savedCount = -1
                var savedPosition = -10.0
                while !Task.isCancelled && token == generation {
                    if macBusy() { stop(); state = "busy"; return }
                    translation.supplyRecognized(recognition.sourceChunks)
                    speech.supply(translation.ready)
                    if !recognition.ready.isEmpty { german = recognition.document }
                    if !translation.ready.isEmpty { russian = translation.document }
                    if let url = recognition.completedURL, let german {
                        history.recognitionSubtitle = url.lastPathComponent
                        history.recognitionSubtitleHash = MediaPublication.hash(Data(MediaPublication.srt(german).utf8))
                    }
                    if let error = recognition.errorMessage ?? translation.errorMessage ?? speech.errorMessage {
                        failure(error); stop(); state = "failed"; return
                    }
                    state = !speech.plan.isEmpty && speech.prepared.count == speech.plan.count ? "ready" : "preparing"
                    if savedCount != speech.prepared.count || abs(savedPosition - position) >= 5 {
                        registerFiles()
                        let manifest = snapshot(allCues: true)
                        let destination = DerivedCacheLocation.directory(for: video, category: "network").appendingPathComponent("\(command.id).json")
                        var saved = history; saved.position = position
                        let remoteIdentity = selection?.rangeStore.identity
                        try await Task.detached(priority: .utility) {
                            if let remoteIdentity { try saved.save(video: video, remoteIdentity: remoteIdentity) }
                            else { try saved.save(video: video) }
                            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try JSONEncoder().encode(manifest).write(to: destination, options: .atomic)
                        }.value
                        savedCount = speech.prepared.count; savedPosition = position
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                failure(error.localizedDescription); stop(); state = "failed"
            }
        }
        return .init(status: 202)
    }

    private func update(_ command: LANPreparationCommand) {
        position = min(command.position, duration)
        let ahead = command.playing ? 360.0 : 600.0
        speech.bufferAhead = ahead; translation.bufferAhead = ahead; recognition.bufferAhead = ahead + 90
        speech.updatePosition(position); translation.updatePosition(position); recognition.updatePosition(position)
    }
    private func settings(review: Bool) -> TranslationSettings {
        let prefix = review ? "review" : "translation"
        let name = UserDefaults.standard.string(forKey: "\(prefix).model") ?? (review ? "Terra" : "Luna")
        let effort = UserDefaults.standard.string(forKey: "\(prefix).effort") ?? "Среднее"
        return .init(model: name == "Luna" ? "gpt-5.6-luna" : name == "Terra" ? "gpt-5.6-terra" : "gpt-6-astra",
                     effort: effort == "Лёгкие" ? "low" : effort == "Высокие" ? "high" : "medium")
    }
    private func registerFiles() {
        guard let id else { return }
        for prepared in speech.prepared {
            let relative = prepared.audioURL.path.replacingOccurrences(of: library.root.path, with: "")
            let key = SHA256.hash(data: Data(relative.utf8)).map { String(format: "%02x", $0) }.joined()
            files["/prepared/\(id)/\(key).wav"] = prepared.audioURL
        }
    }
    private func snapshot(allCues: Bool = false) -> Snapshot {
        let byURL = Dictionary(files.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let clips = speech.prepared.compactMap { part -> Clip? in
            guard let path = byURL[part.audioURL] else { return nil }
            return .init(start: part.chunk.start, end: part.chunk.end, url: path)
        }.sorted { $0.start < $1.start }
        func cues(_ document: SubtitleDocument?) -> [Cue] {
            (document?.cues ?? []).filter { allCues || $0.end >= position - 30 && $0.start <= position + 90 }
                .map { .init(start: $0.start, end: $0.end, text: $0.text) }
        }
        return .init(state: state, duration: duration, speechEnd: speech.plan.last?.end ?? duration, requests: translation.requestCount, clips: clips,
                     recognized: recognition.ready.map { [$0.start, $0.end] },
                     translated: translation.ready.map { [$0.start, $0.end] }, russian: cues(russian), german: cues(german))
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; cancellation?.cancel(); cancellation = nil
        recognition.stop(); translation.stop(); speech.stop(); state = "stopped"
    }
}
