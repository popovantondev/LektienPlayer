import AppKit
import PlayerCore
import XCTest
@testable import LektienOnlineUebersetzung

final class LocalizationAndMenuTests: XCTestCase {
    func testAllResourceLanguagesHaveMatchingKeysAndFormatArguments() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+0 #]*(?:\d+)?(?:\.\d+)?(?:ll|l)?[@diufgse]"#)
        for target in ["LektienOnlineUebersetzung", "PlayerCore", "PlayerTranslation", "PlayerSpeech"] {
            let resources = root.appendingPathComponent("Sources/\(target)/Resources")
            var dictionaries: [[String: String]] = []
            for language in InterfaceLanguage.allCases {
                let file = resources.appendingPathComponent("\(language.rawValue).lproj/Localizable.strings")
                let data = try Data(contentsOf: file)
                let dictionary = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
                dictionaries.append(dictionary)
            }
            let reference = dictionaries[0]
            for dictionary in dictionaries.dropFirst() {
                XCTAssertEqual(Set(reference.keys), Set(dictionary.keys), target)
                for (key, value) in reference {
                    func arguments(_ text: String) -> [String] {
                        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                            String(text[Range($0.range, in: text)!])
                        }
                    }
                    XCTAssertEqual(arguments(value), arguments(dictionary[key] ?? ""), "\(target): \(key)")
                }
            }
        }
    }

    @MainActor
    func testNativeMenuSurvivesPlaybackUpdatesAndUsesSelectedLanguage() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let savedLanguage = defaults.object(forKey: AppLocalization.preferenceKey)
        let savedMode = defaults.object(forKey: "player.controlsMode")
        let oldMenu = NSApp.mainMenu
        defer {
            defaults.set(savedLanguage, forKey: AppLocalization.preferenceKey)
            defaults.set(savedMode, forKey: "player.controlsMode")
            NSApp.mainMenu = oldMenu
        }
        defaults.set("de", forKey: AppLocalization.preferenceKey)
        let surface = PlayerContainerView(frame: .zero)
        PlayerMenuController.shared.activeSurface = surface
        PlayerMenuController.shared.install()
        let menu = NSApp.mainMenu!
        XCTAssertEqual(menu.items.map(\.title), ["Lektien Player", "Ablage", "Ansicht", "Wiedergabe", "Fenster", "Hilfe"])
        let modes = menu.items[2].submenu!.items[0].submenu!
        XCTAssertEqual(modes.items.count, 3)
        for mode in PlayerControlsMode.allCases {
            defaults.set(mode.rawValue, forKey: "player.controlsMode")
            for item in modes.items {
                XCTAssertTrue(PlayerMenuController.shared.validateMenuItem(item))
                XCTAssertEqual(item.state, item.representedObject as? String == mode.rawValue ? .on : .off)
            }
        }
        for _ in 0..<100 {
            surface.menuActions = PlayerActions(perform: { _ in }, canPlay: true, canTranslate: false)
        }
        XCTAssertTrue(NSApp.mainMenu === menu, "Playback updates must not replace a menu being tracked")
        NSApp.mainMenu = NSMenu()
        PlayerMenuController.shared.restoreIfNeeded()
        XCTAssertTrue(NSApp.mainMenu === menu, "Window transitions must restore the same menu")
        menu.removeItem(at: 2)
        PlayerMenuController.shared.restoreIfNeeded()
        XCTAssertEqual(menu.items[2].title, "Ansicht")
        XCTAssertTrue(menu.items[2].submenu!.items[0].submenu === modes)
        defaults.set("en", forKey: AppLocalization.preferenceKey)
        PlayerMenuController.shared.install()
        XCTAssertEqual(NSApp.mainMenu?.items[1].title, "File")
        defaults.set("ru", forKey: AppLocalization.preferenceKey)
        XCTAssertEqual(translationText("settings.shortTitle"), "Настройки")
    }
}
