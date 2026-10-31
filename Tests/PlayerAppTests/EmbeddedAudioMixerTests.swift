import XCTest
@preconcurrency import AVFoundation
@testable import LektienOnlineUebersetzung

final class EmbeddedAudioMixerTests: XCTestCase {
    @MainActor
    func testMixedPCMContainsBothTracksAtIndependentLevelsAndCanMuteAll() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = AVMutableComposition()
        var sourceAssets: [AVURLAsset] = []
        defer { withExtendedLifetime(sourceAssets) {} }
        for (index, frequency) in [440.0, 880.0].enumerated() {
            let url = root.appendingPathComponent("tone-\(index).wav")
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            for frame in 0..<48_000 { buffer.floatChannelData![0][frame] = Float(0.2 * sin(2 * .pi * frequency * Double(frame) / 48_000)) }
            try autoreleasepool {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            let asset = AVURLAsset(url: url)
            sourceAssets.append(asset)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let track = try XCTUnwrap(tracks.first)
            let destination = try XCTUnwrap(source.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try destination.insertTimeRange(.init(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 48_000)), of: track, at: .zero)
        }
        let mixer = EmbeddedAudioMixer()
        var choices = try await mixer.prepare(asset: source)
        defer { mixer.reset() }
        XCTAssertEqual(choices.count, 2)
        choices[0].enabled = true
        choices[0].volume = 0.25
        choices[1].enabled = true
        choices[1].volume = 0.75
        mixer.apply(choices)
        let both = try await samples(mixer)
        XCTAssertEqual(amplitude(both, at: 440), 0.05, accuracy: 0.002)
        XCTAssertEqual(amplitude(both, at: 880), 0.15, accuracy: 0.002)
        choices[0].enabled = false
        mixer.apply(choices)
        let second = try await samples(mixer)
        XCTAssertLessThan(amplitude(second, at: 440), 0.002)
        XCTAssertEqual(amplitude(second, at: 880), 0.15, accuracy: 0.002)
        choices[1].enabled = false
        mixer.apply(choices)
        let silent = try await samples(mixer)
        XCTAssertLessThan(silent.map { abs($0) }.max() ?? 1, 0.0001)
    }

    @MainActor
    func testDuckingRespondsToAudioAndRestoresOriginalAfterPause() async throws {
        guard let path = ProcessInfo.processInfo.environment["LEKTIEN_STREAM_FIXTURE"] else { throw XCTSkip("Opt-in silent video") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("speech-tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
        buffer.frameLength = 96000
        for frame in 0..<96000 { buffer.floatChannelData![0][frame] = Float(0.2 * sin(2 * .pi * 440 * Double(frame) / 24000)) }
        try autoreleasepool { try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer) }
        let playback = PlaybackController()
        playback.load(url: URL(fileURLWithPath: path))
        defer { playback.pause(); playback.clearVoice(); playback.audioMixer.reset() }
        for _ in 0..<100 where playback.snapshot.duration == nil { try await Task.sleep(for: .milliseconds(20)) }
        playback.volume = 0.8
        playback.russianVolume = 0.05
        try playback.attachVoice(url: url)
        XCTAssertEqual(playback.externalVoiceName, "speech-tone.wav")
        playback.seek(to: 1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(playback.voicePlayer?.currentTime ?? -1, 1, accuracy: 0.15)
        XCTAssertFalse(playback.voicePlayer?.isPlaying ?? true, "Seeking while paused must not start external speech")
        playback.play()
        for _ in 0..<40 where playback.audioMixer.player.volume > 0.3 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertLessThan(playback.audioMixer.player.volume, 0.3)
        XCTAssertEqual(playback.volume, 0.8, "Ducking must preserve the user's master setting")
        playback.pause()
        XCTAssertFalse(playback.voicePlayer?.isPlaying ?? true, "Pause must pause external speech with the video")
        for _ in 0..<80 where playback.audioMixer.player.volume < 0.78 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThan(playback.audioMixer.player.volume, 0.78)
    }

    @MainActor
    func testOpeningOnPauseStillLoadsTimelineAndVideoDimensions() async throws {
        guard let path = ProcessInfo.processInfo.environment["LEKTIEN_MEDIA_FIXTURE"] else { throw XCTSkip("Opt-in synthetic MP4") }
        let playback = PlaybackController()
        playback.load(url: URL(fileURLWithPath: path))
        defer { playback.pause(); playback.audioMixer.reset() }
        for _ in 0..<100 where playback.snapshot.duration == nil || playback.videoSize.width == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(playback.snapshot.duration ?? 0, 1)
        XCTAssertGreaterThan(playback.videoSize.width, 0)
        XCTAssertFalse(playback.playbackRequested)
        XCTAssertEqual(playback.player.rate, 0)
        playback.seek(to: 3)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(playback.snapshot.position, 3, accuracy: 0.05)
        XCTAssertFalse(playback.playbackRequested)
    }

    @MainActor
    func testMixerFollowsPauseSeekAndIgnoresUnrelatedEndNotification() async throws {
        guard let path = ProcessInfo.processInfo.environment["LEKTIEN_MEDIA_FIXTURE"] else { throw XCTSkip("Opt-in synthetic MP4") }
        let playback = PlaybackController()
        playback.load(url: URL(fileURLWithPath: path))
        playback.play()
        defer { playback.player.pause(); playback.audioMixer.reset() }
        for _ in 0..<100 where !playback.audioMixReady { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(playback.audioMixReady, playback.errorMessage ?? "Mixer not ready")
        playback.setAudioEnabled(0, true)
        playback.setAudioEnabled(1, true)
        playback.setAudioVolume(0, 0.2)
        playback.setAudioVolume(1, 0.7)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(playback.player.isMuted, "The original audio must not duplicate the composition")
        XCTAssertGreaterThan(playback.audioMixer.player.rate, 0)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: playback.audioMixer.player.currentItem)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(playback.playbackRequested)
        playback.togglePlayback()
        XCTAssertEqual(playback.audioMixer.player.rate, 0)
        playback.seek(to: 2)
        playback.seek(to: 7)
        playback.seek(to: 4)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(playback.snapshot.position, 4, accuracy: 0.05)
        XCTAssertEqual(playback.audioMixer.player.currentTime().seconds, 4, accuracy: 0.15)
        XCTAssertEqual(playback.audioMixer.player.rate, 0)
        playback.togglePlayback()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThan(playback.audioMixer.player.rate, 0)
        XCTAssertEqual(playback.audioMixer.player.currentTime().seconds, playback.player.currentTime().seconds, accuracy: 0.15)
    }

    @MainActor
    private func samples(_ mixer: EmbeddedAudioMixer) async throws -> [Float] {
        let item = try XCTUnwrap(mixer.player.currentItem)
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: item.asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        output.audioMix = item.audioMix
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var values: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [Float](repeating: 0, count: length / 4)
            let result = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            XCTAssertEqual(result, kCMBlockBufferNoErr)
            values.append(contentsOf: bytes)
        }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "")
        XCTAssertEqual(values.count, 48_000)
        return values
    }

    private func amplitude(_ samples: [Float], at frequency: Double) -> Double {
        let sum = samples.enumerated().reduce(0.0) { $0 + Double($1.element) * sin(2 * .pi * frequency * Double($1.offset) / 48_000) }
        return abs(2 * sum / Double(samples.count))
    }
}
