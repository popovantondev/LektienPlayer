import Foundation
import Network
import PlayerMedia

/// One bounded TDLib request at a time. Playback reads outrank media preparation.
@MainActor
final class TelegramRangeStore {
    enum Priority: Int { case preparation = 0, playback = 1 }
    typealias Fetch = @MainActor (UUID, Int64, Int, @escaping @Sendable (Result<Data, Error>) -> Void) -> Void
    typealias Cancel = @MainActor (UUID) -> Void
    private struct Request {
        let id: UUID
        let offset: Int64
        let priority: Priority
        let continuation: CheckedContinuation<Data, Error>
    }
    let item: TelegramMedia
    private let directory: URL
    private let fetch: Fetch
    private let cancelFetch: Cancel
    private var pending: [Request] = []
    private var working = false
    private var active: Request?
    private var stopped = false
    private static let blockSize: Int64 = 1024 * 1024

    init(item: TelegramMedia, storageURL: URL, controller: TelegramController) throws {
        self.item = item
        let identity = MediaPublication.hash(Data("\(item.id):\(item.fileID):\(item.size):\(item.name)".utf8))
        directory = storageURL.deletingLastPathComponent().appendingPathComponent(".lektien/telegram-ranges/\(identity)", isDirectory: true)
        fetch = { id, offset, length, completion in
            controller.requestStreamRange(id: id, fileID: item.fileID, offset: offset, length: length, completion: completion)
        }
        cancelFetch = { id in controller.cancelStreamRange(id) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    init(item: TelegramMedia, directory: URL, fetch: @escaping Fetch,
         cancel: @escaping Cancel = { _ in }) throws {
        self.item = item; self.directory = directory; self.fetch = fetch; cancelFetch = cancel
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    var identity: String {
        MediaPublication.hash(Data("telegram:\(item.id):\(item.fileID):\(item.size):\(item.name)".utf8))
    }

    func read(offset: Int64, length: Int, priority: Priority) async throws -> Data {
        guard !stopped, offset >= 0, length > 0, offset < item.size else { throw TelegramClientError.invalidResponse }
        let end = min(item.size, offset + Int64(length))
        var result = Data()
        var cursor = offset
        while cursor < end {
            try Task.checkCancellation()
            let block = cursor / Self.blockSize * Self.blockSize
            let bytes = try await blockData(at: block, priority: priority)
            let local = Int(cursor - block)
            let count = min(Int(end - cursor), bytes.count - local)
            guard count > 0 else { throw TelegramClientError.invalidResponse }
            result.append(bytes[local..<(local + count)])
            cursor += Int64(count)
        }
        return result
    }

    func stop() {
        stopped = true
        let waiting = pending; pending = []
        waiting.forEach { $0.continuation.resume(throwing: MediaFailure.stopped) }
        if let active {
            cancelFetch(active.id)
            self.active = nil
            active.continuation.resume(throwing: MediaFailure.stopped)
        }
        working = false
    }

    private static func nextIndex(_ pending: [Request]) -> Int? {
        pending.indices.max { left, right in
            if pending[left].priority.rawValue != pending[right].priority.rawValue {
                return pending[left].priority.rawValue < pending[right].priority.rawValue
            }
            return left > right
        }
    }

    private func blockData(at offset: Int64, priority: Priority) async throws -> Data {
        let file = directory.appendingPathComponent("\(offset).bin")
        let expected = Int(min(Self.blockSize, item.size - offset))
        if let data = try? Data(contentsOf: file), data.count == expected { return data }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pending.append(.init(id: id, offset: offset, priority: priority, continuation: continuation))
                    pump()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRequest(id) }
        }
    }

    private func cancelRequest(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            let request = pending.remove(at: index)
            request.continuation.resume(throwing: CancellationError())
            return
        }
        guard active?.id == id, let request = active else { return }
        cancelFetch(id)
        active = nil
        working = false
        request.continuation.resume(throwing: CancellationError())
        pump()
    }

