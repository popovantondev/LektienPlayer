import AppKit
import SwiftUI
import PlayerCore

struct SubtitleAppearance: Equatable {
    var russian = "FFFFFF"
    var german = "FFE45C"
    var outline = "000000"
    var size = 24.0
    var stroke = 2.0
    var background = 0.35

    static func color(_ hex: String) -> Color { Color(nsColor: nsColor(hex)) }
    static func nsColor(_ hex: String) -> NSColor {
        let value = UInt32(hex, radix: 16) ?? 0xFFFFFF
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    static func hex(_ color: Color) -> String {
        let value = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "%02X%02X%02X", Int((value.redComponent * 255).rounded()),
                      Int((value.greenComponent * 255).rounded()), Int((value.blueComponent * 255).rounded()))
    }
}

struct StyledSubtitle: View {
    let text: String
    let color: String
    let appearance: SubtitleAppearance

    private var lettering: some View {
        Text(text).font(.system(size: appearance.size, weight: .semibold))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
    var body: some View {
        lettering.foregroundStyle(SubtitleAppearance.color(color))
            .background {
                if appearance.stroke > 0 {
                    ZStack {
                        ForEach(0..<8) { direction in
                            lettering.foregroundStyle(SubtitleAppearance.color(appearance.outline))
                                .offset(x: cos(Double(direction) * .pi / 4) * appearance.stroke,
                                        y: sin(Double(direction) * .pi / 4) * appearance.stroke)
                        }
                    }.accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(.black.opacity(appearance.background), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct SubtitleSettingsView: View {
    @AppStorage(AppLocalization.preferenceKey) private var language: InterfaceLanguage = .german
    @AppStorage("subtitles.ruColor") private var russian = "FFFFFF"
    @AppStorage("subtitles.deColor") private var german = "FFE45C"
    @AppStorage("subtitles.outlineColor") private var outline = "000000"
    @AppStorage("subtitles.size") private var size = 24.0
    @AppStorage("subtitles.stroke") private var stroke = 2.0
    @AppStorage("subtitles.background") private var background = 0.35
    var body: some View {
        Form {
            ColorPicker(translationText("subtitles.ruColor"), selection: color($russian), supportsOpacity: false)
            ColorPicker(translationText("subtitles.deColor"), selection: color($german), supportsOpacity: false)
            ColorPicker(translationText("subtitles.outlineColor"), selection: color($outline), supportsOpacity: false)
            Slider(value: $size, in: 14...48, step: 1) { Text(translationText("subtitles.size") + " \(Int(size))") }
            Slider(value: $stroke, in: 0...4, step: 0.5) { Text(translationText("subtitles.stroke")) }
            Slider(value: $background, in: 0...0.9) { Text(translationText("subtitles.background")) }
            StyledSubtitle(text: translationText("subtitles.preview"), color: russian,
                appearance: .init(russian: russian, german: german, outline: outline, size: size, stroke: stroke, background: background))
                .frame(maxWidth: .infinity).padding().background(.gray.opacity(0.4))
            Text(translationText("subtitles.scope")).font(.caption).foregroundStyle(.secondary)
        }.id(language).padding(20).frame(width: 440)
    }
    private func color(_ storage: Binding<String>) -> Binding<Color> {
        Binding(get: { SubtitleAppearance.color(storage.wrappedValue) }, set: { storage.wrappedValue = SubtitleAppearance.hex($0) })
    }
}
