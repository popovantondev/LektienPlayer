import Foundation

public enum InterfaceLanguage: String, CaseIterable, Sendable {
    case german = "de", english = "en", russian = "ru"
    public var nativeName: String {
        switch self { case .german: "Deutsch"; case .english: "English"; case .russian: "Русский" }
    }
}

public enum AppLocalization {
    private static let resources = Bundle.main.url(forResource: "LektienOnlineUebersetzung_PlayerCore", withExtension: "bundle")
        .flatMap(Bundle.init(url:)) ?? .module
    public static func coreText(_ key: String) -> String { text(key, bundle: resources) }
    public static let preferenceKey = "interface.language"
    public static var language: InterfaceLanguage {
        InterfaceLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "de") ?? .german
    }
    public static var locale: Locale { Locale(identifier: language.rawValue) }

    public static func text(_ key: String, bundle: Bundle, language: InterfaceLanguage? = nil) -> String {
        let code = (language ?? self.language).rawValue
        let localized = bundle.url(forResource: code, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? bundle
        return localized.localizedString(forKey: key, value: nil, table: "Localizable")
    }
}
