import CryptoKit
import Foundation

/// A portable description of the completed export selected for a manual Telegram upload.
/// File names are always relative to `exportDirectory`; the directory itself is never encoded.
public struct TelegramUploadPlan: Codable, Equatable, Sendable, Identifiable {
    public enum FileKind: String, Codable, Sendable { case video, audio, russianSubtitles, germanSubtitles }
    public struct File: Codable, Equatable, Sendable, Identifiable {
        public let localName: String
        public let size: Int64
        public let kind: FileKind
        public var id: String { localName }
        public init(localName: String, size: Int64, kind: FileKind) {
            self.localName = localName; self.size = size; self.kind = kind
        }
    }

    public let destinationChatID: Int64
    public let files: [File]
    public let idempotencyKey: String
    public var id: String { idempotencyKey }

    public init(destinationChatID: Int64, files: [File]) throws {
        guard destinationChatID != 0, !files.isEmpty,
              Set(files.map(\.localName)).count == files.count,
              files.allSatisfy({ Self.safeName($0.localName) && $0.size >= 0 }),
              files.filter({ $0.kind == .video || $0.kind == .audio }).count == 1,
              files.contains(where: { $0.kind == .russianSubtitles }) else { throw TelegramUploadError.invalidPlan }
        self.destinationChatID = destinationChatID
        self.files = files
        let identity = ([String(destinationChatID)] + files.map { "\($0.kind.rawValue)|\($0.localName)|\($0.size)" }.sorted())
            .joined(separator: "\n")
        idempotencyKey = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Builds the only allowed upload set from an atomically published export folder.
    public static func make(exportDirectory: URL, destinationChatID: Int64) throws -> TelegramUploadPlan {
        let unwrappedRoot = exportDirectory.standardizedFileURL
        guard (try? unwrappedRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw TelegramUploadError.invalidPlan }
        let root = unwrappedRoot.resolvingSymlinksInPath()
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw TelegramUploadError.invalidPlan }
        let candidates: [(String, FileKind)] = [("video.mp4", .video), ("video.mkv", .video), ("voice.ru.m4a", .audio),
                                                  ("voice.ru.srt", .russianSubtitles), ("voice.de.srt", .germanSubtitles)]
        var files: [File] = []
        var hasPrimary = false
        for (name, kind) in candidates {
            if (kind == .video || kind == .audio) && hasPrimary { continue }
            let url = root.appendingPathComponent(name).resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path + "/") else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            files.append(.init(localName: name, size: Int64(values.fileSize ?? 0), kind: kind))
            if kind == .video || kind == .audio { hasPrimary = true }
        }
        return try .init(destinationChatID: destinationChatID, files: files)
    }

    public func resolvedFiles(in exportDirectory: URL) throws -> [(File, URL)] {
        let root = exportDirectory.standardizedFileURL.resolvingSymlinksInPath()
        return try files.map { file in
            guard Self.safeName(file.localName) else { throw TelegramUploadError.invalidPlan }
            let url = root.appendingPathComponent(file.localName).resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path + "/"),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == file.size else { throw TelegramUploadError.fileChanged }
            return (file, url)
        }
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && URL(fileURLWithPath: name).lastPathComponent == name && !name.contains("/") && !name.contains("\\")
    }
}

public enum TelegramUploadError: Error, Equatable { case invalidPlan, fileChanged }

public enum TelegramUploadStatus: String, Codable, Sendable { case pending, sending, completed, cancelled, failed }

/// Durable local progress. Completed file names prevent a retry from re-sending a file.
public struct TelegramUploadReceipt: Codable, Equatable, Sendable {
    public let idempotencyKey: String
    public var status: TelegramUploadStatus
    public var completedFileNames: [String]
    /// A request may have reached TDLib before cancellation. It is never sent again automatically.
    public var submittedFileNames: [String]
    public var error: String?
    public var updatedAt: Date
    public init(plan: TelegramUploadPlan) {
        idempotencyKey = plan.idempotencyKey; status = .pending; completedFileNames = []; submittedFileNames = []; error = nil; updatedAt = Date()
    }
    public mutating func markSending(_ name: String) {
        if !submittedFileNames.contains(name) { submittedFileNames.append(name) }
        status = .sending; error = nil; updatedAt = Date()
    }
    public mutating func markCompleted(_ name: String, total: Int) {
        if !completedFileNames.contains(name) { completedFileNames.append(name) }
        submittedFileNames.removeAll { $0 == name }
        status = completedFileNames.count == total ? .completed : .pending; error = nil; updatedAt = Date()
    }
    public mutating func cancel() { status = .cancelled; updatedAt = Date() }
    public mutating func fail(_ message: String, retrying name: String? = nil) {
        if let name { submittedFileNames.removeAll { $0 == name } }
        status = .failed; error = message; updatedAt = Date()
    }
}

public final class TelegramUploadReceiptStore: @unchecked Sendable {
    public static let fileName = ".telegram-upload-receipt.json"
    public let url: URL
    public init(exportDirectory: URL) { url = exportDirectory.appendingPathComponent(Self.fileName) }
    public func load(for plan: TelegramUploadPlan) -> TelegramUploadReceipt {
        guard let data = try? Data(contentsOf: url), let receipt = try? JSONDecoder().decode(TelegramUploadReceipt.self, from: data),
              receipt.idempotencyKey == plan.idempotencyKey else { return .init(plan: plan) }
        return receipt
    }
    public func save(_ receipt: TelegramUploadReceipt) throws {
        let data = try JSONEncoder().encode(receipt)
        try data.write(to: url, options: .atomic)
    }
}

/// TDLib JSON construction is kept data-only so it can be validated without a TDLib session.
public enum TelegramUploadRequestBuilder {
    public static func sendMessage(plan: TelegramUploadPlan, file: TelegramUploadPlan.File, resolvedURL: URL) throws -> Data {
        guard plan.files.contains(file), file.localName == resolvedURL.lastPathComponent else { throw TelegramUploadError.invalidPlan }
        let contentType = file.kind == .video ? "inputMessageVideo" : "inputMessageDocument"
        let fileKey = file.kind == .video ? "video" : "document"
        let content: [String: Any] = ["@type": contentType, fileKey: ["@type": "inputFileLocal", "path": resolvedURL.path]]
        let object: [String: Any] = ["@type": "sendMessage", "chat_id": plan.destinationChatID,
            "input_message_content": content,
            "@extra": ["kind": "upload", "idempotency_key": plan.idempotencyKey, "local_name": file.localName]]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
