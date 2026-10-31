@preconcurrency import AVFoundation

@MainActor
final class EmbeddedSubtitleOutput: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    let output = AVPlayerItemLegibleOutput()
    var onText: ((String) -> Void)?

    override init() {
        super.init()
        output.suppressesPlayerRendering = true
        output.advanceIntervalForDelegateInvocation = 0
        output.setDelegate(self, queue: .main)
    }

    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                                  didOutputAttributedStrings strings: [NSAttributedString],
                                  nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        let text = strings.map(\.string).filter { !$0.isEmpty }.joined(separator: "\n")
        MainActor.assumeIsolated { onText?(text) }
    }

    nonisolated func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        MainActor.assumeIsolated { onText?("") }
    }
}
