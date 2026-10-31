import SwiftUI

struct AudioMixerView: View {
    @ObservedObject var playback: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(translationText("mixer.title")).font(.headline)
            Text(translationText("mixer.help")).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(playback.embeddedAudioTracks) { track in
                        volumeRow(title: track.title,
                                  enabled: Binding(get: { track.enabled }, set: { playback.setAudioEnabled(track.id, $0) }),
                                  volume: Binding(get: { track.volume }, set: { playback.setAudioVolume(track.id, $0) }))
                    }
                    if !playback.audioMixReady {
                        Text(translationText("mixer.unavailable")).font(.caption).foregroundStyle(.secondary)
                        Picker(translationText("player.audio"), selection: Binding(get: { playback.selectedAudioTrack }, set: { playback.selectAudio($0) })) {
                            ForEach(playback.audioTracks) { Text($0.title).tag($0.id) }
                        }
                        .disabled(playback.audioTracks.isEmpty)
                    }
                    Divider()
                    volumeRow(title: translationText("mixer.kseniya"), enabled: $playback.russianVoiceEnabled, volume: $playback.russianVolume)
                        .disabled(!playback.hasRussianVoice)
                    if !playback.hasRussianVoice {
                        Text(translationText("mixer.needsSpeech")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: min(330, CGFloat(max(1, playback.embeddedAudioTracks.count) * 66 + 120)))
            Divider()
            Toggle(translationText("audio.duck"), isOn: $playback.duckingEnabled)
            HStack {
                Text(translationText("audio.duckLevel")).font(.caption)
                Slider(value: $playback.duckingLevel, in: 0...0.7)
                Text("\(Int((playback.duckingLevel * 100).rounded()))%").font(.caption).monospacedDigit()
            }.disabled(!playback.duckingEnabled)
            Text(translationText("mixer.master")).font(.caption)
            Slider(value: $playback.volume, in: 0...1)
                .accessibilityLabel(translationText("mixer.master"))
        }
        .padding(20)
        .frame(width: 350)
    }

    private func volumeRow(title: String, enabled: Binding<Bool>, volume: Binding<Double>) -> some View {
        VStack(spacing: 5) {
            HStack {
                Toggle(title, isOn: enabled)
                Spacer()
                Text("\(Int((volume.wrappedValue * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: volume, in: 0...1)
                .disabled(!enabled.wrappedValue)
                .accessibilityLabel(String(format: translationText("mixer.trackVolume"), title))
        }
    }
}
