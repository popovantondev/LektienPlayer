import CryptoKit
import Foundation

public enum LectureSource: Codable, Equatable, Sendable {
    case local(path: String)
    case telegram(chatID: Int64, messageID: Int64, fileID: Int32, name: String, size: Int64)

    public var displayName: String {
        switch self {
        case .local(let path): URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        case .telegram(_, _, _, let name, _): URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        }
    }
}

public enum LecturePreparationState: String, Codable, CaseIterable, Sendable {
    case idle, preparing, stopped, failed, complete
}

public struct LectureProgress: Codable, Equatable, Sendable {
    public var completed: Int
    public var total: Int
    public init(completed: Int = 0, total: Int = 0) {
        self.completed = max(0, completed); self.total = max(0, total)
    }
    public var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
}

public struct LecturePreparationStatus: Codable, Equatable, Sendable {
    public var hasGermanSubtitles = false
    public var recognized = false
    public var translated = false
    public var reviewed = false
    public var voiced = false
    public var state: LecturePreparationState = .idle
    public var progress = LectureProgress()
    public var languages: [String] = []
    public var error: String?
    public var updatedAt = Date()

    public init() {}
    public var fullyReady: Bool { reviewed && voiced && state != .failed && state != .stopped }
}

public struct LibraryLectureRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var source: LectureSource
    public var status: LecturePreparationStatus
    public var cacheBytes: Int64
    public var cacheCategories: [String: Int64]
    public var lastOpenedAt: Date?
    /// Names are relative to the video's folder.  The catalog deliberately
    /// never stores a machine path for attachments.
    public var attachments: LectureAttachments

    public init(id: String, source: LectureSource, status: LecturePreparationStatus = .init(),
                cacheBytes: Int64 = 0, cacheCategories: [String: Int64] = [:], lastOpenedAt: Date? = nil,
                attachments: LectureAttachments = .init()) {
        self.id = id; self.source = source; self.status = status
        self.cacheBytes = max(0, cacheBytes); self.cacheCategories = cacheCategories; self.lastOpenedAt = lastOpenedAt
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey { case id, source, status, cacheBytes, cacheCategories, lastOpenedAt, attachments }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        source = try values.decode(LectureSource.self, forKey: .source)
        status = try values.decode(LecturePreparationStatus.self, forKey: .status)
        cacheBytes = try values.decodeIfPresent(Int64.self, forKey: .cacheBytes) ?? 0
        cacheCategories = try values.decodeIfPresent([String: Int64].self, forKey: .cacheCategories) ?? [:]
        lastOpenedAt = try values.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        attachments = try values.decodeIfPresent(LectureAttachments.self, forKey: .attachments) ?? .init()
    }
}

/// A portable selection of files beside an original video or an exported
/// `video.mp4`.  Values are bare file names, not user paths or bookmarks.
public struct LectureAttachments: Codable, Equatable, Sendable {
    public var russianAudio: String?
    public var germanSubtitles: String?
    public var russianSubtitles: String?
    public init(russianAudio: String? = nil, germanSubtitles: String? = nil, russianSubtitles: String? = nil) {
        self.russianAudio = Self.safeName(russianAudio)
        self.germanSubtitles = Self.safeName(germanSubtitles)
        self.russianSubtitles = Self.safeName(russianSubtitles)
    }
    private enum CodingKeys: String, CodingKey { case russianAudio, germanSubtitles, russianSubtitles }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(russianAudio: try values.decodeIfPresent(String.self, forKey: .russianAudio),
                  germanSubtitles: try values.decodeIfPresent(String.self, forKey: .germanSubtitles),
                  russianSubtitles: try values.decodeIfPresent(String.self, forKey: .russianSubtitles))
    }

    public static func safeName(_ value: String?) -> String? {
        guard let value, !value.isEmpty, URL(fileURLWithPath: value).lastPathComponent == value,
              !value.contains("/") && !value.contains("\\") else { return nil }
        return value
    }

    public func resolved(in folder: URL, audio: Bool = false, language: SubtitleLanguage? = nil) -> URL? {
        let name: String?
        if audio { name = russianAudio }
        else { name = language == .german ? germanSubtitles : russianSubtitles }
        guard let safe = Self.safeName(name) else { return nil }
        let url = folder.appendingPathComponent(safe)
        let ext = url.pathExtension.lowercased()
        guard (audio ? ["m4a", "wav"].contains(ext) : ext == "srt"),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }
}

