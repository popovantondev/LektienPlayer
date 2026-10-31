import Foundation
import XCTest
import PlayerLAN
import PlayerMedia
@testable import LektienOnlineUebersetzung

@MainActor
final class NetworkPreparationTests: XCTestCase {
    @MainActor
    func testLANStartRequiresAtLeastOneSource() {
        XCTAssertFalse(NetworkController.canStart(folderSelected: false, telegramChannelSelected: false))
        XCTAssertTrue(NetworkController.canStart(folderSelected: true, telegramChannelSelected: false))
        XCTAssertTrue(NetworkController.canStart(folderSelected: false, telegramChannelSelected: true))
    }

    func testRejectsUnsharedFilesAndPreparationWhileMacIsBusy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("test".utf8).write(to: directory.appendingPathComponent("test.mp4"))
        let library = try SharedLibrary(directory: directory)
        let worker = NetworkPreparation(library: library)
        defer { worker.stop() }
        let unknown = await worker.handle("/api/prepare", body: Data("{\"id\":\"../private\",\"position\":0,\"playing\":true}".utf8))
        XCTAssertEqual(unknown.status, 400)
        worker.macBusy = { true }
        let body = try JSONSerialization.data(withJSONObject: ["id": library.lectures[0].id, "position": 0, "playing": true, "source": 0])
        let busy = await worker.handle("/api/prepare", body: body)
        XCTAssertEqual(busy.status, 409)
        let file = await worker.handle("/prepared/../private", body: nil)
        XCTAssertEqual(file.status, 404)
    }

    func testStoppingDuringInspectionCannotStartAnOrphanJob() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("test".utf8).write(to: directory.appendingPathComponent("test.mp4"))
        let library = try SharedLibrary(directory: directory)
        let started = expectation(description: "inspection started")
        let finish = DispatchSemaphore(value: 0)
        let worker = NetworkPreparation(library: library) { _, _ in
            started.fulfill()
            _ = finish.wait(timeout: .now() + 5)
            return try JSONDecoder().decode(MediaInspection.self, from: Data(#"{"streams":[{"index":1,"codec_type":"audio"}],"format":{"duration":"2"}}"#.utf8))
        }
        defer { worker.stop() }
        let body = try JSONSerialization.data(withJSONObject: ["id": library.lectures[0].id, "position": 0, "playing": true, "source": 1])
        let request = Task { await worker.handle("/api/prepare", body: body) }
        await fulfillment(of: [started], timeout: 2)
        worker.stop()
        finish.signal()
        let result = await request.value
        XCTAssertEqual(result.status, 409)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".lektien").path))
    }

    func testRealPreparationPersistsAndReusesCompletedParts() async throws {
        guard let path = ProcessInfo.processInfo.environment["LEKTIEN_LAN_PIPELINE_VIDEO"] else {
            throw XCTSkip("Opt-in short local fixture; without SRT this uses one translation window")
        }
        let video = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: video)
        let library = try SharedLibrary(directory: video.deletingLastPathComponent())
        let id = try XCTUnwrap(library.lectures.first { library.file(for: "/media/\($0.id)/video") == video }?.id)
        let worker = NetworkPreparation(library: library)
        defer { worker.stop() }
        let sources = await worker.handle("/api/sources/" + id, body: nil)
        XCTAssertEqual(sources.status, 200)
        let options = try XCTUnwrap(JSONSerialization.jsonObject(with: sources.data) as? [String: Any])
        let source = try XCTUnwrap(options["selected"] as? Int)
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "position": 0, "playing": false, "source": source])
        func prepare() async throws -> NetworkPreparation.Snapshot {
            let accepted = await worker.handle("/api/prepare", body: body)
            XCTAssertEqual(accepted.status, 202)
            for _ in 0..<600 {
                let response = await worker.handle("/api/preparation/" + id, body: nil)
                let state = try JSONDecoder().decode(NetworkPreparation.Snapshot.self, from: response.data)
                if state.state == "ready" { return state }
                XCTAssertNotEqual(state.state, "failed")
                if state.state == "failed" { throw MediaFailure.invalidOutput }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw MediaFailure.invalidOutput
        }
        let first = try await prepare()
        XCTAssertFalse(first.clips.isEmpty)
        let audio = await worker.handle(first.clips[0].url, body: nil)
        XCTAssertNotNil(audio.file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.deletingLastPathComponent().appendingPathComponent(".lektien/network/\(id).json").path))
        worker.stop()
        let second = try await prepare()
        XCTAssertEqual(second.requests, 0)
        XCTAssertEqual(first.clips.map(\.url), second.clips.map(\.url))
        XCTAssertEqual(try Data(contentsOf: video), original)
    }
}
