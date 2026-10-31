import AppKit
import PlayerCore
import SwiftUI

/// This window deliberately exposes only cache categories that can be rebuilt.
/// It never lists neighbouring media or the durable `.lektien` records.
struct LibraryCacheView: View {
    let library: URL
    @ObservedObject var controller: LibraryQueueController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsCleanup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(translationText("cache.title")).font(.title2.bold())
            Text(translationText("cache.explanation")).foregroundStyle(.secondary)
            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            GroupBox(translationText("cache.location")) {
                HStack {
                    Text(controller.cacheDirectory(for: library).path)
                        .lineLimit(2).truncationMode(.middle).font(.caption)
                    Spacer()
                    Button(translationText("cache.choose"), action: chooseDirectory)
                }.padding(.vertical, 2)
            }
            HStack {
                Text(translationText("cache.total"))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: controller.cacheUsage.totalBytes, countStyle: .file))
                    .monospacedDigit()
            }
            List {
                ForEach(DerivedCacheInspector.recoverableCategories.sorted(), id: \.self) { category in
                    HStack {
                        Text(translationText("cache.category.\(category)"))
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: controller.cacheUsage.categories[category] ?? 0, countStyle: .file))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            Text(translationText("cache.safeOnly")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(translationText("library.close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(translationText("cache.clear"), role: .destructive) { confirmsCleanup = true }
                    .disabled(DerivedCacheInspector.safeCleanupPlan(at: controller.cacheDirectory(for: library)).isEmpty)
            }
        }
        .padding(20).frame(minWidth: 580, minHeight: 460)
        .onAppear { controller.refresh(directory: library) }
        .alert(translationText("cache.confirmTitle"), isPresented: $confirmsCleanup) {
            Button(translationText("cache.clear"), role: .destructive) { controller.clearRecoverableCache(for: library) }
            Button(translationText("export.cancel"), role: .cancel) {}
        } message: { Text(translationText("cache.confirmMessage")) }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = controller.cacheDirectory(for: library)
        panel.prompt = translationText("cache.choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.chooseCacheDirectory(url, for: library)
    }
}
