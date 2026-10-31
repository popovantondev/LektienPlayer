import Foundation
import XCTest
@testable import PlayerLAN

final class LocalLibraryServerTests: XCTestCase {
    func testEmptyLibrarySupportsTelegramOnlyServerState() {
        let library = SharedLibrary.empty()
        XCTAssertTrue(library.lectures.isEmpty)
        XCTAssertNil(library.file(for: "/media/anything/video"))
    }

    func testMixedCatalogKeepsSourcesDistinctAndSafe() throws {
        let local = SharedLecture(id: "local", name: "Local.mp4", audio: false, subtitles: [])
        let remote = TelegramLANEntryFixture(id: String(repeating: "a", count: 64), name: "Telegram.mp4")
        let localJSON = try JSONEncoder().encode([local])
        let remoteJSON = try JSONEncoder().encode([remote])
        let json = String(decoding: localJSON + remoteJSON, as: UTF8.self)
        XCTAssertTrue(json.contains("Local.mp4")); XCTAssertTrue(json.contains("Telegram.mp4"))
        XCTAssertTrue(json.contains("\"source\":\"telegram\""))
        XCTAssertFalse(json.contains("/Users/")); XCTAssertFalse(json.contains("api_hash")); XCTAssertFalse(json.contains("fileID"))
    }

    func testByteRangesAndInvalidRequests() throws {
        XCTAssertEqual(try HTTPByteRange.parse("bytes=3-8", size: 10), .init(start: 3, count: 6))
        XCTAssertEqual(try HTTPByteRange.parse("bytes=8-99", size: 10), .init(start: 8, count: 2))
        XCTAssertEqual(try HTTPByteRange.parse("bytes=-3", size: 10), .init(start: 7, count: 3))
        XCTAssertEqual(try HTTPByteRange.parse("bytes=3-", size: 10), .init(start: 3, count: 7))
        XCTAssertEqual(try HTTPByteRange.parse(nil, size: 0), .init(start: 0, count: 0))
        for header in ["bytes=10-", "bytes=-0", "bytes=8-3", "bytes=0-1,3-4", "bytes=999999999999999999999999-", "other=0-1"] {
            XCTAssertThrowsError(try HTTPByteRange.parse(header, size: 10))
        }
        XCTAssertTrue(LocalLibraryServer.privateIPv4("192.168.1.5"))
        XCTAssertFalse(LocalLibraryServer.privateIPv4("8.8.8.8"))
        XCTAssertFalse(LocalLibraryServer.privateIPv4("192.168.1.999"))
    }

