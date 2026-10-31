import XCTest
@preconcurrency import AVFoundation
@testable import LektienOnlineUebersetzung

final class MediaTrackTests: XCTestCase {
    @MainActor
    func testEmbeddedTracksCanBeSelectedAndDisabled() async throws {
        guard let path = ProcessInfo.processInfo.environment["LEKTIEN_MEDIA_FIXTURE"] else {
            throw XCTSkip("Supply a synthetic MP4 with two audio and two subtitle tracks")
        }
        let playback = PlaybackController()
        playback.load(url: URL(fileURLWithPath: path))
        defer { playback.player.pause() }
        for _ in 0..<100 where playback.subtitleTracks.count < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(playback.audioTracks.count, 2)
        XCTAssertGreaterThanOrEqual(playback.subtitleTracks.count, 2)
        print("Synthetic subtitle options: \(playback.subtitleTracks.map(\.title))")
        let item = try XCTUnwrap(playback.player.currentItem)
        let audioResult = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let subtitleResult = try await item.asset.loadMediaSelectionGroup(for: .legible)
        let audio = try XCTUnwrap(audioResult)
        let subtitles = try XCTUnwrap(subtitleResult)
        XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: subtitles))
        let textIndex = try XCTUnwrap(subtitles.options.firstIndex { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) })
        playback.selectSubtitle(textIndex)
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: subtitles), subtitles.options[textIndex])
        playback.player.play()
        for _ in 0..<100 where playback.embeddedSubtitleText.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(playback.embeddedSubtitleText.isEmpty, "Embedded text must reach the app overlay instead of appearing behind controls")
        XCTAssertTrue(item.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput }.allSatisfy(\.suppressesPlayerRendering))
        playback.selectSubtitle(-1)
        XCTAssertTrue(playback.embeddedSubtitleText.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(playback.embeddedSubtitleText.isEmpty, "A late callback must not restore disabled subtitles")
        XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: subtitles))
        playback.selectAudio(1)
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: audio), audio.options[1])
        playback.selectAudio(0)
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: audio), audio.options[0])
    }
}
