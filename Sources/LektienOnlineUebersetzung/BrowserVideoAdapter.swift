import Foundation
import PlayerLAN
import PlayerMedia

/// A single bounded browser-video worker. Each cached part is independently
/// playable fMP4, so a seek can cancel FFmpeg and restart at the requested part.
@MainActor
final class BrowserVideoAdapter {
    struct Source: Sendable {
        let id: String
        let input: URL
        let directURL: String
        let container: String
        let cacheRoot: URL
        let identity: String
    }
    struct Descriptor: Codable, Sendable {
        let mode: String
        let url: String?
        let duration: Double
        let segmentDuration: Double?
        let mimeType: String?
        let error: String?
    }
    enum Method: String, Codable, Sendable { case remux, audioTranscode, transcode }
    struct Plan: Sendable {
        let duration: Double
        let videoIndex: Int
        let audioIndex: Int?
        let method: Method
        let mimeType: String
    }
    struct Output: Sendable { let initialization: URL; let segment: URL }
    typealias Inspect = @Sendable (URL, MediaCancellation) throws -> MediaInspection
    typealias Encode = @Sendable (URL, Plan, Double, Double, URL, MediaCancellation) throws -> Output

    static let partDuration = 12.0
    private let inspect: Inspect
    private let encode: Encode
    private let maximumCacheBytes: Int64
    private var active: (source: Source, plan: Plan, directory: URL)?
    private var generation = UUID()
    private var work: Task<URL, Error>?
    private var workIndex: Int?
    private var cancellation: MediaCancellation?
    private var failed: [Int: String] = [:]
    private var position = 0.0

    init(maximumCacheBytes: Int64 = 2 * 1024 * 1024 * 1024,
         inspect: @escaping Inspect = { try MediaInspection.read($0, cancellation: $1) },
         encode: @escaping Encode = BrowserVideoAdapter.encodePart) {
        self.maximumCacheBytes = maximumCacheBytes
        self.inspect = inspect
        self.encode = encode
    }

