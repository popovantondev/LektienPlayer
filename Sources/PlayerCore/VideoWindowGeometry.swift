import Foundation

public enum VideoWindowGeometry {
    public enum ResizeAxis { case width, height }

    public static func fittedSize(proposed: CGSize, axis: ResizeAxis = .width, videoSize: CGSize,
                                  chrome: CGSize, minimum: CGSize, maximum: CGSize) -> CGSize {
        guard videoSize.width.isFinite, videoSize.height.isFinite,
              videoSize.width > 0, videoSize.height > 0 else { return proposed }
        let ratio = videoSize.width / videoSize.height
        let wantedWidth = axis == .width ? proposed.width - chrome.width : (proposed.height - chrome.height) * ratio
        let lower = max(1, minimum.width - chrome.width, (minimum.height - chrome.height) * ratio)
        let upper = max(1, min(maximum.width - chrome.width, (maximum.height - chrome.height) * ratio))
        let width = max(min(lower, upper), min(wantedWidth, upper))
        return CGSize(width: width + chrome.width, height: width / ratio + chrome.height)
    }
}
