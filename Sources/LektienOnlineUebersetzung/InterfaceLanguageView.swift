import PlayerCore
import SwiftUI

struct InterfaceLanguageView: View {
    @AppStorage(AppLocalization.preferenceKey) private var language: InterfaceLanguage = .german
    @AppStorage("interface.languageConfirmed") private var confirmed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Sprache wählen · Choose language · Выберите язык").font(.title3.bold())
            Picker("Sprache / Language / Язык", selection: $language) {
                ForEach(InterfaceLanguage.allCases, id: \.self) { Text($0.nativeName).tag($0) }
            }.pickerStyle(.radioGroup)
            Text(translationText("language.help")).font(.callout)
            HStack { Spacer(); Button(translationText("language.continue")) { confirmed = true }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 450)
    }
}
