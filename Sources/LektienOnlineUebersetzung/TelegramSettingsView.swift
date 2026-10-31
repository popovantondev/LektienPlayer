import PlayerCore
import SwiftUI

struct TelegramSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppLocalization.preferenceKey) private var language: InterfaceLanguage = .german
    @State private var apiID = ""
    @State private var apiHash = ""
    @State private var hasSavedCredentials = false
    @State private var message: String?
    @State private var isFailure = false
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var selectedChatID: Int64?
    @StateObject private var telegram = TelegramController.shared

    private let store = TelegramCredentialsStore()

    var body: some View {
        NavigationStack {
            Form {
                Section(translationText("telegram.credentials.title")) {
                    TextField(translationText("telegram.apiID"), text: $apiID)
                    SecureField(translationText("telegram.apiHash"), text: $apiHash)
                    Text(translationText("telegram.credentials.help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(translationText("telegram.login.title")) {
                    if hasSavedCredentials {
                        Label(translationText("telegram.credentials.saved"), systemImage: "key.fill")
                            .foregroundStyle(.teal)
                        loginControls
                    } else {
                        Text(translationText("telegram.login.missing"))
                            .foregroundStyle(.secondary)
                    }
                }
                if telegram.step == .ready {
                    Section(translationText("telegram.chats.title")) {
                        if telegram.chats.isEmpty {
                            ProgressView(translationText("telegram.chats.loading"))
                        } else {
                            Picker(translationText("telegram.chats.choose"), selection: $selectedChatID) {
                                Text(translationText("telegram.chats.none")).tag(Int64?.none)
                                ForEach(telegram.chats) { chat in Text(chat.title).tag(Optional(chat.id)) }
                            }
                            Text(translationText("telegram.chats.next"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if selectedChatID != nil {
                        Section(translationText("telegram.media.title")) {
                            if telegram.isLoadingMedia && telegram.media.isEmpty {
                                ProgressView(translationText("telegram.media.loading"))
                            } else if telegram.media.isEmpty {
                                Text(translationText("telegram.media.empty"))
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(telegram.media) { item in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(item.name).lineLimit(2)
                                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if ["mp4", "m4v", "mkv"].contains(item.type) {
                                            Button(translationText("telegram.watch")) { telegram.stream(item) }
                                        }
                                        Button(translationText("telegram.download")) { telegram.download(item) }
                                    }
                                }
                            }
                            if telegram.isLoadingMedia && !telegram.media.isEmpty {
                                ProgressView(translationText("telegram.media.loadingMore"))
                            } else {
                                HStack {
                                    Button(translationText("telegram.media.refresh")) { telegram.refreshMedia() }
                                    if telegram.canLoadMoreMedia {
                                        Button(translationText("telegram.media.more")) { telegram.loadMoreMedia() }
                                    }
                                }
                            }
                            if let error = telegram.mediaError {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                            if !telegram.downloadStatus.isEmpty {
                                Text(telegram.downloadStatus).font(.caption)
                            }
                        }
                    }
                }
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(isFailure ? .red : .teal)
                }
            }
            .formStyle(.grouped)
            .id(language)
            .navigationTitle(translationText("telegram.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if hasSavedCredentials {
                        Button(translationText("telegram.remove"), role: .destructive, action: removeCredentials)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(translationText("telegram.save"), action: saveCredentials)
                        .disabled(apiID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiHash.isEmpty)
                }
                ToolbarItem(placement: .automatic) {
                    Button(translationText("common.done")) { dismiss() }
                }
            }
        }
        .frame(width: 560, height: 520)
        .task { await loadCredentials() }
        .onChange(of: selectedChatID) { _, id in telegram.selectChat(id) }
    }

    @ViewBuilder private var loginControls: some View {
        switch telegram.step {
        case .idle:
            Button(translationText("telegram.login.connect"), action: connect)
        case .starting:
            ProgressView(translationText("telegram.login.starting"))
        case .phone:
            TextField(translationText("telegram.phone"), text: $phone)
            Button(translationText("telegram.continue")) { telegram.submitPhone(phone) }
                .disabled(phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .code:
            TextField(translationText("telegram.code"), text: $code)
            Button(translationText("telegram.continue")) { telegram.submitCode(code) }
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .password:
            SecureField(translationText("telegram.password"), text: $password)
            Button(translationText("telegram.continue")) { telegram.submitPassword(password) }
                .disabled(password.isEmpty)
        case .ready:
            Label(translationText("telegram.login.ready"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.teal)
        case .unavailable(let reason), .failed(let reason):
            Text(reason).foregroundStyle(.red)
            Button(translationText("telegram.retry"), action: connect)
        }
    }

    private func loadCredentials() async {
        do {
            let store = store
            guard let credentials = try await Task.detached(priority: .userInitiated, operation: store.load).value else { return }
            apiID = String(credentials.apiID)
            apiHash = credentials.apiHash
            hasSavedCredentials = true
        } catch { show(error) }
    }

    private func saveCredentials() {
        do {
            try store.save(.validated(apiID: apiID, apiHash: apiHash))
            hasSavedCredentials = true
            isFailure = false
            message = translationText("telegram.credentials.saved")
        } catch { show(error) }
    }

    private func connect() {
        do { telegram.start(credentials: try TelegramCredentials.validated(apiID: apiID, apiHash: apiHash)) }
        catch { show(error) }
    }

    private func removeCredentials() {
        do {
            telegram.stop()
            try store.removeAll()
            apiID = ""; apiHash = ""; hasSavedCredentials = false
            isFailure = false
            message = translationText("telegram.credentials.removed")
        } catch { show(error) }
    }

    private func show(_ error: Error) {
        isFailure = true
        message = error.localizedDescription
    }
}