    private func pump() {
        guard !working, !pending.isEmpty else { return }
        working = true
        let request = pending.remove(at: Self.nextIndex(pending)!)
        active = request
        let file = directory.appendingPathComponent("\(request.offset).bin")
        let expected = Int(min(Self.blockSize, item.size - request.offset))
        if let data = try? Data(contentsOf: file), data.count == expected {
            request.continuation.resume(returning: data)
            active = nil; working = false; pump(); return
        }
        fetch(request.id, request.offset, expected) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.active?.id == request.id else { return }
                defer { self.active = nil; self.working = false; self.pump() }
                switch result {
                case .success(let data) where data.count == expected:
                    do {
                        if !FileManager.default.fileExists(atPath: file.path) {
                            try MediaPublication.writeNew(data, to: file)
                        }
                        request.continuation.resume(returning: data)
                    } catch { request.continuation.resume(throwing: error) }
                case .failure(let error): request.continuation.resume(throwing: error)
                default: request.continuation.resume(throwing: TelegramClientError.invalidResponse)
                }
            }
        }
    }
}

/// FFprobe and FFmpeg seek over this private HTTP endpoint; only the selected
/// media is available, and responses are fulfilled through the same range cache.
final class TelegramMediaServer: @unchecked Sendable {
    private let store: TelegramRangeStore
    private let size: Int64
    private let type: String
    private let queue = DispatchQueue(label: "player.telegram.media", qos: .utility)
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]

    @MainActor init(store: TelegramRangeStore) {
        self.store = store; size = store.item.size; type = store.item.type
    }

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port else { continuation.resume(throwing: MediaFailure.unavailable); return }
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/media")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
                _ = self
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel(); listener = nil
            connections.values.forEach { $0.cancel() }; connections = [:]
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receiveHeader(connection, id: id, accumulated: Data())
    }

    private func receiveHeader(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection else { return }
            var header = accumulated
            if let data { header.append(data) }
            guard header.count <= 16 * 1024, error == nil else { self.finish(connection, id: id); return }
            guard let marker = header.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { self.finish(connection, id: id) }
                else { self.receiveHeader(connection, id: id, accumulated: header) }
                return
            }
            let headerData = header[..<marker.upperBound]
            guard let text = String(data: headerData, encoding: .utf8),
                  let first = text.components(separatedBy: "\r\n").first,
                  (first == "GET /media HTTP/1.1" || first == "HEAD /media HTTP/1.1") else {
                self.finish(connection, id: id); return
            }
            let isHead = first.hasPrefix("HEAD")
            let range = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
            guard range != nil || isHead else { self.finish(connection, id: id); return }
            let bounds = range?.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            let start = bounds?.first.flatMap { Int64($0) } ?? 0
            let end = bounds?.count == 2 ? Int64(bounds![1]) ?? min(start + 1024 * 1024 - 1, self.size - 1) : self.size - 1
            guard start >= 0, end >= start, end < self.size, isHead || end - start < 8 * 1024 * 1024 else {
                self.finish(connection, id: id); return
            }
            Task { @MainActor in
                do {
                    let payload = isHead ? Data() : try await self.store.read(offset: start, length: Int(end - start + 1), priority: .preparation)
                    let partial = range != nil
                    let header = "HTTP/1.1 \(partial ? 206 : 200) OK\r\nContent-Type: video/\(self.type)\r\nAccept-Ranges: bytes\r\nContent-Length: \(end - start + 1)\r\n\(partial ? "Content-Range: bytes \(start)-\(end)/\(self.size)\r\n" : "")Connection: close\r\n\r\n"
                    connection.send(content: Data(header.utf8) + payload, completion: .contentProcessed { [weak self] _ in
                        self?.finish(connection, id: id)
                    })
                } catch { self.queue.async { [weak self] in self?.finish(connection, id: id) } }
            }
        }
    }

    private func finish(_ connection: NWConnection, id: UUID) {
        connections[id] = nil
        connection.cancel()
    }
}
