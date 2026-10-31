import Darwin
import Foundation
import PlayerCore

enum TelegramAuthorizationStep: Equatable {
    case idle, starting, phone, code, password, ready, unavailable(String), failed(String)
}

struct TelegramChat: Identifiable, Equatable {
    let id: Int64
    let title: String
    let kind: String
}

struct TelegramMedia: Identifiable, Equatable {
    let id: Int64
    let fileID: Int32
    let name: String
    let size: Int64
    let type: String
}

private final class TDJSONLibrary: @unchecked Sendable {
    typealias Create = @convention(c) () -> Int32
    typealias Send = @convention(c) (Int32, UnsafePointer<CChar>) -> Void
    typealias Receive = @convention(c) (Double) -> UnsafePointer<CChar>?
    typealias Execute = @convention(c) (UnsafePointer<CChar>) -> UnsafePointer<CChar>?

    let handle: UnsafeMutableRawPointer
    let create: Create
    let send: Send
    let receive: Receive
    let execute: Execute

    init() throws {
        let override = ProcessInfo.processInfo.environment["LEKTIEN_TDLIB_PATH"].map(URL.init(fileURLWithPath:))
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Runtime/lib/libtdjson.dylib")
        guard let url = [override, packaged].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            throw TelegramClientError.libraryMissing
        }
        self.handle = handle
        do {
            create = try Self.symbol("td_create_client_id", in: handle)
            send = try Self.symbol("td_send", in: handle)
            receive = try Self.symbol("td_receive", in: handle)
            execute = try Self.symbol("td_execute", in: handle)
        } catch {
            dlclose(handle)
            throw error
        }
    }

    // TDLib owns worker threads. Keep the image loaded for the process lifetime;
    // unloading a dylib while a client is closing would make those threads unsafe.

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) throws -> T {
        guard let pointer = dlsym(handle, name) else { throw TelegramClientError.invalidLibrary }
        return unsafeBitCast(pointer, to: T.self)
    }
}

enum TelegramClientError: LocalizedError {
    case libraryMissing, invalidLibrary, invalidResponse

    var errorDescription: String? {
        switch self {
        case .libraryMissing: translationText("telegram.error.libraryMissing")
        case .invalidLibrary: translationText("telegram.error.invalidLibrary")
        case .invalidResponse: translationText("telegram.error.response")
        }
    }
}

@MainActor
final class TelegramController: ObservableObject {
    static let shared = TelegramController()
    @Published private(set) var step: TelegramAuthorizationStep = .idle
    @Published private(set) var chats: [TelegramChat] = []
    @Published private(set) var media: [TelegramMedia] = []
    @Published private(set) var downloadStatus = ""
    @Published private(set) var isLoadingMedia = false
    @Published private(set) var canLoadMoreMedia = false
    @Published private(set) var mediaError: String?
    @Published private(set) var uploadReceipt: TelegramUploadReceipt?

    private var library: TDJSONLibrary?
    private var clientID: Int32?
    private var receiveTask: Task<Void, Never>?
    private var knownChats: [Int64: TelegramChat] = [:]
    private var didSendParameters = false
    private var selectedChatID: Int64?
    var lanMedia: [TelegramMedia] {
        guard step == .ready, selectedChatID != nil else { return [] }
        return media
    }
    var lanChatID: Int64? { step == .ready ? selectedChatID : nil }
    private var pendingDownloads: [Int32: TelegramMedia] = [:]
    private struct StreamRead {
        let id: UUID
        let offset: Int64
        let length: Int
        let completion: @Sendable (Result<Data, Error>) -> Void
    }
    private var streamReads: [Int32: StreamRead] = [:]
    private var historyRequestID = UUID()
    private var historyCursor: Int64 = 0
    private var historyScanned = 0
    private var historyItems: [Int64: TelegramMedia] = [:]
    private var shouldContinueHistoryAutomatically = false
    private var uploadPlan: TelegramUploadPlan?
    private var uploadDirectory: URL?
    private var uploadStore: TelegramUploadReceiptStore?
    private var pendingUploadName: String?

    private static let historyPageSize = 100
    private static let automaticHistoryLimit = 1_000

