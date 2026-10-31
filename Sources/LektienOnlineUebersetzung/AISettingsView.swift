import SwiftUI
import PlayerCore

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @AppStorage("translation.model") private var translationModel = "Luna"
    @AppStorage("translation.effort") private var reasoningEffort = "Среднее"
    @AppStorage("review.model") private var reviewModel = "Terra"
    @AppStorage("review.effort") private var reviewEffort = "Среднее"

    @AppStorage("speech.bufferMinutes") private var bufferMinutes = 6.0
    @AppStorage("speech.pausedMinutes") private var pausedMinutes = 10.0
    @AppStorage("player.autoHide") private var autoHide = true
    @AppStorage("player.controlsMode") private var controlsMode: PlayerControlsMode = .sliding

    @AppStorage(AppLocalization.preferenceKey) private var language: InterfaceLanguage = .german
    @AppStorage("player.panelOpacity") private var opacity = 0.85
    @AppStorage("player.fullscreenFill") private var fullscreenFill = true
    @AppStorage("player.videoUnderHeader") private var videoUnderHeader = false

    var body: some View {
        NavigationStack {
            Form {
                Section(translationText("language.title")) {
                    Picker(translationText("language.interface"), selection: $language) {
                        ForEach(InterfaceLanguage.allCases, id: \.self) { Text($0.nativeName).tag($0) }
                    }.pickerStyle(.radioGroup)
                    Text(translationText("language.independent")).font(.caption).foregroundStyle(.secondary)
                }
                Section(translationText("settings.translationTitle")) {
                    Picker(translationText("settings.model"), selection: $translationModel) {
                        Text("Luna").tag("Luna")
                        Text("Terra").tag("Terra")
                        Text("Astra").tag("Astra")
                    }
                    Picker(translationText("settings.effort"), selection: $reasoningEffort) {
                        Text(translationText("effort.low")).tag("Лёгкие")
                        Text(translationText("effort.medium")).tag("Среднее")
                        Text(translationText("effort.high")).tag("Высокие")
                    }
                    Text(translationText("settings.translation"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(translationText("review.title")) {
                    Picker(translationText("settings.model"), selection: $reviewModel) {
                        Text("Terra").tag("Terra")
                        Text("Luna").tag("Luna")
                        Text("Astra").tag("Astra")
                    }
                    Picker(translationText("settings.effort"), selection: $reviewEffort) {
                        Text(translationText("effort.low")).tag("Лёгкие")
                        Text(translationText("effort.medium")).tag("Среднее")
                        Text(translationText("effort.high")).tag("Высокие")
                    }
                    Text(translationText("review.help")).font(.caption).foregroundStyle(.secondary)
                }

                Section(translationText("buffer.settings")) {
                    Picker(translationText("buffer.playing"), selection: $bufferMinutes) {
                        ForEach([3, 6, 10], id: \.self) { Text("\($0) " + translationText("time.minutes")).tag(Double($0)) }
                    }
                    Picker(translationText("buffer.paused"), selection: $pausedMinutes) {
                        ForEach([3, 10, 30], id: \.self) { Text("\($0) " + translationText("time.minutes")).tag(Double($0)) }
                        Text(translationText("buffer.whole")).tag(0.0)
                    }
                    Text(translationText("buffer.help")).font(.caption).foregroundStyle(.secondary)
                }
                Section(translationText("controls.settings")) {
                    PlayerControlsModePicker()
                    Toggle(translationText("controls.autoHide"), isOn: $autoHide)
                        .disabled(controlsMode == .standard)
                    Slider(value: $opacity, in: 0...1, step: 0.05) {
                        Text(translationText("controls.opacity") + " \(Int(opacity * 100))%")
                    }
                    Toggle(translationText("fullscreen.fill"), isOn: $fullscreenFill)
                    Text(translationText("fullscreen.fillHelp")).font(.caption).foregroundStyle(.secondary)
                    Toggle(translationText("window.videoUnderHeader"), isOn: $videoUnderHeader)
                    Text(translationText("window.videoUnderHeaderHelp")).font(.caption).foregroundStyle(.secondary)
                    Text(translationText("controls.mode.help")).font(.caption).foregroundStyle(.secondary)
                }
                Section(translationText("settings.limits")) {
                    Label(translationText("settings.unlimited"), systemImage: "infinity")
                        .foregroundStyle(.teal)
                    Text(translationText("settings.limitsHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(translationText("settings.speechTitle")) {
                    Label("Silero · Kseniya", systemImage: "waveform")
                    Text(translationText("pronunciation.location"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(translationText("settings.voice"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(translationText("telegram.title")) {
                    Button(translationText("telegram.open")) { openWindow(id: "telegram-settings") }
                    Text(translationText("telegram.settings.help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text(translationText("settings.glossary"))
                        .font(.caption).foregroundStyle(.secondary)
                    Label(translationText("settings.resume"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.teal)
                }
            }
            .formStyle(.grouped)
            .id(language)
            .navigationTitle(translationText("settings.shortTitle"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(translationText("common.done")) { dismiss() }
                }
            }
        }
        .frame(width: 560, height: 680)
        .onChange(of: language) {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
            PlayerMenuController.shared.install()
        }
    }
}