    func testCatalogExcludesLinksOutsideFolderAndEscapesSubtitles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: root.appendingPathComponent("private.mp4"))
        try FileManager.default.createSymbolicLink(at: shared.appendingPathComponent("link.mp4"), withDestinationURL: root.appendingPathComponent("private.mp4"))
        try Data("video".utf8).write(to: shared.appendingPathComponent("video.mp4"))
        let sub = shared.appendingPathComponent("voice.ru.srt")
        try Data("1\n00:00:01,000 --> 00:00:02,000\n<b>пример</b> & текст\n".utf8).write(to: sub)
        let library = try SharedLibrary(directory: shared)
        XCTAssertEqual(library.lectures.count, 1)
        XCTAssertEqual(library.lectures[0].subtitles, ["ru"])
        let vtt = String(decoding: try SharedLibrary.vtt(sub), as: UTF8.self)
        XCTAssertTrue(vtt.contains("00:00:01.000 --> 00:00:02.000"))
        XCTAssertTrue(vtt.contains("&lt;b&gt;пример&lt;/b&gt; &amp; текст"))
        XCTAssertNil(library.file(for: "/media/../private.mp4"))
    }

    func testLocalCatalogIncludesMKV() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: root.appendingPathComponent("lecture.mkv"))
        let library = try SharedLibrary(directory: root)
        XCTAssertEqual(library.lectures.map(\.name), ["lecture"])
        XCTAssertNotNil(library.file(for: "/media/\(library.lectures[0].id)/video"))
    }

    func testRealServerAuthSeekAndConcurrentReaders() async throws {
        guard ProcessInfo.processInfo.environment["LEKTIEN_LAN_TEST"] == "1" else { throw XCTSkip("Opt-in local listener integration") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lektien-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
        try bytes.write(to: root.appendingPathComponent("test.mp4"))
        let library = try SharedLibrary(directory: root)
        let server = LocalLibraryServer(library: library) { path, body in
            if path.hasPrefix("/prepared/") { return .init(file: root.appendingPathComponent("test.mp4")) }
            if path == "/adapted/test/index.m3u8" { return .init(data: Data("#EXTM3U\n".utf8), contentType: "application/vnd.apple.mpegurl") }
            if path == "/adapted/test/0.media.m4s" { return .init(file: root.appendingPathComponent("test.mp4"), fileRoot: root) }
            if path == "/api/telegram" {
                return .init(data: Data(#"[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Channel lecture.mp4","audio":false,"subtitles":["de"],"source":"telegram"}]"#.utf8))
            }
            if path == "/telegram/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/video" {
                return .init(media: .init(size: UInt64(bytes.count), contentType: "video/mp4") { offset, count in
                    Data(bytes[Int(offset)..<Int(offset) + count])
                })
            }
            return .init(status: body == nil ? 200 : 202, data: Data("{}".utf8))
        }
        defer { server.stop() }
        let ready = expectation(description: "listener ready")
        let portBox = PortBox()
        try server.start(port: 0) { result in
            if case .success(let port) = result { portBox.set(port); ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(portBox.get())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func fetch(_ path: String, range: String? = nil, code: String? = nil, method: String = "GET", body: String? = nil, origin: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.httpBody = body.map { Data($0.utf8) }
            if let origin {
                request.setValue(origin == "self" ? "http://127.0.0.1:\(port)" : origin, forHTTPHeaderField: "Origin")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            if let code { request.setValue("lektien=\(code)", forHTTPHeaderField: "Cookie") }
            let (data, response) = try await session.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }
        let denied = try await fetch("/api/library")
        XCTAssertEqual(denied.1.statusCode, 401)
        let login = try await fetch("/auth", method: "POST", body: server.code)
        XCTAssertEqual(login.1.statusCode, 204)
        XCTAssertTrue(login.1.value(forHTTPHeaderField: "Set-Cookie")?.contains("HttpOnly") == true)
        let catalog = try await fetch("/api/library", code: server.code)
        XCTAssertEqual(catalog.1.statusCode, 200)
        XCTAssertFalse(String(decoding: catalog.0, as: UTF8.self).contains(root.path))
        let telegramDenied = try await fetch("/api/telegram")
        XCTAssertEqual(telegramDenied.1.statusCode, 401)
        let playlistDenied = try await fetch("/adapted/test/index.m3u8")
        XCTAssertEqual(playlistDenied.1.statusCode, 401)
        let playlist = try await fetch("/adapted/test/index.m3u8", code: server.code)
        XCTAssertEqual(playlist.1.statusCode, 200)
        XCTAssertEqual(playlist.1.value(forHTTPHeaderField: "Content-Type"), "application/vnd.apple.mpegurl; charset=utf-8")
        let mediaSegment = try await fetch("/adapted/test/0.media.m4s", range: "bytes=0-7", code: server.code)
        XCTAssertEqual(mediaSegment.1.statusCode, 206)
        XCTAssertEqual(mediaSegment.1.value(forHTTPHeaderField: "Content-Type"), "video/iso.segment")
        let telegramCatalog = try await fetch("/api/telegram", code: server.code)
        let telegramJSON = String(decoding: telegramCatalog.0, as: UTF8.self)
        XCTAssertEqual(telegramCatalog.1.statusCode, 200)
        for secret in [root.path, "api_hash", "api_id", "session", "token"] { XCTAssertFalse(telegramJSON.contains(secret)) }
        let telegramPath = "/telegram/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/video"
        let telegramWhole = try await fetch(telegramPath, code: server.code)
        XCTAssertEqual(telegramWhole.1.statusCode, 416)
        let telegramRange = try await fetch(telegramPath, range: "bytes=120000-120127", code: server.code)
        XCTAssertEqual(telegramRange.1.statusCode, 206)
        XCTAssertEqual(telegramRange.0, bytes.subdata(in: 120000..<120128))
        XCTAssertEqual(telegramRange.1.value(forHTTPHeaderField: "Content-Range"), "bytes 120000-120127/200000")
        let telegramInvalid = try await fetch(telegramPath, range: "bytes=200000-", code: server.code)
        XCTAssertEqual(telegramInvalid.1.statusCode, 416)
        let path = "/media/\(library.lectures[0].id)/video"
        async let early = fetch(path, range: "bytes=0-70000", code: server.code)
        async let late = fetch(path, range: "bytes=170000-", code: server.code)
        let (a, b) = try await (early, late)
        XCTAssertEqual(a.1.statusCode, 206); XCTAssertEqual(b.1.statusCode, 206)
        XCTAssertEqual(a.0, bytes.prefix(70_001)); XCTAssertEqual(b.0, bytes.suffix(30_000))
        XCTAssertEqual(a.1.value(forHTTPHeaderField: "Content-Range"), "bytes 0-70000/200000")
        let invalid = try await fetch(path, range: "bytes=200000-", code: server.code)
        XCTAssertEqual(invalid.1.statusCode, 416)
        let head = try await fetch(path, code: server.code, method: "HEAD")
        XCTAssertEqual(head.1.statusCode, 200); XCTAssertTrue(head.0.isEmpty)
        XCTAssertEqual(head.1.value(forHTTPHeaderField: "Content-Length"), "200000")
        let page = try await fetch("/")
        XCTAssertTrue(String(decoding: page.0, as: UTF8.self).contains("<video"))
        let noAuth = try await fetch("/api/prepare", method: "POST", body: "{}", origin: "self")
        XCTAssertEqual(noAuth.1.statusCode, 401)
        let noOrigin = try await fetch("/api/prepare", code: server.code, method: "POST", body: "{}")
        XCTAssertEqual(noOrigin.1.statusCode, 403)
        let foreign = try await fetch("/api/prepare", code: server.code, method: "POST", body: "{}", origin: "http://example.com")
        XCTAssertEqual(foreign.1.statusCode, 403)
        let prepare = try await fetch("/api/prepare", code: server.code, method: "POST", body: "{}", origin: "self")
        XCTAssertEqual(prepare.1.statusCode, 202)
        let wav = try await fetch("/prepared/test/clip.wav", range: "bytes=20-40", code: server.code)
        XCTAssertEqual(wav.1.statusCode, 206)
        XCTAssertEqual(wav.0, bytes.subdata(in: 20..<41))
        XCTAssertEqual(wav.1.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
        let script = try await fetch("/playback.js")
        XCTAssertEqual(script.1.statusCode, 200)
        let escape = try await fetch("/media/not-allowed/video", code: server.code)
        XCTAssertEqual(escape.1.statusCode, 404)
    }
}

private struct TelegramLANEntryFixture: Encodable {
    let id: String
    let name: String
    let audio = false
    let subtitles: [String] = []
    let source = "telegram"
}

private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt16?
    func set(_ port: UInt16) { lock.lock(); defer { lock.unlock() }; value = port }
    func get() -> UInt16? { lock.lock(); defer { lock.unlock() }; return value }
}
