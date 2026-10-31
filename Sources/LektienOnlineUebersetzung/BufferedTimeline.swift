import AppKit
import SwiftUI
import PlayerSpeech
import PlayerCore

/// Retain native mouse, keyboard and accessibility behavior while drawing cached ranges.
struct BufferedTimeline: NSViewRepresentable {
    let position: Double
    let duration: Double?
    let prepared: [PreparedSpeechChunk]
    let active: SpeechChunk?
    var translated: [ClosedRange<Double>] = []
    var translating: ClosedRange<Double>? = nil
    var recognized: [ClosedRange<Double>] = []
    var recognizing: ClosedRange<Double>? = nil
    let seek: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(seek: seek) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        let cell = BufferSliderCell()
        slider.cell = cell
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel(translationText("timeline.label"))
        slider.toolTip = translationText("timeline.help")
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.seek = seek
        if context.coordinator.language != AppLocalization.language {
            context.coordinator.language = AppLocalization.language
            slider.setAccessibilityLabel(translationText("timeline.label"))
            slider.toolTip = translationText("timeline.help")
        }
        slider.minValue = 0
        slider.maxValue = max(1, duration ?? 1)
        slider.isEnabled = duration != nil
        guard let cell = slider.cell as? BufferSliderCell else { return }
        if !cell.isDragging { slider.doubleValue = position }
        cell.translated = translated
        cell.translating = translating
        cell.recognized = recognized
        cell.recognizing = recognizing
        cell.ready = prepared.map { $0.chunk.start...$0.chunk.end }
        cell.preparing = active.map { $0.start...$0.end }
        slider.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject {
        var seek: (Double) -> Void
        var language = AppLocalization.language
        init(seek: @escaping (Double) -> Void) { self.seek = seek }
        @objc func changed(_ slider: NSSlider) { seek(slider.doubleValue) }
    }
}

@MainActor
final class BufferSliderCell: NSSliderCell {
    var ready: [ClosedRange<Double>] = []
    var preparing: ClosedRange<Double>?
    var translated: [ClosedRange<Double>] = []
    var translating: ClosedRange<Double>?
    var recognized: [ClosedRange<Double>] = []
    var recognizing: ClosedRange<Double>?
    private(set) var isDragging = false

    override func trackMouse(with event: NSEvent, in cellFrame: NSRect, of controlView: NSView, untilMouseUp flag: Bool) -> Bool {
        isDragging = true
        defer { isDragging = false }
        return super.trackMouse(with: event, in: cellFrame, of: controlView, untilMouseUp: flag)
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = NSRect(x: rect.minX, y: rect.midY - 3, width: rect.width, height: 6)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
        guard maxValue > 0 else { return }
        for range in recognized { draw(range, in: bar, color: NSColor.systemPurple.withAlphaComponent(0.35)) }
        if let recognizing { draw(recognizing, in: bar, color: .systemPurple) }
        for range in translated { draw(range, in: bar, color: NSColor.systemTeal.withAlphaComponent(0.5)) }
        if let translating { draw(translating, in: bar, color: .systemBlue) }
        for range in ready { draw(range, in: bar, color: .lightGray) }
        if let preparing { draw(preparing, in: bar, color: .systemOrange) }
        draw(0...max(0, doubleValue), in: bar, color: .controlAccentColor)
    }

    private func draw(_ range: ClosedRange<Double>, in bar: NSRect, color: NSColor) {
        let start = min(maxValue, max(0, range.lowerBound)) / maxValue
        let end = min(maxValue, max(0, range.upperBound)) / maxValue
        guard end > start else { return }
        color.setFill()
        NSBezierPath(roundedRect: .init(x: bar.minX + bar.width * start, y: bar.minY,
                                        width: bar.width * (end - start), height: bar.height),
                     xRadius: 2, yRadius: 2).fill()
    }
}
