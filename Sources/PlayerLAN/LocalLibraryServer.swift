import Foundation
import Network
import Darwin

/// All mutable listener/connection state is confined to queue. No discovery,
/// router configuration or internet-facing relay is used.
public final class LocalLibraryServer: @unchecked Sendable {
    public let code = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    public let addresses: [String]
    public let library: SharedLibrary
    private let queue = DispatchQueue(label: "player.lan", qos: .utility)
    private let handler: LANRequestHandler?
    private var listener: NWListener?
    private var clients: [UUID: HTTPConnection] = [:]

    public init(library: SharedLibrary, handler: LANRequestHandler? = nil) {
        self.library = library
        self.handler = handler
        addresses = Self.localAddresses()
    }

    public func start(port: UInt16, state: @escaping @Sendable (Result<UInt16, Error>) -> Void) throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        listener.stateUpdateHandler = { [weak listener] value in
            switch value {
            case .ready: if let port = listener?.port { state(.success(port.rawValue)) }
            case .failed(let error): state(.failure(error))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, self.clients.count < 32, Self.isLocalPeer(connection.endpoint) else { connection.cancel(); return }
            let id = UUID()
            let client = HTTPConnection(connection: connection, queue: self.queue, library: self.library,
                handler: self.handler, code: self.code, hosts: self.addresses + ["127.0.0.1", "localhost"], port: listener?.port?.rawValue ?? port,
                finished: { [weak self] in self?.clients.removeValue(forKey: id) })
            self.clients[id] = client
            client.start()
        }
        listener.start(queue: queue)
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel(); listener = nil
            let active = Array(clients.values)
            active.forEach { $0.close() }
        }
    }

    static func privateIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
    }
    private static func isLocalPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let value): return privateIPv4(value.debugDescription)
        case .ipv6(let value): return value == .loopback
        default: return false
        }
    }
    private static func localAddresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var cursor = first
        var result = Set<String>()
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  current.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if privateIPv4(host), !host.hasPrefix("127.") { result.insert(host) }
            }
        }
        return result.sorted()
    }
}