public enum QueueItemState: String, Codable, Sendable { case waiting, running, stopped, failed }

public struct PreparationQueueItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let lectureID: String
    public var state: QueueItemState
    public var error: String?
    public init(id: UUID = UUID(), lectureID: String, state: QueueItemState = .waiting, error: String? = nil) {
        self.id = id; self.lectureID = lectureID; self.state = state; self.error = error
    }
}

public struct DerivedCacheSettings: Codable, Equatable, Sendable {
    /// Nil keeps local data in the hidden `.lektien` folder beside its video.
    /// A value is always relative to the library folder, never a machine path.
    public var selectedRoot: String?
    public init(selectedRoot: String? = nil) { self.selectedRoot = selectedRoot }
}

/// Resolves only disposable local-video data. Telegram keeps its cache in
/// Application Support and durable per-video material remains beside the video.
public enum DerivedCacheLocation {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var libraryRoot: URL?
        var relativeRoot: String?
    }
    private static let state = State()

    public static func configure(libraryRoot: URL?, relativeRoot: String?) {
        state.lock.withLock {
            state.libraryRoot = libraryRoot?.standardizedFileURL
            state.relativeRoot = Self.validRelativePath(relativeRoot) ? relativeRoot : nil
        }
    }

    public static func root(for video: URL) -> URL {
        state.lock.withLock {
            guard let libraryRoot = state.libraryRoot, let relativeRoot = state.relativeRoot,
                  video.standardizedFileURL.path.hasPrefix(libraryRoot.path + "/") || video.standardizedFileURL == libraryRoot else {
                return video.deletingLastPathComponent().appendingPathComponent(".lektien", isDirectory: true)
            }
            return libraryRoot.appendingPathComponent(relativeRoot, isDirectory: true)
        }
    }

    public static func directory(for video: URL, category: String) -> URL {
        root(for: video).appendingPathComponent(category, isDirectory: true)
    }

    public static func relativePath(from libraryRoot: URL, to cacheRoot: URL) -> String? {
        let base = libraryRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let target = cacheRoot.standardizedFileURL.resolvingSymlinksInPath().path
        guard target == base || target.hasPrefix(base + "/") else { return nil }
        let result = String(target.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return validRelativePath(result) ? result : nil
    }

    public static func validRelativePath(_ path: String?) -> Bool {
        guard let path, !path.isEmpty, !NSString(string: path).isAbsolutePath else { return false }
        return !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
}

public struct LibraryManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var schemaVersion = currentVersion
    public var revision: UInt64 = 0
    public var lectures: [String: LibraryLectureRecord] = [:]
    public var queue: [PreparationQueueItem] = []
    public var queueRunning = false
    public var autoContinue = false
    public var cache = DerivedCacheSettings()
    public var updatedAt = Date()
    public init() {}
}

public enum LibraryManifestError: Error, Equatable { case unsupportedVersion, invalidState }

