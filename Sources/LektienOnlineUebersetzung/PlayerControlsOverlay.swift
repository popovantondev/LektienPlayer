import AppKit
import SwiftUI

enum PlayerControlsMode: String, CaseIterable {
    case standard, overlay, sliding
    var title: String { translationText("controls.mode." + rawValue) }
}

struct ControlsVisibility {
    var mode: PlayerControlsMode = .sliding
    var autoHide = true
    var playing = false
    var pinned = false
    private(set) var visible = true
    private(set) var pointerInsidePanel = false
    private var lastActivity = 0.0
    private var manuallyHidden = false

    init(mode: PlayerControlsMode = .sliding, autoHide: Bool = true, playing: Bool = false, pinned: Bool = false) {
        self.mode = mode; self.autoHide = autoHide; self.playing = playing; self.pinned = pinned
    }

    var canHide: Bool { autoHide && mode != .standard && !pinned && (mode == .sliding || playing) }
    var delay: Double { mode == .sliding ? 0.7 : 3 }

    mutating func reveal(at time: Double) { visible = true; manuallyHidden = false; lastActivity = time }
    mutating func toggleManually(at time: Double) {
        if visible { visible = false; manuallyHidden = true }
        else { reveal(at: time) }
    }

    mutating func pointerMoved(y: Double?, height: Double, panelHeight: Double, at time: Double) {
        let wasInside = pointerInsidePanel
        pointerInsidePanel = y.map { $0 >= height - panelHeight && $0 <= height } ?? false
        if wasInside && !pointerInsidePanel { lastActivity = time }
        if mode == .overlay {
            if y != nil { reveal(at: time) }
        } else if let y, y >= height - 16, y <= height {
            reveal(at: time)
        } else if visible && pointerInsidePanel {
            lastActivity = time
        }
    }

    mutating func update(at time: Double) {
        if manuallyHidden && !pinned { return }
        if !canHide { reveal(at: time) }
        else if !pointerInsidePanel && time - lastActivity >= delay { visible = false }
    }
}

@MainActor
final class ControlsVisibilityController: ObservableObject {
    @Published private(set) var visible = true
    private var state = ControlsVisibility()
    private var timer: Task<Void, Never>?

    func configure(mode: PlayerControlsMode, autoHide: Bool, playing: Bool, pinned: Bool) {
        state.mode = mode; state.autoHide = autoHide; state.playing = playing; state.pinned = pinned
        state.reveal(at: ProcessInfo.processInfo.systemUptime)
        update()
    }

    func pointerMoved(y: Double?, height: Double, panelHeight: Double) {
        state.pointerMoved(y: y, height: height, panelHeight: panelHeight, at: ProcessInfo.processInfo.systemUptime)
        update()
    }

    func stop() { timer?.cancel(); timer = nil }
    func toggleManually() { state.toggleManually(at: ProcessInfo.processInfo.systemUptime); update() }

    private func update() {
        state.update(at: ProcessInfo.processInfo.systemUptime)
        // Mouse coordinates and timestamps are deliberately not published to SwiftUI.
        if visible != state.visible { visible = state.visible }
        guard state.canHide, state.visible, !state.pointerInsidePanel else { stop(); return }
        guard timer == nil else { return }
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            self.timer = nil
            self.update()
        }
    }
}

struct PlayerControlsOverlay<Subtitles: View, Controls: View, Header: View>: View {
    let mode: PlayerControlsMode
    let autoHide: Bool
    let playing: Bool
    let pinned: Bool
    let fullscreen: Bool
    let manualToggle: Int
    @Binding var panelHeight: CGFloat
    @ViewBuilder var subtitles: () -> Subtitles
    @ViewBuilder var controls: () -> Controls
    @ViewBuilder var header: () -> Header
    @StateObject private var visibility = ControlsVisibilityController()
    @AppStorage("player.panelOpacity") private var panelOpacity = 0.85
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                subtitles()
                    .padding(.horizontal, 32)
                    .padding(.top, fullscreen ? 16 : PlayerChrome.headerHeight + 12)
                    .padding(.bottom, visibility.visible ? panelHeight + 16 : 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
                VStack(spacing: 3) {
                    if mode != .standard || fullscreen {
                        Button { visibility.toggleManually() } label: {
                            Image(systemName: "chevron.down").font(.caption2)
                                .frame(maxWidth: .infinity).frame(height: 14).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(translationText("controls.hide"))
                            .accessibilityLabel(translationText("controls.hide"))
                    }
                    if fullscreen {
                        header().frame(height: PlayerChrome.headerHeight)
                    }
                    controls()
                }.padding(12)
                    // A simple translucent fill avoids re-blurring the desktop during window dragging.
                    .background(Color(nsColor: .windowBackgroundColor).opacity(panelOpacity))
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { panelHeight = $0 }
                    .offset(y: (fullscreen || mode == .sliding) && !visibility.visible && !reduceMotion ? panelHeight : 0)
                    .opacity(visibility.visible || ((fullscreen || mode == .sliding) && !reduceMotion) ? 1 : 0)
                    .allowsHitTesting(visibility.visible)
                    .accessibilityHidden(!visibility.visible)
                if !visibility.visible {
                    Button {
                        visibility.pointerMoved(y: geometry.size.height - 1, height: geometry.size.height, panelHeight: panelHeight)
                    } label: {
                        Capsule().fill(.white.opacity(0.65)).frame(width: 36, height: 3)
                            .frame(maxWidth: .infinity).frame(height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(translationText("controls.reveal"))
                    .help(translationText("controls.reveal"))
                    .onHover { inside in
                        if inside {
                            visibility.pointerMoved(y: geometry.size.height - 1, height: geometry.size.height, panelHeight: panelHeight)
                        }
                    }
                }
                if !fullscreen {
                    header()
                    .frame(height: PlayerChrome.headerHeight)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.88))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                let y: Double? = if case let .active(point) = phase { Double(point.y) } else { nil }
                visibility.pointerMoved(y: y, height: geometry.size.height, panelHeight: panelHeight)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: visibility.visible)
        }
        .onAppear { configure() }
        .onChange(of: mode) { configure() }
        .onChange(of: autoHide) { configure() }
        .onChange(of: playing) { configure() }
        .onChange(of: pinned) { configure() }
        .onChange(of: fullscreen) { configure() }
        .onChange(of: manualToggle) { visibility.toggleManually() }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in configure() }
        .onDisappear { visibility.stop() }
    }

    private func configure() {
        visibility.configure(mode: fullscreen ? .sliding : mode, autoHide: fullscreen || autoHide, playing: playing,
                             pinned: pinned || NSWorkspace.shared.isVoiceOverEnabled)
    }
}

struct PlayerControlsModePicker: View {
    @AppStorage("player.controlsMode") private var mode: PlayerControlsMode = .sliding
    var body: some View {
        Picker(translationText("controls.mode"), selection: $mode) {
            ForEach(PlayerControlsMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.radioGroup)
    }
}
