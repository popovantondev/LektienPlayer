import AppKit
import PlayerCore
import SwiftUI

enum PlayerCommand: String {
    case openVideo, openLibrary, playPause, translate, prepare, settings, subtitleSettings, help, fullscreen, controls
}

struct PlayerActions {
    var perform: (PlayerCommand) -> Void
    var canPlay: Bool
    var canTranslate: Bool
}

@MainActor
final class PlayerMenuController: NSObject, ObservableObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = PlayerMenuController()
    weak var activeSurface: PlayerContainerView?
    @Published private(set) var isTracking = false
    private var trackingMenus = Set<ObjectIdentifier>()
    private var installedMenu: NSMenu?
    private var installedItems: [NSMenuItem] = []

    func restoreIfNeeded() {
        guard !isTracking, let installedMenu else { return }
        if installedMenu.items != installedItems {
            installedMenu.removeAllItems()
            for item in installedItems { installedMenu.addItem(item) }
        }
        if NSApp.mainMenu !== installedMenu { NSApp.mainMenu = installedMenu }
    }

    func install() {
        let root = NSMenu()
        let app = submenu(translationText("app.title"), in: root)
        add("menu.about", to: app, selector: #selector(about))
        app.addItem(.separator())
        command(.settings, title: "settings.shortTitle", key: ",", to: app)
        app.addItem(.separator())
        add("menu.hideApp", key: "h", to: app, selector: #selector(hideApp))
        add("menu.quit", key: "q", to: app, selector: #selector(quit))
        let file = submenu(translationText("menu.file"), in: root)
        command(.openVideo, title: "menu.open", key: "o", to: file)
        command(.openLibrary, title: "menu.library", key: "o", modifiers: [.command, .shift], to: file)
        file.addItem(.separator())
        add("library.close", key: "w", to: file, selector: #selector(closeWindow))
        let view = submenu(translationText("menu.view"), in: root)
        let modes = submenu(translationText("controls.mode"), in: view)
        for mode in PlayerControlsMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = mode.rawValue; modes.addItem(item)
        }
        add("controls.autoHide", to: view, selector: #selector(toggleAutoHide))
        command(.controls, title: "controls.toggle", key: "u", modifiers: [.command, .shift], to: view)
        command(.subtitleSettings, title: "subtitles.appearance", to: view)
        view.addItem(.separator())
        command(.fullscreen, title: "player.fullscreen", key: "f", modifiers: [.command, .control], to: view)
        let playback = submenu(translationText("menu.playback"), in: root)
        command(.playPause, title: "menu.playPause", key: " ", modifiers: [], to: playback)
        command(.translate, title: "translation.start", to: playback)
        command(.prepare, title: "preparation.title", to: playback)
        let window = submenu(translationText("menu.window"), in: root)
        add("menu.minimize", key: "m", to: window, selector: #selector(minimize))
        NSApp.windowsMenu = window
        let help = submenu(translationText("menu.helpTitle"), in: root)
        command(.help, title: "menu.help", to: help)
        NSApp.helpMenu = help
        installedMenu = root
        installedItems = root.items
        NSApp.mainMenu = root
    }

    private func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let menu = NSMenu(title: title); menu.delegate = self
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu; parent.addItem(item)
        return menu
    }
    private func add(_ key: String, key shortcut: String = "", to menu: NSMenu, selector: Selector) {
        let item = NSMenuItem(title: translationText(key), action: selector, keyEquivalent: shortcut)
        item.target = self; menu.addItem(item)
    }
    private func command(_ command: PlayerCommand, title: String, key: String = "",
                         modifiers: NSEvent.ModifierFlags = [.command], to menu: NSMenu) {
        let item = NSMenuItem(title: translationText(title), action: #selector(run(_:)), keyEquivalent: key)
        item.target = self; item.representedObject = command.rawValue; item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
    }
    func menuWillOpen(_ menu: NSMenu) { trackingMenus.insert(ObjectIdentifier(menu)); isTracking = true }
    func menuDidClose(_ menu: NSMenu) {
        trackingMenus.remove(ObjectIdentifier(menu))
        if menu.supermenu === installedMenu { trackingMenus.removeAll() }
        isTracking = !trackingMenus.isEmpty
        DispatchQueue.main.async { self.restoreIfNeeded() }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(selectMode(_:)), let value = item.representedObject as? String {
            item.state = value == (UserDefaults.standard.string(forKey: "player.controlsMode") ?? "sliding") ? .on : .off
        }
        if item.action == #selector(toggleAutoHide) {
            item.state = (UserDefaults.standard.object(forKey: "player.autoHide") as? Bool ?? true) ? .on : .off
        }
        if item.action == #selector(run(_:)), let value = item.representedObject as? String,
           let command = PlayerCommand(rawValue: value) {
            guard let actions = activeSurface?.menuActions else { return false }
            if command == .translate || command == .prepare { return actions.canTranslate }
            if command == .playPause { return actions.canPlay }
        }
        return true
    }
    @objc private func run(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let command = PlayerCommand(rawValue: value) else { return }
        activeSurface?.menuActions?.perform(command)
    }
    @objc private func selectMode(_ item: NSMenuItem) {
        guard let mode = item.representedObject as? String else { return }
        UserDefaults.standard.set(mode, forKey: "player.controlsMode")
    }
    @objc private func toggleAutoHide() {
        let current = UserDefaults.standard.object(forKey: "player.autoHide") as? Bool ?? true
        UserDefaults.standard.set(!current, forKey: "player.autoHide")
    }
    @objc private func about() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func hideApp() { NSApp.hide(nil) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func closeWindow() { NSApp.keyWindow?.performClose(nil) }
    @objc private func minimize() { NSApp.keyWindow?.miniaturize(nil) }
}

final class PlayerAppDelegate: NSObject, NSApplicationDelegate {
    // SwiftUI may replace the scene menu when a window or fullscreen space changes.
    // Restore the same native menu, preserving submenu identity and tracking state.
    func applicationDidUpdate(_ notification: Notification) { PlayerMenuController.shared.restoreIfNeeded() }
    func applicationDidBecomeActive(_ notification: Notification) { PlayerMenuController.shared.restoreIfNeeded() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        DispatchQueue.main.async { PlayerMenuController.shared.install() }
    }
}

struct PlayerHelpView: View {
    @AppStorage(AppLocalization.preferenceKey) private var language: InterfaceLanguage = .german
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(["help.open", "help.library", "help.translate", "help.prepare", "help.buffer", "help.export", "help.exportVideo", "help.audio", "help.controls", "help.languages"], id: \.self) {
                    Text(translationText($0))
                }
            }.id(language).padding(24).textSelection(.enabled)
        }.frame(width: 540, height: 500)
            .environment(\.locale, Locale(identifier: language.rawValue))
    }
}