private final class HTTPConnection: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    let library: SharedLibrary
    let handler: LANRequestHandler?
    let code: String
    let hosts: [String]
    let port: UInt16
    let finished: @Sendable () -> Void
    var input = Data()
    var file: FileHandle?
    var remoteTask: Task<Void, Never>?
    var remaining: UInt64 = 0
    var deadline: DispatchWorkItem?
    var closed = false
    let security = "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; media-src 'self'; connect-src 'self'; frame-ancestors 'none'\r\n"

    init(connection: NWConnection, queue: DispatchQueue, library: SharedLibrary, handler: LANRequestHandler?, code: String,
         hosts: [String], port: UInt16, finished: @escaping @Sendable () -> Void) {
        self.connection = connection; self.queue = queue; self.library = library
        self.handler = handler; self.code = code; self.hosts = hosts; self.port = port; self.finished = finished
    }
    func start() {
        connection.start(queue: queue)
        armTimeout()
        receive()
    }
    func armTimeout() {
        deadline?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.close() }
        deadline = item
        queue.asyncAfter(deadline: .now() + 15, execute: item)
    }
    func close() {
        guard !closed else { return }
        closed = true; deadline?.cancel(); deadline = nil
        try? file?.close(); file = nil
        remoteTask?.cancel(); remoteTask = nil
        connection.cancel(); finished()
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.input.append(data) }
            guard self.input.count <= 32_768 else { self.respond(431); return }
            if self.routeIfComplete() { return }
            if complete || error != nil { self.close() } else { self.receive() }
        }
    }
    func routeIfComplete() -> Bool {
        guard let boundary = input.range(of: Data("\r\n\r\n".utf8)) else { return false }
        guard let header = String(data: input[..<boundary.lowerBound], encoding: .utf8) else { respond(400); return true }
        let lines = header.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { respond(400); return true }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { respond(400); return true }
            let key = line[..<colon].lowercased()
            guard fields[key] == nil else { respond(400); return true }
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let host = fields["host"] ?? ""
        guard hosts.contains(where: { host == "\($0):\(port)" }), fields["transfer-encoding"] == nil,
              fields["origin"] == nil || fields["origin"] == "http://\(host)" else { respond(403); return true }
        let method = String(first[0]), path = String(first[1])
        guard ["GET", "HEAD", "POST"].contains(method) else { respond(405); return true }
        if path == "/auth", method == "POST" {
            guard let count = Int(fields["content-length"] ?? ""), count == code.utf8.count else { respond(403); return true }
            guard input.count >= boundary.upperBound + count else { return false }
            let submitted = input[boundary.upperBound..<(boundary.upperBound + count)]
            guard submitted == Data(code.utf8) else { respond(403); return true }
            respond(204, extra: "Set-Cookie: lektien=\(code); HttpOnly; SameSite=Strict; Path=/\r\n")
            return true
        }
        let assets = ["/prepared-speech.js": ("prepared-speech", "js", "text/javascript"), "/adaptive-video.js": ("adaptive-video", "js", "text/javascript"), "/": ("index", "html", "text/html"), "/player.js": ("player", "js", "text/javascript"), "/playback.js": ("playback", "js", "text/javascript"), "/player.css": ("player", "css", "text/css")]
        let resources = Bundle.main.url(forResource: "LektienOnlineUebersetzung_PlayerLAN", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? .module
        if method != "POST", let asset = assets[path], let url = resources.url(forResource: asset.0, withExtension: asset.1, subdirectory: "Web"), let data = try? Data(contentsOf: url) {
            respond(200, data: data, type: asset.2, head: method == "HEAD"); return true
        }
        let cookies = (fields["cookie"] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard cookies.contains("lektien=\(code)") else { respond(401); return true }
        if let handler, path.hasPrefix("/api/preparation/") || path.hasPrefix("/api/sources/") || path.hasPrefix("/api/video/") || path.hasPrefix("/prepared/") || path.hasPrefix("/adapted/") || path.hasPrefix("/telegram/") || path == "/api/telegram" || path == "/api/library" ||
            ["/api/prepare", "/api/position", "/api/video/position", "/api/stop", "/api/telegram/select"].contains(path) {
            let mutation = ["/api/prepare", "/api/position", "/api/video/position", "/api/stop", "/api/telegram/select"].contains(path)
            guard mutation ? method == "POST" : method == "GET" || method == "HEAD" else { respond(405); return true }
            var body: Data?
            if mutation {
                guard fields["origin"] == "http://\(host)", fields["content-type"] == "application/json",
                      let count = Int(fields["content-length"] ?? ""), (1...4096).contains(count) else { respond(403); return true }
                guard input.count >= boundary.upperBound + count else { return false }
                body = Data(input[boundary.upperBound..<(boundary.upperBound + count)])
            }
            let requestBody = body
            let requestFields = fields
            Task { [weak self] in
                let response = await handler(path, requestBody)
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, !self.closed else { return }
                    if let media = response.media {
                        self.serveRemote(media, fields: requestFields, head: method == "HEAD")
                    } else if let url = response.file {
                        guard SharedLibrary.regular(url, in: response.fileRoot ?? self.library.root) else { self.respond(404); return }
                        self.serveFile(url, path: path, fields: requestFields, head: method == "HEAD")
                    } else { self.respond(response.status, data: response.data, type: response.contentType ?? (response.status == 200 && path.hasSuffix(".vtt") ? "text/vtt" : "application/json"), head: method == "HEAD") }
                }
            }
            return true
        }
        guard method != "POST" else { respond(405); return true }
        if path == "/api/library", let data = try? JSONEncoder().encode(library.lectures) {
            respond(200, data: data, type: "application/json", head: method == "HEAD"); return true
        }
        guard let url = library.file(for: path) else { respond(404); return true }
        serveFile(url, path: path, fields: fields, head: method == "HEAD")
        return true
    }
    func serveRemote(_ media: LANStreamedMedia, fields: [String: String], head: Bool) {
        let rangeHeader = fields["if-range"] == nil ? fields["range"] : nil
        guard head || rangeHeader != nil else { respond(416, extra: "Content-Range: bytes */\(media.size)\r\n"); return }
        let range: HTTPByteRange
        do { range = try .parse(rangeHeader, size: media.size) }
        catch { respond(416, extra: "Content-Range: bytes */\(media.size)\r\n"); return }
        let partial = rangeHeader != nil
        let extra = partial ? "Content-Range: bytes \(range.start)-\(range.start + range.count - 1)/\(media.size)\r\n" : ""
        let header = "HTTP/1.1 \(partial ? 206 : 200) OK\r\nContent-Type: \(media.contentType)\r\nContent-Length: \(range.count)\r\nAccept-Ranges: bytes\r\n\(extra)\(security)Connection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil || head || range.count == 0 { self.close(); return }
            self.sendRemote(media, offset: range.start, remaining: range.count)
        })
    }
    func sendRemote(_ media: LANStreamedMedia, offset: UInt64, remaining: UInt64) {
        guard !closed, remaining > 0 else { close(); return }
        remoteTask = Task { [weak self] in
            do {
                let count = Int(min(remaining, 1024 * 1024))
                let data = try await media.read(offset, count)
                guard !Task.isCancelled, data.count == count else { throw CancellationError() }
                self?.queue.async { [weak self] in
                    guard let self, !self.closed else { return }
                    self.armTimeout()
                    self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if error != nil { self.close() }
                        else { self.sendRemote(media, offset: offset + UInt64(count), remaining: remaining - UInt64(count)) }
                    })
                }
            } catch { self?.queue.async { [weak self] in self?.close() } }
        }
    }
    func serveFile(_ url: URL, path: String, fields: [String: String], head: Bool) {
        do {
            if path.hasSuffix(".vtt") {
                respond(200, data: try SharedLibrary.vtt(url), type: "text/vtt", head: head)
                return
            }
            let handle = try FileHandle(forReadingFrom: url)
            file = handle
            let size = try handle.seekToEnd()
            let range: HTTPByteRange
            let rangeHeader = fields["if-range"] == nil ? fields["range"] : nil
            do { range = try .parse(rangeHeader, size: size) }
            catch { respond(416, extra: "Content-Range: bytes */\(size)\r\n"); return }
            try handle.seek(toOffset: range.start)
            remaining = head ? 0 : range.count
            let partial = rangeHeader != nil
            let extra = partial ? "Content-Range: bytes \(range.start)-\(range.start + range.count - 1)/\(size)\r\n" : ""
            let type = path.hasSuffix(".wav") ? "audio/wav" : path.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : path.hasSuffix(".m4s") ? "video/iso.segment" : path.hasSuffix("/audio") ? "audio/mp4" : "video/mp4"
            let response = "HTTP/1.1 \(partial ? 206 : 200) OK\r\nContent-Type: \(type)\r\nContent-Length: \(range.count)\r\nAccept-Ranges: bytes\r\n\(extra)\(security)Connection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
                if error != nil { self?.close() } else { self?.sendFile() }
            })
        } catch { respond(500) }
    }
    func sendFile() {
        guard !closed, remaining > 0, let file else { close(); return }
        do {
            guard let bytes = try file.read(upToCount: Int(min(remaining, 65_536))), !bytes.isEmpty else { close(); return }
            remaining -= UInt64(bytes.count)
            armTimeout()
            connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.close() } else { self?.sendFile() }
            })
        } catch { close() }
    }
    func respond(_ status: Int, data: Data = Data(), type: String = "text/plain", extra: String = "", head: Bool = false) {
        let header = "HTTP/1.1 \(status) Response\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(data.count)\r\n\(security)\(extra)Connection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + (head ? Data() : data), completion: .contentProcessed { [weak self] _ in self?.close() })
    }
}
