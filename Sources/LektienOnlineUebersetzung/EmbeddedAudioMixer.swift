@preconcurrency import AVFoundation
import PlayerCore

struct EmbeddedAudioTrack: Identifiable {
    let id: Int
    var title: String
    let languageCode: String?
    var enabled: Bool
    var volume: Double = 1
}

/// One audio-only composition keeps embedded tracks on the same clock without exporting media.
@MainActor
final class EmbeddedAudioMixer {
    let player = AVPlayer()
    private var compositionTracks: [AVMutableCompositionTrack] = []
    private var seeking = false
    private var generation = 0

    func prepare(asset: AVAsset) async throws -> [EmbeddedAudioTrack] {
        let composition = AVMutableComposition()
        let sources = try await asset.loadTracks(withMediaType: .audio)
        var tracks: [AVMutableCompositionTrack] = []
        var choices: [EmbeddedAudioTrack] = []
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            let range = try await source.load(.timeRange)
            let extendedLanguage = try await source.load(.extendedLanguageTag)
            let languageCode = try await source.load(.languageCode)
            let language = extendedLanguage ?? languageCode
            let enabled = try await source.load(.isEnabled)
            guard let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw NSError(domain: "EmbeddedAudioMixer", code: 1)
            }
            // Preserve delayed track starts and edits in the original movie timeline.
            try destination.insertTimeRange(range, of: source, at: range.start)
            tracks.append(destination)
            let name = language.flatMap { AppLocalization.locale.localizedString(forLanguageCode: $0) }
                ?? translationText("player.primaryAudio")
            choices.append(.init(id: index, title: "\(index + 1). \(name)", languageCode: language, enabled: enabled))
        }
        try Task.checkCancellation()
        compositionTracks = tracks
        if !choices.isEmpty {
            let initial = choices.firstIndex(where: \.enabled) ?? 0
            for index in choices.indices { choices[index].enabled = index == initial }
            player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
            apply(choices)
        }
        return choices
    }

    func apply(_ choices: [EmbeddedAudioTrack]) {
        let mix = AVMutableAudioMix()
        mix.inputParameters = zip(compositionTracks, choices).map { track, choice in
            let input = AVMutableAudioMixInputParameters(track: track)
            input.setVolume(choice.enabled ? Float(choice.volume) : 0, at: .zero)
            return input
        }
        player.currentItem?.audioMix = mix
    }

    func reset() {
        generation += 1
        seeking = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        compositionTracks = []
    }

    func pause() { player.pause() }

    func synchronize(with video: AVPlayer, force: Bool = false) {
        guard player.currentItem?.status == .readyToPlay else { return }
        let time = video.currentTime()
        guard time.seconds.isFinite else { return }
        let playing = video.rate > 0 && video.timeControlStatus == .playing
        if !playing { player.pause() }
        guard !seeking else { return }
        let drift = abs(player.currentTime().seconds - time.seconds)
        if force || drift > 0.15 {
            player.pause()
            seeking = true
            let currentGeneration = generation
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak video] finished in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration else { return }
                    self.seeking = false
                    guard finished, let video else { return }
                    self.synchronize(with: video)
                }
            }
        } else if playing && player.rate == 0 {
            player.play()
        }
    }
}
