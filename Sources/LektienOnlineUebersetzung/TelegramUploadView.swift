import PlayerCore
import SwiftUI

/// A review screen between local export and the explicit network action.
struct TelegramUploadView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var telegram = TelegramController.shared
    let exportDirectory: URL
    @State private var plan: TelegramUploadPlan?
    @State private var error: String?
    @State private var confirmsSend = false

    var body: some View {
        NavigationStack {
            Group {
                if let plan {
                    List {
                        Section(translationText("telegram.upload.destination")) {
                            Text(String(plan.destinationChatID)).textSelection(.enabled)
                        }
                        Section(translationText("telegram.upload.files")) {
                            ForEach(plan.files) { file in
                                HStack {
                                    Text(file.localName)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Section(translationText("telegram.upload.check")) {
                            Label(translationText("telegram.upload.localOnly"), systemImage: "checkmark.shield")
                            if let receipt = telegram.uploadReceipt {
                                Text(statusText(receipt)).foregroundStyle(receipt.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            }
                        }
                    }
                } else if let error {
                    ContentUnavailableView(translationText("telegram.upload.unavailable"), systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(translationText("telegram.upload.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(translationText("recognition.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(translationText("telegram.upload.confirm")) { confirmsSend = true }
                        .disabled(plan == nil || telegram.uploadReceipt?.status == .completed)
                }
                if telegram.uploadReceipt?.status == .sending {
                    ToolbarItem(placement: .automatic) {
                        Button(translationText("telegram.upload.cancel"), role: .destructive) { telegram.cancelPreparedUpload() }
                    }
                }
            }
            .alert(translationText("telegram.upload.confirmTitle"), isPresented: $confirmsSend) {
                Button(translationText("recognition.cancel"), role: .cancel) {}
                Button(translationText("telegram.upload.confirm")) { telegram.confirmPreparedUpload() }
            } message: {
                Text(translationText("telegram.upload.confirmMessage"))
            }
            .task {
                do { plan = try telegram.prepareUpload(exportDirectory: exportDirectory) }
                catch { self.error = error.localizedDescription }
            }
        }
        .frame(width: 540, height: 430)
    }

    private func statusText(_ receipt: TelegramUploadReceipt) -> String {
        let key = "telegram.upload.status.\(receipt.status.rawValue)"
        return receipt.error.map { "\(translationText(key)): \($0)" } ?? translationText(key)
    }
}
