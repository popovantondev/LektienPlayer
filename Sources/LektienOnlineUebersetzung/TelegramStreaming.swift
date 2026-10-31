@preconcurrency import AVFoundation
import Foundation
import PlayerMedia
import UniformTypeIdentifiers

@MainActor
final class TelegramStreamSelection: NSObject {
    let item: TelegramMedia
    let storageURL: URL
    let asset: AVURLAsset
    let rangeStore: TelegramRangeStore
    let mediaServer: TelegramMediaServer
    let cacheVideoURL: URL
    private let loader: TelegramAssetLoader
    private var preparedMediaURL: URL?

    init(item: TelegramMedia, storageURL: URL, controller: TelegramController) throws {
        self.item = item
        self.storageURL = storageURL
        let identity = MediaPublication.hash(Data("\(item.id):\(item.fileID):\(item.size):\(item.name)".utf8))
        cacheVideoURL = storageURL.deletingLastPathComponent()
            .appendingPathComponent(".lektien/telegram-videos/\(identity)/\(storageURL.lastPathComponent)")
        try FileManager.default.createDirectory(at: cacheVideoURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        rangeStore = try TelegramRangeStore(item: item, storageURL: storageURL, controller: controller)
        mediaServer = TelegramMediaServer(store: rangeStore)
        loader = TelegramAssetLoader(item: item, store: rangeStore)
        var components = URLComponents()
        components.scheme = "lektien-telegram"
        components.host = "media"
        components.path = "/\(item.fileID)/\(item.name)"
        asset = AVURLAsset(url: components.url!)
        super.init()
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    }

    func stop() {
        rangeStore.stop()
        mediaServer.stop()
    }

    func preparationURL() async throws -> URL {
        if let preparedMediaURL { return preparedMediaURL }
        let url = try await mediaServer.start()
        preparedMediaURL = url
        return url
    }

    var currentPreparationURL: URL? { preparedMediaURL }
}

private final class TelegramAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "player.telegram.stream", qos: .userInitiated)
    private let store: TelegramRangeStore
    private let item: TelegramMedia
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var active: AVAssetResourceLoadingRequest?
    private var activeRangeID: UUID?
    private let chunkSize = 2 * 1024 * 1024

    init(item: TelegramMedia, store: TelegramRangeStore) {
        self.item = item
        self.store = store
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let information = request.contentInformationRequest {
            information.contentLength = item.size
            information.isByteRangeAccessSupported = true
            information.contentType = UTType(filenameExtension: item.type)?.identifier ?? UTType.mpeg4Movie.identifier
        }
        guard request.dataRequest != nil else { request.finishLoading(); return true }
        pending.append(request)
        startNextIfNeeded()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel request: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === request }
        guard active === request else { return }
        activeRangeID = nil
        active = nil
        startNextIfNeeded()
    }

    private func startNextIfNeeded() {
        guard active == nil, !pending.isEmpty else { return }
        active = pending.removeFirst()
        requestNextChunk()
    }

    private func requestNextChunk() {
        guard let request = active, let dataRequest = request.dataRequest else { finishActive(); return }
        let start = dataRequest.currentOffset > 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
        let requestedEnd: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            requestedEnd = item.size
        } else {
            requestedEnd = min(item.size, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
        }
        guard start < requestedEnd else { finishActive(); return }
        let count = Int(min(Int64(chunkSize), requestedEnd - start))
        let rangeID = UUID()
        activeRangeID = rangeID
        Task { @MainActor [weak self, store] in
            let result: Result<Data, Error>
            do { result = .success(try await store.read(offset: start, length: count, priority: .playback)) }
            catch { result = .failure(error) }
            self?.queue.async { [weak self] in self?.received(result, rangeID: rangeID) }
        }
    }

    private func received(_ result: Result<Data, Error>, rangeID: UUID) {
        guard activeRangeID == rangeID, let request = active, let dataRequest = request.dataRequest else { return }
        activeRangeID = nil
        switch result {
        case .success(let data):
            guard !data.isEmpty else { request.finishLoading(with: TelegramClientError.invalidResponse); finishActive(startNext: true); return }
            dataRequest.respond(with: data)
            requestNextChunk()
        case .failure(let error):
            request.finishLoading(with: error)
            finishActive(startNext: true)
        }
    }

    private func finishActive(startNext: Bool = true) {
        active?.finishLoading()
        active = nil
        activeRangeID = nil
        if startNext { startNextIfNeeded() }
    }
}
