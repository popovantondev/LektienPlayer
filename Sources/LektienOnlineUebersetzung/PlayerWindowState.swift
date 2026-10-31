import AppKit
import SwiftUI

enum PlayerChrome {
    static let headerHeight: CGFloat = 44
}

@MainActor
final class PlayerWindowState: ObservableObject {
    weak var window: NSWindow?
    @Published var isFullscreen = false
    @Published var controlsToggle = 0
    func toggleFullscreen() { window?.toggleFullScreen(nil) }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) }
            else { window?.performDrag(with: event) }
        }
    }
}

/// A mouse-operated header action must not retain the file dialog's focus ring.
struct HeaderOpenButton: NSViewRepresentable {
    let title: String
    var action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> Button {
        let button = Button(title: title, target: context.coordinator, action: #selector(Coordinator.run))
        button.isBordered = false
        button.focusRingType = .none
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    func updateNSView(_ button: Button, context: Context) {
        button.title = title; context.coordinator.action = action
    }
    final class Button: NSButton {
        override var acceptsFirstResponder: Bool { false }
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }
}
