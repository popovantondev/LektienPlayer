import SwiftUI
import PlayerMedia
import PlayerExport

struct VideoExportSelection: Identifiable {
    let id = UUID()
    let source: URL
    let inspection: MediaInspection
    let hasGerman: Bool
    let germanAudio: Int?
}

struct VideoExportView: View {
    let selection: VideoExportSelection
    let confirm: (VideoExportRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var container: VideoExportRequest.Container = .mp4
    @State private var originals = Set<Int>()
    @State private var german = true
    @State private var russian = true
    @State private var defaultAudio = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(translationText("export.video")).font(.title2)
            Text(translationText("export.videoExplanation")).font(.callout).fixedSize(horizontal: false, vertical: true)
            Picker(translationText("export.container"), selection: $container) {
                if VideoExport.supportsMP4(selection.inspection) { Text("MP4").tag(VideoExportRequest.Container.mp4) }
                Text("MKV").tag(VideoExportRequest.Container.mkv)
            }
            Text(translationText("export.originalTracks")).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("✓ Kseniya · RU")
                    ForEach(selection.inspection.audio) { stream in
                        Toggle(stream.title, isOn: Binding(get: { originals.contains(stream.index) }, set: { enabled in
                            if enabled { originals.insert(stream.index) } else {
                                originals.remove(stream.index)
                                if defaultAudio == stream.index { defaultAudio = -1 }
                            }
                        }))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 130)
            Picker(translationText("export.defaultAudio"), selection: $defaultAudio) {
                Text("Kseniya · RU").tag(-1)
                ForEach(selection.inspection.audio.filter { originals.contains($0.index) }) { stream in
                    Text(stream.title).tag(stream.index)
                }
            }
            HStack {
                Text(translationText("export.subtitleTracks"))
                Toggle("RU", isOn: $russian)
                if selection.hasGerman { Toggle("DE", isOn: $german) }
            }
            HStack {
                Spacer()
                Button(translationText("recognition.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(translationText("export.chooseFolder")) {
                    confirm(.init(source: selection.source, container: container, originalAudio: originals.sorted(),
                        subtitles: (russian ? ["ru"] : []) + (german && selection.hasGerman ? ["de"] : []),
                        defaultAudio: defaultAudio == -1 ? nil : defaultAudio, germanAudio: selection.germanAudio))
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540)
            .onAppear {
                originals = Set(selection.inspection.audio.map(\.index))
                if !VideoExport.supportsMP4(selection.inspection) { container = .mkv }
            }
    }
}
