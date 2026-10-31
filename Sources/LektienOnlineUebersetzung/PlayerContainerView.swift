import AppKit
import AVFoundation
import PlayerCore

final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()
    var togglePlayback: (() -> Void)?
    var menuActions: PlayerActions?
    weak var windowState: PlayerWindowState?
    var fillFullscreen = true { didSet { updateVideoGravity() } }
    var changingFullscreen = false
    nonisolated(unsafe) private var keyMonitor: Any?
    var mediaURL: URL? { didSet { if mediaURL != oldValue { updateWindowTitle() } } }
    var panelHeight: CGFloat = 0 {
        didSet { if panelHeight != oldValue { scheduleWindowFit() } }
    }
    var headerHeight: CGFloat = 0 {
        didSet { if headerHeight != oldValue { scheduleWindowFit() } }
    }
    var reservedHeight: CGFloat { panelHeight + headerHeight }
    private let sizingDelegate = PlayerWindowSizingDelegate()
    var videoSize: CGSize = .zero {
        didSet {
            if videoSize != oldValue { scheduleWindowFit() }
        }
    }
    private var fittingScheduled = false
    private weak var configuredWindow: NSWindow?

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        // Layer geometry follows live resizing without Core Animation's default interpolation.
        playerLayer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        layer?.addSublayer(playerLayer)
        sizingDelegate.surface = self
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      window.attachedSheet == nil, event.charactersIgnoringModifiers == " ",
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      !(window.firstResponder is NSTextView) else { return false }
                if !event.isARepeat { self.togglePlayback?() }
                return true
            }
            return handled ? nil : event
        }
    }

    required init?(coder: NSCoder) { nil }
    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        guard window !== configuredWindow else { return }
        configuredWindow = window
        // The custom header owns the title area; the video meets it with a one-pixel bleed.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .black
        window.isOpaque = true
        windowState?.window = window
        PlayerMenuController.shared.activeSurface = self
        if window.delegate !== sizingDelegate {
            sizingDelegate.original = window.delegate
            window.delegate = sizingDelegate
        }
        updateWindowTitle()
        scheduleWindowFit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayerFrame()
    }

    override func layout() {
        super.layout()
        updateLayerFrame()
    }

    private func updateLayerFrame() {
        let scale = window?.backingScaleFactor ?? 2
        let pixels = convertToBacking(bounds)
        let aligned = CGRect(x: floor(pixels.minX), y: floor(pixels.minY),
                             width: ceil(pixels.maxX) - floor(pixels.minX), height: ceil(pixels.maxY) - floor(pixels.minY))
        let frame = convertFromBacking(aligned).insetBy(dx: -1 / scale, dy: -1 / scale)
        guard playerLayer.frame != frame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = frame
        CATransaction.commit()
    }

    func scheduleWindowFit() {
        guard !fittingScheduled else { return }
        fittingScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fittingScheduled = false
            guard let window = self.window, !self.changingFullscreen, !window.styleMask.contains(.fullScreen),
                  window.attachedSheet == nil, !self.inLiveResize, self.videoSize.width > 0 else { return }
            if self.reservedHeight == 0 { window.contentAspectRatio = self.videoSize }
            else { window.contentResizeIncrements = CGSize(width: 1, height: 1) }
            var frame = window.frame
            let content = window.contentRect(forFrameRect: frame).size
            let chrome = CGSize(width: frame.width - content.width,
                                height: frame.height - content.height + self.reservedHeight)
            let size = VideoWindowGeometry.fittedSize(proposed: frame.size, videoSize: self.videoSize,
                chrome: chrome, minimum: window.minSize,
                maximum: window.screen?.visibleFrame.size ?? window.maxSize)
            guard abs(size.height - frame.height) > 1 || abs(size.width - frame.width) > 1 else { return }
            frame.origin.y += frame.height - size.height
            frame.size = size
            if let visible = window.screen?.visibleFrame {
                frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - size.width))
                frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - size.height))
            }
            window.setFrame(frame, display: true)
        }
    }

    private func updateWindowTitle() {
        guard let window else { return }
        window.title = mediaURL?.lastPathComponent ?? translationText("app.title")
        window.representedURL = mediaURL
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.attachedSheet == nil else { return }
            window.makeFirstResponder(self)
        }
    }

    func updateVideoGravity() {
        let full = window?.styleMask.contains(.fullScreen) == true || windowState?.isFullscreen == true
        let gravity: AVLayerVideoGravity = full && fillFullscreen ? .resizeAspectFill : .resizeAspect
        if playerLayer.videoGravity != gravity { playerLayer.videoGravity = gravity }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayerFrame()
    }

}

private final class PlayerWindowSizingDelegate: NSObject, NSWindowDelegate {
    weak var surface: PlayerContainerView?
    nonisolated(unsafe) weak var original: (any NSWindowDelegate)?
    private var resizeStart: CGSize?
    private var usesWidth: Bool?

    func windowDidBecomeKey(_ notification: Notification) {
        PlayerMenuController.shared.activeSurface = surface
        original?.windowDidBecomeKey?(notification)
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        surface?.changingFullscreen = true
        // Clearing an aspect constraint with a zero ratio also creates zero resize increments.
        surface?.window?.contentResizeIncrements = CGSize(width: 1, height: 1)
        original?.windowWillEnterFullScreen?(notification)
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        surface?.changingFullscreen = false
        surface?.windowState?.isFullscreen = true
        surface?.updateVideoGravity()
        original?.windowDidEnterFullScreen?(notification)
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        surface?.changingFullscreen = true
        original?.windowWillExitFullScreen?(notification)
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        surface?.changingFullscreen = false
        surface?.windowState?.isFullscreen = false
        surface?.updateVideoGravity()
        surface?.scheduleWindowFit()
        original?.windowDidExitFullScreen?(notification)
    }
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        [.fullScreen, .autoHideDock, .autoHideMenuBar]
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
    func windowWillStartLiveResize(_ notification: Notification) {
        resizeStart = surface?.window?.frame.size
        usesWidth = nil
        original?.windowWillStartLiveResize?(notification)
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        resizeStart = nil; usesWidth = nil
        original?.windowDidEndLiveResize?(notification)
    }
    func windowWillResize(_ window: NSWindow, to proposed: NSSize) -> NSSize {
        if surface?.changingFullscreen == true { return proposed }
        // AppKit can constrain the whole content only when no fixed-height chrome is reserved.
        guard let surface, surface.reservedHeight > 0, surface.videoSize.width > 0,
              !window.styleMask.contains(.fullScreen) else {
            return original?.windowWillResize?(window, to: proposed) ?? proposed
        }
        let start = resizeStart ?? window.frame.size
        let ratio = surface.videoSize.width / surface.videoSize.height
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height + surface.reservedHeight
        if usesWidth == nil {
            usesWidth = abs(proposed.width - start.width) >= abs(proposed.height - start.height) * ratio
        }
        // Header and ordinary controls have fixed heights. Lock the driving edge for the entire
        // gesture instead of changing axes as fast diagonal motion crosses the origin.
        return VideoWindowGeometry.fittedSize(proposed: proposed, axis: usesWidth == true ? .width : .height,
            videoSize: surface.videoSize,
            chrome: CGSize(width: 0, height: chrome), minimum: window.minSize,
            maximum: window.screen?.visibleFrame.size ?? window.maxSize)
    }
}
