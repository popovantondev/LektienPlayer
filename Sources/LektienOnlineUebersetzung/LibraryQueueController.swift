import Combine
import Foundation
import PlayerCore
import SwiftUI

final class LibraryPreparationRequest: @unchecked Sendable {
    let lecture: LibraryLectureRecord
    private let lock = NSLock()
    private var finish: ((Result<Void, Error>) -> Void)?
    init(lecture: LibraryLectureRecord, finish: @escaping (Result<Void, Error>) -> Void) {
        self.lecture = lecture; self.finish = finish
    }
    func complete(_ result: Result<Void, Error>) { lock.withLock { let callback = finish; finish = nil; callback?(result) } }
}

extension Notification.Name { static let libraryPreparationRequested = Notification.Name("LektienLibraryPreparationRequested") }
extension Notification.Name { static let libraryPreparationStopRequested = Notification.Name("LektienLibraryPreparationStopRequested") }

@MainActor
final class LibraryQueueController: ObservableObject {
    static let shared = LibraryQueueController()
    @Published private(set) var manifest = LibraryManifest()
    @Published var errorMessage: String?
    @Published private(set) var cacheUsage = CacheUsage(totalBytes: 0, categories: [:])
    @Published private(set) var cacheRoot: URL?
    let store: LibraryManifestStore
    private let queue: PersistentPreparationQueue

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LektienPlayer", isDirectory: true)
        store = try! LibraryManifestStore(url: support.appendingPathComponent("library-manifest-v1.json"))
        queue = PersistentPreparationQueue(store: store) { lecture in
            try await withCheckedThrowingContinuation { continuation in
                let request = LibraryPreparationRequest(lecture: lecture) { result in
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                Task { @MainActor in NotificationCenter.default.post(name: .libraryPreparationRequested, object: request) }
            }
        }
        manifest = store.snapshot()
    }

    func refresh(directory: URL) {
        do {
            configureCache(for: directory)
            manifest = try LectureLibrary.refreshManifest(directory: directory, store: store)
            cacheUsage = DerivedCacheInspector.usage(at: cacheDirectory(for: directory))
        }
        catch { errorMessage = error.localizedDescription }
    }

    func cacheDirectory(for library: URL) -> URL {
        if let relative = manifest.cache.selectedRoot {
            return library.standardizedFileURL.appendingPathComponent(relative, isDirectory: true)
        }
        return library.appendingPathComponent(".lektien", isDirectory: true)
    }

    func chooseCacheDirectory(_ directory: URL, for library: URL) {
        guard let relative = DerivedCacheLocation.relativePath(from: library, to: directory) else {
            errorMessage = translationText("cache.mustBeInLibrary")
            return
        }
        do {
            errorMessage = nil
            manifest = try store.update { $0.cache.selectedRoot = relative }
            configureCache(for: library)
            cacheUsage = DerivedCacheInspector.usage(at: directory)
        } catch { errorMessage = error.localizedDescription }
    }

    func clearRecoverableCache(for library: URL) {
        do {
            errorMessage = nil
            let root = cacheDirectory(for: library)
            cacheUsage = try DerivedCacheInspector.cleanup(at: root, store: store)
            manifest = store.snapshot()
        } catch { errorMessage = error.localizedDescription }
    }

    private func configureCache(for library: URL) {
        let root = cacheDirectory(for: library)
        cacheRoot = root
        DerivedCacheLocation.configure(libraryRoot: library, relativeRoot: manifest.cache.selectedRoot)
    }