    func start(credentials: TelegramCredentials) {
        stop()
        didSendParameters = false
        step = .starting
        do {
            let library = try TDJSONLibrary()
            self.library = library
            let clientID = library.create()
            self.clientID = clientID
            receiveTask = Task.detached(priority: .utility) { [weak self, library] in
                while !Task.isCancelled {
                    guard let result = library.receive(0.5) else { continue }
                    await self?.receive(String(cString: result), credentials: credentials)
                }
            }
            send(["@type": "getAuthorizationState"])
        } catch {
            step = .unavailable(error.localizedDescription)
        }
    }

    func submitPhone(_ phone: String) {
        send(["@type": "setAuthenticationPhoneNumber", "phone_number": phone, "settings": NSNull()])
    }

    func submitCode(_ code: String) {
        send(["@type": "checkAuthenticationCode", "code": code])
    }

    func submitPassword(_ password: String) {
        send(["@type": "checkAuthenticationPassword", "password": password])
    }

    func selectChat(_ id: Int64?) {
        selectedChatID = id
        media = []
        mediaError = nil
        isLoadingMedia = false
        canLoadMoreMedia = false
        historyRequestID = UUID()
        historyCursor = 0
        historyScanned = 0
        historyItems = [:]
        guard let id else { return }
        shouldContinueHistoryAutomatically = true
        requestHistory(chatID: id)
    }

    func refreshMedia() {
        selectChat(selectedChatID)
    }

    func loadMoreMedia() {
        guard let id = selectedChatID, !isLoadingMedia, canLoadMoreMedia else { return }
        shouldContinueHistoryAutomatically = true
        historyScanned = 0
        requestHistory(chatID: id)
    }

    func download(_ item: TelegramMedia) {
        guard selectedChatID != nil else { return }
        pendingDownloads[item.fileID] = item
        downloadStatus = String(format: translationText("telegram.download.starting"), item.name)
        send(["@type": "downloadFile", "file_id": item.fileID, "priority": 16,
              "offset": 0, "limit": 0, "synchronous": false, "@extra": "download"])
    }

    /// This only validates and records a plan. It deliberately performs no network work.
    func prepareUpload(exportDirectory: URL) throws -> TelegramUploadPlan {
        guard step == .ready, let chatID = selectedChatID else { throw TelegramClientError.invalidResponse }
        let plan = try TelegramUploadPlan.make(exportDirectory: exportDirectory, destinationChatID: chatID)
        let store = TelegramUploadReceiptStore(exportDirectory: exportDirectory)
        uploadPlan = plan; uploadDirectory = exportDirectory; uploadStore = store
        uploadReceipt = store.load(for: plan)
        return plan
    }

    /// The sole upload entry point. The view calls this only from its final confirmation action.
    func confirmPreparedUpload() {
        guard step == .ready, let plan = uploadPlan, plan.destinationChatID == selectedChatID,
              var receipt = uploadReceipt, let directory = uploadDirectory, pendingUploadName == nil else { return }
        do {
            let resolved = try plan.resolvedFiles(in: directory)
            guard let next = resolved.first(where: { !receipt.completedFileNames.contains($0.0.localName) && !receipt.submittedFileNames.contains($0.0.localName) }) else {
                if receipt.completedFileNames.count == plan.files.count { receipt.status = .completed; uploadReceipt = receipt; try uploadStore?.save(receipt) }
                return
            }
            receipt.markSending(next.0.localName)
            try uploadStore?.save(receipt); uploadReceipt = receipt; pendingUploadName = next.0.localName
            let json = try TelegramUploadRequestBuilder.sendMessage(plan: plan, file: next.0, resolvedURL: next.1)
            send(json)
        } catch {
            receipt.fail(error.localizedDescription)
            try? uploadStore?.save(receipt); uploadReceipt = receipt
        }
    }

    func cancelPreparedUpload() {
        guard var receipt = uploadReceipt else { return }
        receipt.cancel(); try? uploadStore?.save(receipt); uploadReceipt = receipt
        // An already submitted TDLib request is intentionally not re-issued on retry.
        pendingUploadName = nil
    }

    func stream(_ item: TelegramMedia) {
        guard ["mp4", "m4v", "mkv"].contains(item.type) else { return }
        do {
            let selection = try makeStreamSelection(item)
            downloadStatus = String(format: translationText("telegram.stream.starting"), item.name)
            NotificationCenter.default.post(name: .telegramStreamSelected, object: selection)
            for subtitle in media where subtitle.type == "srt" && Self.mediaStem(subtitle.name) == Self.mediaStem(item.name) {
                download(subtitle)
            }
        } catch { mediaError = error.localizedDescription }
    }

