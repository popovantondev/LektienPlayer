import SwiftUI
import PlayerMedia

struct RecognitionSourceSelection: Identifiable {
    let id = UUID()
    let video: URL
    let mediaURL: URL?
    let inspection: MediaInspection

    init(video: URL, mediaURL: URL? = nil, inspection: MediaInspection) {
        self.video = video; self.mediaURL = mediaURL; self.inspection = inspection
    }
}

struct RecognitionSourceView: View {
    let selection: RecognitionSourceSelection
    let prepare: (MediaStream, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var streamIndex = -1
    @State private var translates = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(translationText("recognition.title")).font(.title2)
            Text(translationText("recognition.explanation")).fixedSize(horizontal: false, vertical: true)
            Picker(translationText("recognition.source"), selection: $streamIndex) {
                ForEach(selection.inspection.textSubtitles) { stream in
                    Text("SRT · " + stream.title).tag(stream.index)
                }
                ForEach(selection.inspection.audio) { stream in
                    Text(translationText("recognition.audio") + " · " + stream.title).tag(stream.index)
                }
            }
            Toggle(translationText("recognition.translate"), isOn: $translates)
            Text(translationText("recognition.saving")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(translationText("recognition.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(translationText("recognition.start")) {
                    guard let stream = selection.inspection.streams.first(where: { $0.index == streamIndex }) else { return }
                    dismiss(); prepare(stream, translates)
                }.keyboardShortcut(.defaultAction).disabled(streamIndex < 0)
            }
        }.padding(24).frame(width: 520)
            .onAppear {
                streamIndex = (selection.inspection.textSubtitles.first { $0.isGerman }
                    ?? selection.inspection.audio.first { $0.isGerman }
                    ?? selection.inspection.textSubtitles.first
                    ?? selection.inspection.audio.first)?.index ?? -1
            }
    }
}
