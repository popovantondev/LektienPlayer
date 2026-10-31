import AppKit
import Combine
import SwiftUI
import PlayerCore
import PlayerLAN
import CoreImage.CIFilterBuiltins

@MainActor
final class NetworkController: ObservableObject {
    @Published var folder: URL?
    @Published var port = "41870"
    @Published private(set) var links: [URL] = []
    @Published private(set) var code = ""
    @Published private(set) var preparing = false
    @Published private(set) var active = false
    @Published private(set) var viewerActive = false
    @Published private(set) var error: String?
    @Published private(set) var count = 0
    @Published private(set) var localCount = 0
    var telegram: TelegramController { .shared }
    var macBusy: () -> Bool = { false }
    private var processor: NetworkPreparation?
    private var telegramSource: TelegramLANSource?
    private var server: LocalLibraryServer?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var viewerGeneration = UUID()

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        if panel.runModal() == .OK { folder = panel.url }
    }
    func start() {
        let telegramController = telegram
        guard Self.canStart(folderSelected: folder != nil, telegramChannelSelected: telegram.lanChatID != nil) else {
            error = translationText("network.noSource"); return
        }
        guard let port = UInt16(port), port >= 1024 else {
            error = translationText("network.invalidPort"); return
        }
        stop(); preparing = true; error = nil
        let token = generation
        let selectedFolder = folder
        let libraryManifest = LibraryQueueController.shared.store.snapshot()
        task = Task { [weak self] in
            do {
                let library = try await Task.detached(priority: .utility) {
                    if let selectedFolder { return try SharedLibrary(directory: selectedFolder, manifest: libraryManifest) }
                    return SharedLibrary.empty()
                }.value
                guard let self, token == generation, !Task.isCancelled else { return }
                let telegramSource = TelegramLANSource(controller: telegramController)
                let processor = NetworkPreparation(library: library, telegram: telegramSource)
                self.telegramSource = telegramSource
                processor.failure = { [weak self] error in self?.error = error }
                processor.macBusy = { [weak self] in self?.macBusy() ?? true }
                processor.viewerActivity = { [weak self] in self?.noteViewerActivity() }
                self.processor = processor
                let server = LocalLibraryServer(library: library) { [weak processor] path, body in
                    guard let processor else { return .init(status: 503) }
                    return await processor.handle(path, body: body)
                }
                self.server = server; localCount = library.lectures.count
                count = library.lectures.count + telegramSource.catalog().count
                try server.start(port: port) { [weak self, weak server] result in
                    Task { @MainActor [weak self, weak server] in
                        guard let self, let server, token == self.generation else { return }
                        self.preparing = false
                        switch result {
                        case .success(let port):
                            self.active = true; self.code = server.code
                            self.links = (server.addresses + ["127.0.0.1"]).compactMap { URL(string: "http://\($0):\(port)/#\(server.code)") }
                        case .failure(let error):
                            self.error = error.localizedDescription; self.stop()
                        }
                    }
                }
            } catch {
                guard let self, token == generation else { return }
                self.error = error.localizedDescription; preparing = false
            }
        }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        processor?.stop(); processor = nil
        telegramSource?.stop(); telegramSource = nil
        server?.stop(); server = nil
        links = []; code = ""; count = 0; localCount = 0; preparing = false; active = false
        viewerGeneration = UUID(); viewerActive = false
    }
    deinit { task?.cancel(); server?.stop() }

    static func canStart(folderSelected: Bool, telegramChannelSelected: Bool) -> Bool {
        folderSelected || telegramChannelSelected
    }

    private func noteViewerActivity() {
        let token = UUID(); viewerGeneration = token; viewerActive = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, viewerGeneration == token else { return }
            viewerActive = false
        }
    }
}

struct NetworkView: View {
    @ObservedObject var controller: NetworkController
    @ObservedObject private var telegram = TelegramController.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    private func text(_ key: String) -> String { translationText(key) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(text("network.title")).font(.title2)
            Text(text("network.scope")).foregroundStyle(.secondary)
            GroupBox(text("network.localSource")) {
                HStack {
                    Text(controller.folder?.path ?? text("network.noFolder")).lineLimit(2).truncationMode(.middle)
                    Spacer()
                    Button(text("network.choose")) { controller.chooseFolder() }.disabled(controller.active || controller.preparing)
                }
                    Text(String(format: text("network.localCount"), controller.localCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
            GroupBox(text("network.telegramSource")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(telegramStatus).foregroundStyle(.secondary)
                    HStack {
                        Button(text("network.connectTelegram")) { openWindow(id: "telegram-settings") }
                        Button(text("network.chooseChannel")) { openWindow(id: "telegram-settings") }
                    }
                }
            }
            if let receipt = telegram.uploadReceipt {
                GroupBox(text("network.telegramUploadStatus")) {
                    Text(text("telegram.upload.status.\(receipt.status.rawValue)"))
                        .foregroundStyle(receipt.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
            HStack {
                Text(text("network.port"))
                TextField("41870", text: $controller.port).frame(width: 100).disabled(controller.active || controller.preparing)
                Spacer()
                if controller.active || controller.preparing {
                    Button(text("network.stop")) { controller.stop() }
                } else {
                    Button(text("network.start")) { controller.start() }.disabled(!NetworkController.canStart(folderSelected: controller.folder != nil, telegramChannelSelected: telegram.lanChatID != nil))
                }
            }
            if controller.folder == nil && telegram.lanChatID == nil {
                Text(text("network.noSource")).foregroundStyle(.secondary)
            }
            if controller.preparing { ProgressView() }
            if controller.active {
                Text(String(format: text("network.count"), controller.count))
                if let url = controller.links.first(where: { $0.host != "127.0.0.1" }), let qr = qrCode(url) {
                    HStack {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 130, height: 130)
                            .padding(8).background(.white).accessibilityLabel(text("network.scan"))
                        Text(text("network.scan")).foregroundStyle(.secondary)
                    }
                }
                ForEach(controller.links, id: \.absoluteString) { url in
                    HStack {
                        Text(url.absoluteString.components(separatedBy: "#")[0]).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        if url.host == "127.0.0.1" { Text(text("network.thisMac")).foregroundStyle(.secondary) }
                        Spacer()
                        Button(text("network.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
                        Button(text("network.open")) { NSWorkspace.shared.open(url) }
                    }
                }
                HStack {
                    Text(text("network.code"))
                    Text(controller.code).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button(text("network.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(controller.code, forType: .string) }
                }
            }
            if let error = controller.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text(text("network.firewall")).font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button(text("network.close")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 650)
    }
    private var telegramStatus: String {
        guard telegram.step == .ready else { return text("network.telegramNotConnected") }
        guard let chatID = telegram.lanChatID,
              let chat = telegram.chats.first(where: { $0.id == chatID }) else { return text("network.telegramNoChannel") }
        return String(format: text("network.telegramSelected"), chat.title, telegram.lanMedia.filter { ["mp4", "m4v", "mkv"].contains($0.type) }.count)
    }
    private func qrCode(_ url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 4, y: 4)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