    func makeStreamSelection(_ item: TelegramMedia) throws -> TelegramStreamSelection {
        guard lanMedia.contains(item), ["mp4", "m4v", "mkv"].contains(item.type), item.size > 0 else {
            throw TelegramClientError.invalidResponse
        }
        let storage = try downloadDirectory().appendingPathComponent(URL(fileURLWithPath: item.name).lastPathComponent)
        return try TelegramStreamSelection(item: item, storageURL: storage, controller: self)
    }

    nonisolated static func mediaStem(_ name: String) -> String {
        var url = URL(fileURLWithPath: name).deletingPathExtension()
        while ["de", "ru", "en", "reviewed"].contains(url.pathExtension.lowercased()) { url.deletePathExtension() }
        return url.lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    func requestStreamRange(id: UUID, fileID: Int32, offset: Int64, length: Int,
                            completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        streamReads[fileID] = .init(id: id, offset: offset, length: length, completion: completion)
        send(["@type": "downloadFile", "file_id": fileID, "priority": 32,
              "offset": offset, "limit": length, "synchronous": false,
              "@extra": ["kind": "stream", "file_id": fileID, "request_id": id.uuidString]])
    }

    func cancelStreamRange(_ id: UUID) {
        if let entry = streamReads.first(where: { $0.value.id == id }) {
            streamReads[entry.key] = nil
            send(["@type": "cancelDownloadFile", "file_id": entry.key, "only_if_pending": false])
        }
    }

    func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        if clientID != nil { send(["@type": "close"]) }
        clientID = nil
        library = nil
        knownChats = [:]
        chats = []
        media = []
        mediaError = nil
        isLoadingMedia = false
        canLoadMoreMedia = false
        pendingDownloads = [:]
        pendingUploadName = nil
        streamReads.values.forEach { $0.completion(.failure(TelegramClientError.invalidResponse)) }
        streamReads = [:]
        if step != .idle { step = .idle }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(data)
    }

    private func send(_ data: Data) {
        guard let library, let clientID, let string = String(data: data, encoding: .utf8) else { return }
        string.withCString { library.send(clientID, $0) }
    }