    func registerLocalVideo(_ video: URL) {
        let source = LectureSource.local(path: video.standardizedFileURL.path)
        let id = LibraryManifestStore.lectureID(for: source)
        do {
            manifest = try store.update { value in
                if value.lectures[id] == nil {
                    value.lectures[id] = .init(id: id, source: source, attachments: LectureAttachmentLocator.discover(for: video))
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func attachments(for video: URL) -> LectureAttachments {
        let id = LibraryManifestStore.lectureID(for: .local(path: video.standardizedFileURL.path))
        return manifest.lectures[id]?.attachments ?? LectureAttachmentLocator.discover(for: video)
    }

    func saveAttachments(_ attachments: LectureAttachments, for video: URL) {
        let source = LectureSource.local(path: video.standardizedFileURL.path)
        let id = LibraryManifestStore.lectureID(for: source)
        do {
            manifest = try store.update { value in
                var record = value.lectures[id] ?? .init(id: id, source: source)
                record.attachments = attachments
                record.status.voiced = attachments.resolved(in: video.deletingLastPathComponent(), audio: true) != nil
                record.status.hasGermanSubtitles = attachments.resolved(in: video.deletingLastPathComponent(), language: .german) != nil
                record.status.translated = attachments.resolved(in: video.deletingLastPathComponent(), language: .russian) != nil
                value.lectures[id] = record
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func registerTelegram(_ media: [TelegramMedia], chatID: Int64?) {
        guard let chatID else { return }
        do {
            manifest = try store.update { value in
                for item in media where ["mp4", "m4v", "mkv", "mov"].contains(item.type.lowercased()) {
                    let source = LectureSource.telegram(chatID: chatID, messageID: item.id, fileID: item.fileID,
                                                        name: item.name, size: item.size)
                    let id = LibraryManifestStore.lectureID(for: source)
                    if value.lectures[id] == nil { value.lectures[id] = .init(id: id, source: source) }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func add(_ ids: [String]) { let queue = queue; perform { try await queue.add(ids) } }
    func addAllIncomplete() { add(manifest.lectures.values.filter { !$0.status.fullyReady }.map(\.id)) }
    func remove(_ id: UUID) { let queue = queue; perform { try await queue.remove(id) } }
    func move(_ offsets: IndexSet, _ destination: Int) { let queue = queue; perform { try await queue.move(from: offsets, to: destination) } }
    func start() { let queue = queue; perform { try await queue.start() } }
    func stop() {
        NotificationCenter.default.post(name: .libraryPreparationStopRequested, object: nil)
        let queue = queue; perform { try await queue.stop() }
    }
    func setInteractive(_ active: Bool) { let queue = queue; Task { await queue.setInteractive(active) } }
    func setAutoContinue(_ value: Bool) { let queue = queue; perform { try await queue.setAutoContinue(value) } }
    func resumeAfterLaunch() { let queue = queue; Task { await queue.resumeAfterLaunch() } }

    func updateStatus(id: String, _ body: (inout LecturePreparationStatus) -> Void) {
        do {
            manifest = try store.update { value in
                guard var record = value.lectures[id] else { return }
                body(&record.status); record.status.updatedAt = Date(); value.lectures[id] = record
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func perform(_ operation: @escaping @Sendable () async throws -> Void) {
        Task {
            do { try await operation(); manifest = store.snapshot() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func reload() { manifest = store.snapshot() }
}

struct PreparationQueueView: View {
    @StateObject private var model = LibraryQueueController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(translationText("queue.title")).font(.title2.bold())
                Spacer()
                Button(translationText("queue.addIncomplete")) { model.addAllIncomplete() }
                Button(translationText(model.manifest.queueRunning ? "queue.stop" : "queue.start")) {
                    model.manifest.queueRunning ? model.stop() : model.start()
                }.disabled(model.manifest.queue.isEmpty)
            }
            List {
                ForEach(model.manifest.queue) { item in
                    HStack {
                        Image(systemName: item.state == .running ? "gearshape.fill" : item.state == .failed ? "exclamationmark.triangle" : "line.3.horizontal")
                        VStack(alignment: .leading) {
                            Text(model.manifest.lectures[item.lectureID]?.source.displayName ?? item.lectureID)
                            Text(item.error ?? translationText("queue.state.\(item.state.rawValue)"))
                                .font(.caption).foregroundStyle(item.state == .failed ? .red : .secondary)
                        }
                        Spacer()
                        Button { model.remove(item.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help(translationText("queue.remove")).disabled(item.state == .running)
                    }
                }.onMove(perform: model.move)
            }
            Toggle(translationText("queue.autoContinue"), isOn: Binding(
                get: { model.manifest.autoContinue }, set: { value in model.setAutoContinue(value) }))
            Text(translationText("queue.priorityHelp")).font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(minWidth: 620, minHeight: 420)
            .task {
                while !Task.isCancelled {
                    model.reload()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
    }
}
