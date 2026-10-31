import Foundation
import XCTest
@testable import PlayerCore

final class TelegramUploadTests: XCTestCase {
    func testPlanOnlyIncludesAllowlistedRelativeExportFiles() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2]).write(to: root.appendingPathComponent("voice.ru.m4a"))
        try Data([3]).write(to: root.appendingPathComponent("voice.ru.srt"))
        try Data([4]).write(to: root.appendingPathComponent("voice.de.srt"))
        try Data([5]).write(to: root.appendingPathComponent("private.txt"))

        let plan = try TelegramUploadPlan.make(exportDirectory: root, destinationChatID: 42)
        XCTAssertEqual(plan.files.map(\.localName), ["voice.ru.m4a", "voice.ru.srt", "voice.de.srt"])
        XCTAssertFalse(plan.files.contains { $0.localName.hasPrefix("/") })
        XCTAssertNil(try JSONEncoder().encode(plan).range(of: Data(root.path.utf8)))
    }

    func testRequestJSONUsesVideoOrDocumentAndKeepsPortablePlanData() throws {
        let plan = try TelegramUploadPlan(destinationChatID: 42, files: [.init(localName: "video.mp4", size: 2, kind: .video), .init(localName: "voice.ru.srt", size: 1, kind: .russianSubtitles)])
        let json = try TelegramUploadRequestBuilder.sendMessage(plan: plan, file: plan.files[0], resolvedURL: URL(fileURLWithPath: "/private/tmp/video.mp4"))
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(request["@type"] as? String, "sendMessage")
        XCTAssertEqual(request["chat_id"] as? Int, 42)
        XCTAssertEqual((request["input_message_content"] as? [String: Any])?["@type"] as? String, "inputMessageVideo")
        XCTAssertEqual(((request["@extra"] as? [String: Any])?["local_name"] as? String), "video.mp4")
        XCTAssertNil(try JSONEncoder().encode(plan).range(of: Data("/private/tmp".utf8)))
    }

    func testReceiptCancellationAndRetryNeverResubmitsSubmittedFile() throws {
        let plan = try TelegramUploadPlan(destinationChatID: 42, files: [.init(localName: "voice.ru.m4a", size: 2, kind: .audio), .init(localName: "voice.ru.srt", size: 1, kind: .russianSubtitles)])
        var receipt = TelegramUploadReceipt(plan: plan)
        receipt.markSending("voice.ru.m4a")
        receipt.cancel()
        XCTAssertEqual(receipt.status, .cancelled)
        XCTAssertEqual(receipt.submittedFileNames, ["voice.ru.m4a"])
        receipt.markCompleted("voice.ru.srt", total: plan.files.count)
        XCTAssertEqual(receipt.status, .pending)
        XCTAssertEqual(receipt.completedFileNames, ["voice.ru.srt"])
    }

    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("telegram-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
