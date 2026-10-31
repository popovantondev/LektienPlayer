import XCTest
import AppKit
@testable import LektienOnlineUebersetzung

final class PlayerResizeTests: XCTestCase {
    @MainActor
    func testLayerFollowsEachResizeImmediatelyAndWindowKeepsVideoRatio() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 620))
        let surface = PlayerContainerView(frame: NSRect(x: 0, y: 0, width: 960, height: 620))
        surface.videoSize = CGSize(width: 1920, height: 1080)
        host.addSubview(surface)
        window.contentView = host
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(window.contentAspectRatio, surface.videoSize)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertNil(window.toolbar)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        for width in stride(from: 960, through: 1100, by: 10) {
            surface.setFrameSize(CGSize(width: width, height: width * 9 / 16))
            let frame = surface.playerLayer.frame
            XCTAssertTrue(frame.contains(surface.bounds), "The actual video must cover the whole surface, including its edges")
            let bleed = 2 / window.backingScaleFactor
            XCTAssertLessThanOrEqual(abs(frame.minX - surface.bounds.minX), bleed)
            XCTAssertLessThanOrEqual(abs(frame.maxY - surface.bounds.maxY), bleed)
            XCTAssertTrue(surface.playerLayer.animationKeys()?.isEmpty ?? true)
        }
        // AppKit already constrains overlay windows. The delegate must not correct them again.
        let fitted = window.delegate!.windowWillResize!(window, to: CGSize(width: 1000, height: window.frame.height))
        XCTAssertEqual(fitted, CGSize(width: 1000, height: window.frame.height))
        let moved = NSRect(origin: CGPoint(x: 150, y: 180), size: window.frame.size)
        window.setFrame(moved, display: false)
        for _ in 0..<100 { surface.layout() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(window.frame, moved, "Layout or moving the window must not enqueue another frame correction")
        window.close()
    }

    @MainActor
    func testOrdinaryPanelKeepsOneResizeAxisWhileCornerDragReverses() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let surface = PlayerContainerView(frame: .zero)
        surface.videoSize = CGSize(width: 16, height: 9)
        surface.panelHeight = 150
        window.contentView = surface
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(window.contentResizeIncrements, CGSize(width: 1, height: 1), "Ordinary mode must clear aspect constraints without zero increments")
        let start = window.frame.size
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height + 150
        window.delegate?.windowWillStartLiveResize?(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        for dx in [20.0, 10, 1, 0, -1, -10, -20] {
            let proposed = CGSize(width: start.width + dx, height: start.height + 1)
            let result = window.delegate!.windowWillResize!(window, to: proposed)
            XCTAssertEqual(result.width, proposed.width, accuracy: 0.001)
            XCTAssertEqual(result.width / (result.height - chrome), 16.0 / 9.0, accuracy: 0.001)
        }
        window.delegate?.windowDidEndLiveResize?(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        window.close()
    }

    @MainActor
    func testWindowedHeaderReservesSpaceWithEitherControlsLayout() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let surface = PlayerContainerView(frame: .zero)
        surface.videoSize = CGSize(width: 16, height: 9)
        window.contentView = surface
        for panel in [0.0, 150.0] {
            surface.panelHeight = panel
            surface.headerHeight = PlayerChrome.headerHeight
            try await Task.sleep(for: .milliseconds(50))
            let content = window.contentRect(forFrameRect: window.frame)
            // NSWindow rounds its frame to resize increments; compare in points, not ratio error.
            XCTAssertEqual(content.height - panel - PlayerChrome.headerHeight, content.width * 9 / 16, accuracy: 1)
            XCTAssertEqual(window.contentResizeIncrements, CGSize(width: 1, height: 1))
            let frame = window.frame
            for _ in 0..<20 { surface.layout() }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(window.frame, frame, "Rendering and panel visibility must not resize the window")
        }
        surface.panelHeight = 0
        surface.headerHeight = 0
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(window.contentAspectRatio, surface.videoSize, "Opt-in video behind the title retains the full-content aspect ratio")
    }

    @MainActor
    func testFullscreenTransitionClearsAspectConstraintWithValidResizeSteps() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let surface = PlayerContainerView(frame: .zero)
        surface.videoSize = CGSize(width: 16, height: 9)
        let state = PlayerWindowState()
        surface.windowState = state
        window.contentView = surface
        try await Task.sleep(for: .milliseconds(50))
        window.delegate?.windowWillEnterFullScreen?(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        XCTAssertEqual(window.contentResizeIncrements, CGSize(width: 1, height: 1))
        let proposed = CGSize(width: 1512, height: 945)
        XCTAssertEqual(window.delegate!.windowWillResize!(window, to: proposed), proposed)
        window.delegate?.windowDidEnterFullScreen?(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        XCTAssertTrue(state.isFullscreen)
        XCTAssertEqual(surface.playerLayer.videoGravity, .resizeAspectFill)
        surface.fillFullscreen = false
        XCTAssertEqual(surface.playerLayer.videoGravity, .resizeAspect)
        window.delegate?.windowWillExitFullScreen?(Notification(name: NSWindow.willExitFullScreenNotification, object: window))
        window.delegate?.windowDidExitFullScreen?(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(state.isFullscreen)
        XCTAssertEqual(window.contentAspectRatio, surface.videoSize)
        window.close()
    }
}