    private func receive(_ json: String, credentials: TelegramCredentials) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        if let replyClientID = (object["@client_id"] as? NSNumber)?.int32Value, replyClientID != clientID { return }
        let type = object["@type"] as? String
        if type == "error" {
            let message = object["message"] as? String ?? translationText("telegram.error.response")
            if let extra = object["@extra"] as? [String: Any], extra["kind"] as? String == "stream",
               let fileID = (extra["file_id"] as? NSNumber)?.int32Value,
               let read = streamReads.removeValue(forKey: fileID) {
                read.completion(.failure(TelegramClientError.invalidResponse))
            } else if let extra = object["@extra"] as? [String: Any], extra["kind"] as? String == "upload" {
                finishUpload(name: extra["local_name"] as? String, error: message)
            } else if isCurrentHistoryResponse(object) {
                isLoadingMedia = false
                mediaError = message
            } else if isHistoryResponse(object) {
                // A reply for a chat that was deselected must not break authorization.
                return
            } else {
                step = .failed(message)
            }
            return
        }
        if type == "message", let extra = object["@extra"] as? [String: Any], extra["kind"] as? String == "upload" {
            finishUpload(name: extra["local_name"] as? String, error: nil)
            return
        }
        if type == "updateNewChat", let chat = object["chat"] as? [String: Any] {
            store(chat: chat)
            return
        }
        if type == "messages", isCurrentHistoryResponse(object) {
            receiveHistory(object)
            return
        }
        if type == "updateFile", let file = object["file"] as? [String: Any] {
            receiveFile(file)
            return
        }
        if type == "file", object["@extra"] as? String == "download" {
            receiveFile(object)
            return
        }
        if type == "file", let extra = object["@extra"] as? [String: Any], extra["kind"] as? String == "stream" {
            receiveFile(object)
            return
        }
        let state: [String: Any]?
        if type == "updateAuthorizationState" { state = object["authorization_state"] as? [String: Any] }
        else if type?.hasPrefix("authorizationState") == true { state = object }
        else { state = nil }
        guard let state, let stateType = state["@type"] as? String else { return }
        switch stateType {
        case "authorizationStateWaitTdlibParameters":
            if !didSendParameters {
                didSendParameters = true
                sendParameters(credentials)
            }
        case "authorizationStateWaitPhoneNumber": step = .phone
        case "authorizationStateWaitCode": step = .code
        case "authorizationStateWaitPassword": step = .password
        case "authorizationStateReady":
            step = .ready
            send(["@type": "loadChats", "chat_list": ["@type": "chatListMain"], "limit": 100])
        case "authorizationStateClosed": stop()
        default: step = .failed(String(format: translationText("telegram.error.unsupportedState"), stateType))
        }
    }

    private func finishUpload(name: String?, error: String?) {
        guard let plan = uploadPlan, var receipt = uploadReceipt, let name, name == pendingUploadName else { return }
        pendingUploadName = nil
        if let error { receipt.fail(error, retrying: name) }
        else { receipt.markCompleted(name, total: plan.files.count) }
        try? uploadStore?.save(receipt); uploadReceipt = receipt
        if error == nil, receipt.status != .completed { confirmPreparedUpload() }
    }

    private func sendParameters(_ credentials: TelegramCredentials) {
        do {
            let root = try Self.dataDirectory()
            let database = root.appendingPathComponent("database", isDirectory: true)
            let files = root.appendingPathComponent("files", isDirectory: true)
            try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            send([
                "@type": "setTdlibParameters",
                "use_test_dc": false,
                "database_directory": database.path,
                "files_directory": files.path,
                "database_encryption_key": "",
                "use_file_database": true,
                "use_chat_info_database": true,
                "use_message_database": true,
                "use_secret_chats": false,
                "api_id": credentials.apiID,
                "api_hash": credentials.apiHash,
                "system_language_code": Locale.current.identifier,
                "device_model": "Mac",
                "system_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "application_version": "Preview"
            ])
        } catch { step = .failed(error.localizedDescription) }
    }

    private func store(chat: [String: Any]) {
        let id = (chat["id"] as? NSNumber)?.int64Value ?? (chat["id"] as? String).flatMap(Int64.init)
        guard let id, let title = chat["title"] as? String else { return }
        let type = (chat["type"] as? [String: Any])?["@type"] as? String ?? ""
        guard type == "chatTypeSupergroup" || type == "chatTypeBasicGroup" || type == "chatTypePrivate" else { return }
        knownChats[id] = TelegramChat(id: id, title: title, kind: type)
        chats = knownChats.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func requestHistory(chatID: Int64) {
        isLoadingMedia = true
        mediaError = nil
        send(["@type": "getChatHistory", "chat_id": chatID, "from_message_id": historyCursor,
              "offset": 0, "limit": Self.historyPageSize, "only_local": false,
              "@extra": ["kind": "history", "chat_id": chatID, "request_id": historyRequestID.uuidString]])
    }

    private func isCurrentHistoryResponse(_ object: [String: Any]) -> Bool {
        guard isHistoryResponse(object) else { return false }
        let extra = object["@extra"] as? [String: Any] ?? [:]
        guard let chatID = (extra["chat_id"] as? NSNumber)?.int64Value,
              let requestID = extra["request_id"] as? String else { return false }
        return chatID == selectedChatID && requestID == historyRequestID.uuidString
    }

    private func isHistoryResponse(_ object: [String: Any]) -> Bool {
        guard let extra = object["@extra"] as? [String: Any],
              extra["kind"] as? String == "history" else { return false }
        return true
    }

    private func receiveHistory(_ object: [String: Any]) {
        guard let chatID = selectedChatID else { return }
        let messages = object["messages"] as? [[String: Any]] ?? []
        let messageIDs = messages.compactMap { ($0["id"] as? NSNumber)?.int64Value }
        for item in messages.compactMap(Self.parseMedia) { historyItems[item.id] = item }
        media = historyItems.values.sorted { $0.id > $1.id }
        historyScanned += messages.count

        guard let oldestID = messageIDs.min(), !messages.isEmpty, oldestID > 1 else {
            isLoadingMedia = false
            canLoadMoreMedia = false
            return
        }
        let nextCursor = oldestID - 1
        guard nextCursor != historyCursor else {
            isLoadingMedia = false
            canLoadMoreMedia = false
            return
        }
        historyCursor = nextCursor
        canLoadMoreMedia = true
        if shouldContinueHistoryAutomatically && historyScanned < Self.automaticHistoryLimit {
            requestHistory(chatID: chatID)
        } else {
            shouldContinueHistoryAutomatically = false
            isLoadingMedia = false
        }
    }

    nonisolated static func parseMedia(_ message: [String: Any]) -> TelegramMedia? {
        let content = message["content"] as? [String: Any] ?? [:]
        let type = content["@type"] as? String ?? ""
        let attachment: [String: Any]
        let file: [String: Any]
        if type == "messageVideo" {
            attachment = content["video"] as? [String: Any] ?? [:]
            file = attachment["video"] as? [String: Any] ?? [:]
        } else if type == "messageDocument" {
            attachment = content["document"] as? [String: Any] ?? [:]
            file = attachment["document"] as? [String: Any] ?? [:]
        } else { return nil }
        guard let fileID = (file["id"] as? NSNumber)?.int32Value,
              let messageID = (message["id"] as? NSNumber)?.int64Value else { return nil }
        let suppliedName = attachment["file_name"] as? String ?? ""
        let name: String
        if suppliedName.isEmpty, type == "messageVideo" {
            let timestamp = (message["date"] as? NSNumber)?.int64Value ?? 0
            name = "Telegram video \(timestamp).mp4"
        } else {
            name = suppliedName
        }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard ["mp4", "m4v", "mkv", "srt"].contains(ext) else { return nil }
        return TelegramMedia(id: messageID, fileID: fileID, name: name,
                             size: max((file["size"] as? NSNumber)?.int64Value ?? 0,
                                       (file["expected_size"] as? NSNumber)?.int64Value ?? 0), type: ext)
    }

    private func receiveFile(_ file: [String: Any]) {
        guard let id = (file["id"] as? NSNumber)?.int32Value,
              let local = file["local"] as? [String: Any] else { return }
        fulfillStreamRead(fileID: id, local: local)
        guard let item = pendingDownloads[id] else { return }
        guard local["is_downloading_completed"] as? Bool == true,
              let path = local["path"] as? String, !path.isEmpty else { return }
        pendingDownloads[id] = nil
        do {
            let saved = try publishDownloadedFile(at: URL(fileURLWithPath: path), named: item.name)
            downloadStatus = String(format: translationText("telegram.download.saved"), saved.lastPathComponent)
            NotificationCenter.default.post(name: .telegramFileDownloaded, object: saved)
        } catch { downloadStatus = error.localizedDescription }
    }

    private func fulfillStreamRead(fileID: Int32, local: [String: Any]) {
        guard let read = streamReads[fileID],
              let path = local["path"] as? String, !path.isEmpty else { return }
        let offset = (local["download_offset"] as? NSNumber)?.int64Value ?? 0
        let prefix = (local["downloaded_prefix_size"] as? NSNumber)?.int64Value ?? 0
        let complete = local["is_downloading_completed"] as? Bool == true
        let end = complete ? Int64.max : offset + prefix
        guard read.offset >= offset, read.offset + Int64(read.length) <= end else { return }
        streamReads[fileID] = nil
        Task.detached(priority: .userInitiated) {
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(read.offset))
                let data = try handle.read(upToCount: read.length) ?? Data()
                guard data.count == read.length else { throw TelegramClientError.invalidResponse }
                read.completion(.success(data))
            } catch { read.completion(.failure(error)) }
        }
    }

    private func publishDownloadedFile(at source: URL, named name: String) throws -> URL {
        let base = try downloadDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let safeName = URL(fileURLWithPath: name).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else { throw TelegramClientError.invalidResponse }
        let target = base.appendingPathComponent(safeName)
        let stem = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        let destination = (0...999).map { index -> URL in
            index == 0 ? target : base.appendingPathComponent("\(stem) \(index).\(ext)")
        }.first { !FileManager.default.fileExists(atPath: $0.path) }
        guard let destination else { throw TelegramClientError.invalidResponse }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func downloadDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .moviesDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("Lektien Telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func dataDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("LektienPlayer/Telegram", isDirectory: true)
    }
}

extension Notification.Name {
    static let telegramFileDownloaded = Notification.Name("LektienTelegramFileDownloaded")
    static let telegramStreamSelected = Notification.Name("LektienTelegramStreamSelected")
}