    func open(_ source: Source) async -> Descriptor {
        reset()
        let control = MediaCancellation()
        cancellation = control
        do {
            let inspection = try await Task.detached(priority: .userInitiated) { try self.inspect(source.input, control) }.value
            try control.check()
            guard let duration = inspection.duration, duration.isFinite, duration > 0,
                  let video = inspection.streams.first(where: { $0.codec_type == "video" }) else {
                throw MediaFailure.invalidOutput
            }
            let audio = inspection.audio.first
            let inspectedContainer = inspection.format?.format_name?.lowercased() ?? source.container.lowercased()
            let compatibleVideo = video.codec_name == "h264" && (video.pix_fmt == nil || ["yuv420p", "yuvj420p"].contains(video.pix_fmt!))
            let compatibleAudio = audio == nil || audio?.codec_name == "aac"
            if inspectedContainer.contains("mp4"), compatibleVideo, compatibleAudio {
                cancellation = nil
                return .init(mode: "direct", url: source.directURL, duration: duration,
                             segmentDuration: nil, mimeType: nil, error: nil)
            }
            let method: Method = compatibleVideo ? (compatibleAudio ? .remux : .audioTranscode) : .transcode
            let profile = video.profile?.lowercased() ?? ""
            let prefix = profile.contains("high") ? "6400" : profile.contains("main") ? "4d40" : "42e0"
            let level = max(10, min(video.level ?? 31, 62))
            let videoCodec = method == .transcode ? "avc1.640028" : String(format: "avc1.%@%02x", prefix, level)
            let mime = audio == nil ? "video/mp4; codecs=\"\(videoCodec)\"" : "video/mp4; codecs=\"\(videoCodec),mp4a.40.2\""
            let plan = Plan(duration: duration, videoIndex: video.index, audioIndex: audio?.index,
                            method: method, mimeType: mime)
            let directory = source.cacheRoot.appendingPathComponent(source.identity, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            removePartialFiles(in: source.cacheRoot)
            active = (source, plan, directory)
            cancellation = nil
            trimCache(at: source.cacheRoot, preserving: [])
            return .init(mode: "adapted", url: "/adapted/\(source.id)/index.m3u8", duration: duration,
                         segmentDuration: Self.partDuration, mimeType: mime, error: nil)
        } catch {
            cancellation = nil
            let reason = (error as? MediaFailure) == .unavailable ? "videoToolsMissing" : "videoInvalid"
            return .init(mode: "failed", url: nil, duration: 0, segmentDuration: nil, mimeType: nil, error: reason)
        }
    }

    func update(id: String, position newPosition: Double) {
        guard let active, active.source.id == id else { return }
        position = min(max(0, newPosition), active.plan.duration)
        let wanted = index(for: position, duration: active.plan.duration)
        if let workIndex, workIndex != wanted {
            cancellation?.cancel(); work?.cancel(); work = nil; self.workIndex = nil
        }
        prefetch(from: wanted)
    }

    func response(for path: String) async -> LANResponse {
        guard let active else { return .init(status: 404) }
        let prefix = "/adapted/\(active.source.id)/"
        guard path.hasPrefix(prefix) else { return .init(status: 404) }
        let tail = String(path.dropFirst(prefix.count))
        if tail == "index.m3u8" {
            return .init(data: playlist(active.plan, id: active.source.id), contentType: "application/vnd.apple.mpegurl")
        }
        let components = tail.split(separator: ".")
        guard components.count == 3, let index = Int(components[0]), index >= 0,
              components[1] == "init" || components[1] == "media",
              (components[2] == "mp4" || components[2] == "m4s") else { return .init(status: 404) }
        do {
            let segment = try await prepare(index: index)
            let file = components[1] == "init" ? initializationURL(index, in: active.directory) : segment
            return .init(file: file, fileRoot: active.directory)
        } catch {
            if error is CancellationError || (error as? MediaFailure) == .stopped { return .init(status: 409) }
            let data = (try? JSONEncoder().encode(["error": failed[index] ?? "videoFFmpegFailed"])) ?? Data()
            return .init(status: 422, data: data, contentType: "application/json")
        }
    }

    func reset() {
        generation = UUID()
        cancellation?.cancel(); cancellation = nil
        work?.cancel(); work = nil; workIndex = nil
        active = nil; failed = [:]; position = 0
    }

    private func prepare(index: Int) async throws -> URL {
        guard let active, index >= 0, Double(index) * Self.partDuration < active.plan.duration else {
            throw MediaFailure.invalidOutput
        }
        let destination = segmentURL(index, in: active.directory)
        let initialization = initializationURL(index, in: active.directory)
        if Self.regular(destination), Self.regular(initialization) { return destination }
        if failed[index] != nil { throw MediaFailure.failed }
        if workIndex == index, let work { return try await work.value }
        if let work {
            do { _ = try await work.value }
            catch {
                if index != self.index(for: position, duration: active.plan.duration) { throw MediaFailure.stopped }
            }
            return try await prepare(index: index)
        }
        let token = generation
        let control = MediaCancellation()
        cancellation = control; workIndex = index
        let start = Double(index) * Self.partDuration
        let length = min(Self.partDuration, active.plan.duration - start)
        let encoder = encode
        let task = Task.detached(priority: .userInitiated) {
            try control.check()
            let values = try? active.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let available = values?.volumeAvailableCapacityForImportantUsage, available > 0, available < 128 * 1024 * 1024 {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            let temporary = active.directory.appendingPathComponent("partial-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let output = try encoder(active.source.input, active.plan, start, length, temporary, control)
            try control.check()
            try Self.publish(output.initialization, to: initialization)
            try Self.publish(output.segment, to: destination)
            return destination
        }
        work = task
        do {
            let url = try await task.value
            guard generation == token else { throw MediaFailure.stopped }
            work = nil; workIndex = nil; cancellation = nil
            trimCache(at: active.source.cacheRoot, preserving: [url.path, initialization.path])
            return url
        } catch {
            if generation == token, !(error is CancellationError), (error as? MediaFailure) != .stopped {
                if (error as? MediaFailure) == .unavailable { failed[index] = "videoToolsMissing" }
                else if let cocoa = error as? CocoaError, cocoa.code == .fileWriteOutOfSpace { failed[index] = "videoNoSpace" }
                else { failed[index] = "videoFFmpegFailed" }
            }
            if workIndex == index { work = nil; workIndex = nil; cancellation = nil }
            throw error
        }
    }

    private func prefetch(from index: Int) {
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            for candidate in index..<(index + 5) {
                guard self.generation == token else { return }
                do { _ = try await self.prepare(index: candidate) }
                catch { return }
            }
        }
    }

    private func playlist(_ plan: Plan, id: String) -> Data {
        let count = Int(ceil(plan.duration / Self.partDuration))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-PLAYLIST-TYPE:VOD",
                     "#EXT-X-TARGETDURATION:\(Int(Self.partDuration))", "#EXT-X-MEDIA-SEQUENCE:0"]
        for index in 0..<count {
            let length = min(Self.partDuration, plan.duration - Double(index) * Self.partDuration)
            if index > 0 { lines.append("#EXT-X-DISCONTINUITY") }
            lines += ["#EXT-X-MAP:URI=\"\(index).init.mp4\"", String(format: "#EXTINF:%.3f,", length), "\(index).media.m4s"]
        }
        lines.append("#EXT-X-ENDLIST")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func index(for position: Double, duration: Double) -> Int {
        min(max(0, Int(position / Self.partDuration)), max(0, Int(ceil(duration / Self.partDuration)) - 1))
    }
    private func segmentURL(_ index: Int, in directory: URL) -> URL { directory.appendingPathComponent("\(index).media.m4s") }
    private func initializationURL(_ index: Int, in directory: URL) -> URL { directory.appendingPathComponent("\(index).init.mp4") }
    private nonisolated static func regular(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }

    private nonisolated static func encodePart(input: URL, plan: Plan, start: Double, duration: Double,
                                               directory: URL, cancellation: MediaCancellation) throws -> Output {
        let playlist = directory.appendingPathComponent("part.m3u8")
        let pattern = directory.appendingPathComponent("part-%03d.m4s")
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-ss", String(format: "%.3f", start),
                         "-i", input.isFileURL ? input.path : input.absoluteString, "-t", String(format: "%.3f", duration),
                         "-map", "0:\(plan.videoIndex)"]
        if let audio = plan.audioIndex { arguments += ["-map", "0:\(audio)"] }
        switch plan.method {
        case .remux: arguments += ["-c:v", "copy", "-c:a", "copy"]
        case .audioTranscode: arguments += ["-c:v", "copy", "-c:a", "aac", "-b:a", "192k"]
        case .transcode:
            arguments += ["-c:v", "h264_videotoolbox", "-q:v", "65", "-allow_sw", "1", "-pix_fmt", "yuv420p"]
            if plan.audioIndex != nil { arguments += ["-c:a", "aac", "-b:a", "192k"] }
        }
        arguments += ["-sn", "-dn", "-avoid_negative_ts", "make_zero", "-f", "hls", "-hls_segment_type", "fmp4",
                      "-hls_time", "86400", "-hls_list_size", "0", "-hls_fmp4_init_filename", "init.mp4",
                      "-hls_segment_filename", pattern.path, playlist.path]
        _ = try LocalMediaProcess.run(MediaRuntime.executable("ffmpeg"), arguments, directory: directory, cancellation: cancellation)
        let segments = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "m4s" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard segments.count == 1, let segment = segments.first, regular(directory.appendingPathComponent("init.mp4")) else { throw MediaFailure.invalidOutput }
        return .init(initialization: directory.appendingPathComponent("init.mp4"), segment: segment)
    }

    private nonisolated static func publish(_ source: URL, to destination: URL) throws {
        if regular(destination) { return }
        do { try FileManager.default.moveItem(at: source, to: destination) }
        catch CocoaError.fileWriteFileExists { return }
    }
    private func removePartialFiles(in directory: URL) {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        var stale: [URL] = []
        for case let file as URL in enumerator where file.lastPathComponent.hasPrefix("partial-") {
            stale.append(file); enumerator.skipDescendants()
        }
        for file in stale { try? FileManager.default.removeItem(at: file) }
    }
    private func trimCache(at root: URL, preserving: Set<String>) {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey], options: [.skipsHiddenFiles]) else { return }
        var files: [(URL, Int64, Date)] = []
        var total: Int64 = 0
        for case let url as URL in enumerator where ["m4s", "mp4"].contains(url.pathExtension) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey]), let size = values.fileSize else { continue }
            let bytes = Int64(size); total += bytes
            if !preserving.contains(url.path) { files.append((url, bytes, values.contentAccessDate ?? .distantPast)) }
        }
        for file in files.sorted(by: { $0.2 < $1.2 }) where total > maximumCacheBytes {
            if (try? FileManager.default.removeItem(at: file.0)) != nil { total -= file.1 }
        }
    }
}
