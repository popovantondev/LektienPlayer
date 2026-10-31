import AVFoundation
import SwiftUI
import PlayerSpeech
import PlayerCore
import PlayerMedia

struct PronunciationView: View {
    let video: URL
    let saved: () -> Void
    let pausePlayback: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var dictionary = ""
    @State private var initialDictionary = ""
    @State private var sample = "Кремний влияет на метаболизм. Дверной замок закрыт, а на холме стоит старинный замок."
    @State private var error: String?
    @State private var loaded = false
    @StateObject private var preview = PronunciationPreview()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(translationText("pronunciation.title")).font(.title2)
            Text(translationText("pronunciation.help")).font(.callout)
            Text("кремний => кр+емний\nдверной замок => дверной зам+ок\nстаринный замок => старинный з+амок")
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            TextEditor(text: $dictionary).font(.system(.body, design: .monospaced))
                .frame(minHeight: 150).border(.secondary.opacity(0.3))
                .accessibilityLabel(translationText("pronunciation.dictionary"))
            Text(translationText("pronunciation.sample")).font(.headline)
            TextField(translationText("pronunciation.sample"), text: $sample, axis: .vertical).lineLimit(2...4)
            HStack {
                Button(translationText(preview.preparing ? "pronunciation.stop" : "pronunciation.listen")) {
                    if preview.preparing { preview.stop() } else {
                        pausePlayback()
                        preview.start(text: sample, dictionary: dictionary, video: video)
                    }
                }.disabled(!loaded || sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if preview.preparing { ProgressView().controlSize(.small) }
                if !preview.preparing {
                    Button(translationText("pronunciation.stop")) { preview.stop() }
                }
            }
            Text(translationText("pronunciation.storage")).font(.caption).foregroundStyle(.secondary)
            if let message = error ?? preview.error { Text(message).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button(translationText("recognition.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(translationText("pronunciation.save")) {
                    do {
                        if dictionary != initialDictionary {
                            try SpeechPronunciation.save(dictionary, video: video)
                            preview.stop(); saved()
                        }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.disabled(!loaded).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620, height: 590)
            .onAppear {
                do {
                    dictionary = try SpeechPronunciation.customText(video: video)
                    initialDictionary = dictionary; loaded = true
                }
                catch { self.error = error.localizedDescription }
            }
            .onDisappear { preview.stop() }
    }
}

@MainActor
private final class PronunciationPreview: ObservableObject {
    @Published var preparing = false
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var cancellation: SpeechCancellation?
    private var audio: AVAudioPlayer?
    private var generation = UUID()

    func start(text: String, dictionary: String, video: URL) {
        stop(); error = nil
        let token = generation
        let control = SpeechCancellation(); cancellation = control
        preparing = true
        task = Task {
            do {
                let rules = try SpeechPronunciation.withCustomText(dictionary, video: video)
                let document = try SubtitleDocument(cues: [.init(identifier: 1, start: 0, end: 30, text: text)])
                let srt = MediaPublication.srt(document)
                let result = try await Task.detached {
                    try SpeechSession.run(srt: srt, videoURL: video, voice: "kseniya", cancellation: control,
                        pronunciation: rules, progress: { _, _ in })
                }.value
                guard generation == token else { return }
                audio = try AVAudioPlayer(contentsOf: result.audioURL)
                audio?.play()
            } catch {
                guard generation == token else { return }
                self.error = error.localizedDescription
            }
            guard generation == token else { return }
            preparing = false; cancellation = nil
        }
    }

    func stop() {
        generation = UUID(); task?.cancel(); cancellation?.cancel(); audio?.stop()
        task = nil; cancellation = nil; audio = nil; preparing = false
    }

    deinit { task?.cancel(); cancellation?.cancel() }
}
