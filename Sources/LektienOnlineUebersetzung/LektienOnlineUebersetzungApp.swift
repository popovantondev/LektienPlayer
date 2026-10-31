import PlayerCore
import SwiftUI

@main
struct LektienOnlineUebersetzungApp: App {
    @NSApplicationDelegateAdaptor(PlayerAppDelegate.self) private var appDelegate
    @AppStorage(AppLocalization.preferenceKey) private var language: InterfaceLanguage = .german
    init() {
        UserDefaults.standard.set([AppLocalization.language.rawValue], forKey: "AppleLanguages")
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 630)
        .commandsRemoved()
        Window(translationText("settings.shortTitle"), id: "translation-settings") {
            AISettingsView().environment(\.locale, Locale(identifier: language.rawValue))
        }.windowResizability(.contentSize).defaultPosition(.center).commandsRemoved()
        Window(translationText("subtitles.appearance"), id: "subtitle-settings") {
            SubtitleSettingsView().environment(\.locale, Locale(identifier: language.rawValue))
        }.windowResizability(.contentSize).commandsRemoved()
        Window(translationText("telegram.title"), id: "telegram-settings") {
            TelegramSettingsView().environment(\.locale, Locale(identifier: language.rawValue))
        }.windowResizability(.contentSize).commandsRemoved()
        Window(translationText("menu.help"), id: "player-help") {
            PlayerHelpView()
        }.windowResizability(.contentSize).commandsRemoved()
        Window(translationText("queue.title"), id: "preparation-queue") {
            PreparationQueueView().environment(\.locale, Locale(identifier: language.rawValue))
        }.defaultSize(width: 700, height: 500).commandsRemoved()
    }
}
