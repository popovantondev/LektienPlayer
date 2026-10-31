import XCTest
@testable import LektienOnlineUebersetzung

final class ControlsVisibilityTests: XCTestCase {
    func testManualHidingWorksWithAutoHideDisabled() {
        var state = ControlsVisibility(autoHide: false)
        state.toggleManually(at: 0)
        state.update(at: 100)
        XCTAssertFalse(state.visible)
        state.pointerMoved(y: 300, height: 600, panelHeight: 150, at: 101)
        XCTAssertFalse(state.visible)
        state.pointerMoved(y: 599, height: 600, panelHeight: 150, at: 102)
        XCTAssertTrue(state.visible)
        state.update(at: 500)
        XCTAssertTrue(state.visible)
    }

    func testSlidingPanelHidesOnPauseAndOnlyBottomEdgeRevealsIt() {
        var state = ControlsVisibility()
        state.reveal(at: 10)
        state.update(at: 11)
        XCTAssertFalse(state.visible)
        state.pointerMoved(y: 300, height: 600, panelHeight: 150, at: 12)
        XCTAssertFalse(state.visible, "Moving over the picture must not reveal the sliding panel")
        state.pointerMoved(y: 530, height: 600, panelHeight: 150, at: 13)
        XCTAssertFalse(state.visible, "The hidden panel's former area is not the reveal edge")
        state.pointerMoved(y: 596, height: 600, panelHeight: 150, at: 14)
        state.update(at: 30)
        XCTAssertTrue(state.visible, "Keep controls visible while the pointer is over them")
        state.pointerMoved(y: 200, height: 600, panelHeight: 150, at: 31)
        state.update(at: 31.3)
        XCTAssertTrue(state.visible)
        state.update(at: 32)
        XCTAssertFalse(state.visible)
    }

    func testOriginalOverlayModeUsesInactivityAndStaysVisibleOnPause() {
        var state = ControlsVisibility(mode: .overlay, playing: true)
        state.reveal(at: 0)
        for step in 0..<1000 {
            state.pointerMoved(y: 200, height: 600, panelHeight: 150, at: Double(step) / 100)
        }
        state.update(at: 12)
        XCTAssertTrue(state.visible)
        state.update(at: 14)
        XCTAssertFalse(state.visible)
        state.pointerMoved(y: 200, height: 600, panelHeight: 150, at: 15)
        XCTAssertTrue(state.visible)
        state.playing = false
        state.update(at: 100)
        XCTAssertTrue(state.visible)
    }

    func testStandardModeDisabledAutoHideAndOpenPopoversStayVisible() {
        for state in [ControlsVisibility(mode: .standard, playing: true),
                      ControlsVisibility(autoHide: false, playing: true),
                      ControlsVisibility(playing: true, pinned: true)] {
            var state = state
            state.update(at: 100)
            XCTAssertTrue(state.visible)
        }
    }
}