/// The manifest is the only mutable catalog and queue record. Writes replace the
/// complete file atomically. A last-known-good sidecar is used only for recovery.
public final class LibraryManifestStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var value: LibraryManifest

    public init(url: URL) throws {
        self.url = url
        value = try Self.readRecovering(url: url)
    }

    public func snapshot() -> LibraryManifest { lock.withLock { value } }

    @discardableResult
    public func update(_ body: (inout LibraryManifest) throws -> Void) throws -> LibraryManifest {
        try lock.withLock {
            var next = value
            try body(&next)
            try Self.validate(next)
            next.revision &+= 1; next.updatedAt = Date()
            try Self.write(next, to: url)
            value = next
            return next
        }
    }

    public static func lectureID(for source: LectureSource) -> String {
        let identity: String
        switch source {
        case .local(let path):
            identity = "local\n" + URL(fileURLWithPath: path).standardizedFileURL.path.precomposedStringWithCanonicalMapping
        case .telegram(let chat, let message, let file, let name, let size):
            identity = "telegram\n\(chat)\n\(message)\n\(file)\n\(name)\n\(size)"
        }
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(_ manifest: LibraryManifest) throws {
        guard manifest.schemaVersion == LibraryManifest.currentVersion,
              manifest.cache.selectedRoot == nil || DerivedCacheLocation.validRelativePath(manifest.cache.selectedRoot),
              Set(manifest.queue.map(\.lectureID)).isSubset(of: Set(manifest.lectures.keys)),
              Set(manifest.queue.map(\.lectureID)).count == manifest.queue.count,
              manifest.queue.filter({ $0.state == .running }).count <= 1 else { throw LibraryManifestError.invalidState }
    }

    private static func readRecovering(url: URL) throws -> LibraryManifest {
        let backup = url.appendingPathExtension("backup")
        for candidate in [url, backup] where FileManager.default.fileExists(atPath: candidate.path) {
            if let data = try? Data(contentsOf: candidate), let decoded = try? JSONDecoder().decode(LibraryManifest.self, from: data),
               decoded.schemaVersion == LibraryManifest.currentVersion, (try? validate(decoded)) != nil {
                var recovered = decoded
                if candidate == backup {
                    recovered.queueRunning = false
                    recovered.queue = recovered.queue.map { var item = $0; if item.state == .running { item.state = .waiting }; return item }
                    try write(recovered, to: url)
                }
                return recovered
            }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            let damaged = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: damaged)
        }
        let empty = LibraryManifest()
        try write(empty, to: url)
        return empty
    }

    private static func write(_ manifest: LibraryManifest, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let backup = url.appendingPathExtension("backup")
        if let old = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(LibraryManifest.self, from: old),
           decoded.schemaVersion == LibraryManifest.currentVersion {
            try old.write(to: backup, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
}

public struct CacheUsage: Equatable, Sendable {
    public let totalBytes: Int64
    public let categories: [String: Int64]
    public init(totalBytes: Int64, categories: [String: Int64]) {
        self.totalBytes = totalBytes; self.categories = categories
    }
}

public enum DerivedCacheInspector {
    public static let recoverableCategories = Set(["browser-video", "network", "recognition", "speech", "telegram-ranges", "telegram-videos", "translation-parts", "translations"])

    /// Enumerates only the selected `.lektien` cache, never the video itself.
    public static func usage(at root: URL) -> CacheUsage {
        var categories: [String: Int64] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return .init(totalBytes: 0, categories: [:]) }
        for case let file as URL in entries {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let relative = file.path.dropFirst(root.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let category = relative.split(separator: "/").first.map(String.init) ?? "other"
            categories[category, default: 0] += Int64(values.fileSize ?? 0)
        }
        return .init(totalBytes: categories.values.reduce(0, +), categories: categories)
    }

    public static func safeCleanupPlan(at root: URL) -> [URL] {
        recoverableCategories.sorted().map { root.appendingPathComponent($0, isDirectory: true) }
            .filter {
                guard let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
    }

    /// Move allowlisted directories out of the live cache before changing the
    /// manifest. If that update fails, moves are reversed; a crash leaves a
    /// hidden recoverable staging directory that `recoverInterruptedCleanup`
    /// restores on the next inspection.
    @discardableResult
    public static func cleanup(at root: URL, store: LibraryManifestStore) throws -> CacheUsage {
        try recoverInterruptedCleanup(at: root)
        let plan = safeCleanupPlan(at: root)
        guard !plan.isEmpty else { return usage(at: root) }
        let staging = root.appendingPathComponent(".cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var moved: [URL] = []
        do {
            for item in plan {
                let destination = staging.appendingPathComponent(item.lastPathComponent, isDirectory: true)
                try FileManager.default.moveItem(at: item, to: destination)
                moved.append(item)
            }
            _ = try store.update { manifest in
                for id in manifest.lectures.keys {
                    guard case .local = manifest.lectures[id]?.source else { continue }
                    manifest.lectures[id]?.cacheBytes = 0
                    manifest.lectures[id]?.cacheCategories = [:]
                }
            }
        } catch {
            for item in moved.reversed() {
                let staged = staging.appendingPathComponent(item.lastPathComponent, isDirectory: true)
                if FileManager.default.fileExists(atPath: staged.path) { try? FileManager.default.moveItem(at: staged, to: item) }
            }
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        try? FileManager.default.removeItem(at: staging)
        return usage(at: root)
    }

    public static func recoverInterruptedCleanup(at root: URL) throws {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for staging in entries where staging.lastPathComponent.hasPrefix(".cleanup-") {
            for category in recoverableCategories {
                let source = staging.appendingPathComponent(category, isDirectory: true)
                let destination = root.appendingPathComponent(category, isDirectory: true)
                guard FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: destination.path) else { continue }
                try FileManager.default.moveItem(at: source, to: destination)
            }
            try? FileManager.default.removeItem(at: staging)
        }
    }
}

public actor PersistentPreparationQueue {
    public typealias Worker = @Sendable (LibraryLectureRecord) async throws -> Void
    private let store: LibraryManifestStore
    private let worker: Worker
    private var task: Task<Void, Never>?
    private var interactive = false

    public init(store: LibraryManifestStore, worker: @escaping Worker) {
        self.store = store; self.worker = worker
        _ = try? store.update { manifest in
            manifest.queueRunning = manifest.autoContinue && !manifest.queue.isEmpty
            manifest.queue = manifest.queue.map { var item = $0; if item.state == .running { item.state = .waiting }; return item }
        }
    }

    public func resumeAfterLaunch() {
        guard store.snapshot().queueRunning, task == nil else { return }
        task = Task { await run() }
    }

    public func add(_ lectureIDs: [String]) throws {
        try store.update { manifest in
            var existing = Set(manifest.queue.map(\.lectureID))
            for id in lectureIDs where manifest.lectures[id] != nil && !existing.contains(id) {
                manifest.queue.append(.init(lectureID: id))
                existing.insert(id)
            }
        }
    }
    public func remove(_ itemID: UUID) throws {
        try store.update { manifest in manifest.queue.removeAll { $0.id == itemID && $0.state != .running } }
    }
    public func move(from offsets: IndexSet, to destination: Int) throws {
        try store.update { manifest in
            let moving = offsets.sorted().map { manifest.queue[$0] }
            for index in offsets.sorted(by: >) { manifest.queue.remove(at: index) }
            let removedBefore = offsets.filter { $0 < destination }.count
            manifest.queue.insert(contentsOf: moving, at: min(manifest.queue.count, destination - removedBefore))
        }
    }
    public func setAutoContinue(_ enabled: Bool) throws { try store.update { $0.autoContinue = enabled } }
    public func setInteractive(_ active: Bool) { interactive = active }
    public func start() throws {
        try store.update { $0.queueRunning = true }
        if task == nil { task = Task { await run() } }
    }
    public func stop() throws {
        task?.cancel()
        try store.update { manifest in
            manifest.queueRunning = false
            for index in manifest.queue.indices where manifest.queue[index].state == .running { manifest.queue[index].state = .stopped }
        }
    }

    private func run() async {
        defer {
            task = nil
            if store.snapshot().queueRunning { task = Task { await run() } }
        }
        while !Task.isCancelled {
            if interactive { try? await Task.sleep(for: .milliseconds(100)); continue }
            let snapshot = store.snapshot()
            guard snapshot.queueRunning, let item = snapshot.queue.first,
                  let lecture = snapshot.lectures[item.lectureID] else { break }
            do {
                let claimed = try store.update { manifest in
                    guard let index = manifest.queue.firstIndex(where: { $0.id == item.id }) else { return }
                    manifest.queue[index].state = .running; manifest.queue[index].error = nil
                }
                guard claimed.queue.first(where: { $0.id == item.id })?.state == .running else { continue }
                try await worker(lecture)
                try store.update { manifest in
                    manifest.queue.removeAll { $0.id == item.id }
                    if manifest.queue.isEmpty { manifest.queueRunning = false }
                }
            } catch is CancellationError { break }
            catch {
                _ = try? store.update { manifest in
                    guard let index = manifest.queue.firstIndex(where: { $0.id == item.id }) else { return }
                    manifest.queue[index].state = .failed; manifest.queue[index].error = error.localizedDescription
                    manifest.queueRunning = false
                }
                break
            }
        }
    }
}
