import XCTest
import PlayerCore

final class VideoWindowGeometryTests: XCTestCase {
    func testHorizontalAndVerticalDragKeepVideoRatioExcludingControls() {
        for axis in [VideoWindowGeometry.ResizeAxis.width, .height] {
            let result = VideoWindowGeometry.fittedSize(proposed: CGSize(width: 1200, height: 850), axis: axis,
                videoSize: CGSize(width: 1920, height: 1080), chrome: CGSize(width: 0, height: 140),
                minimum: CGSize(width: 400, height: 300), maximum: CGSize(width: 1600, height: 1000))
            XCTAssertEqual(result.width / (result.height - 140), 16.0 / 9.0, accuracy: 0.001)
            XCTAssertLessThanOrEqual(result.height, 1000)
        }
    }
}
