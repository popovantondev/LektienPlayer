@preconcurrency import AVFoundation
import AVKit
import Combine
import PlayerCore
import PlayerSpeech

struct MediaTrackChoice: Identifiable {
    let id: Int
    let title: String
}

@MainActor
final class PlaybackController: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var snapshot = PlaybackSnapshot()
    @Published private(set) var errorMessage: String?
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var audioTracks: [MediaTrackChoice] = []
    @Published private(set) var embeddedAudioTracks: [EmbeddedAudioTrack] = []
    @Published private(set) var audioMixReady = false
    let audioMixer = EmbeddedAudioMixer()
    @Published private(set) var subtitleTracks: [MediaTrackChoice] = []
    @Published private(set) var selectedAudioTrack = -1
    @Published private(set) var selectedSubtitleTrack = -1
    @Published private(set) var embeddedSubtitleText = ""
    private var subtitleOutput: EmbeddedSubtitleOutput?
    @Published var volume: Double = 1 { didSet { applyOriginalGain() } }
    @Published var duckingEnabled = true
    @Published var duckingLevel = 0.25
    private var ducking = DuckingEnvelope()
    nonisolated(unsafe) private var duckingTimer: Timer?
    @Published private(set) var hasRussianVoice = false
    @Published private(set) var externalVoiceName: String?
    @Published private(set) var externalVoiceStatus: String?
    @Published private(set) var waitingForSpeech = false
    @Published private(set) var speechBufferSeconds = 0.0
    @Published private(set) var playbackRequested = false
    @Published var russianVoiceEnabled = true { didSet { synchronizeVoice(force: true) } }
    @Published var russianVolume: Double = 1 { didSet { voicePlayer?.volume = Float(russianVolume) } }
    private(set) var voicePlayer: AVAudioPlayer?
    private var speechPlan: [SpeechChunk] = []
    private var speechFiles: [Int: URL] = [:]
    private var activeSpeechChunk: Int?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var seekGeneration = 0
    private var isSeeking = false
    private var itemObservations: [NSKeyValueObservation] = []
    private var trackLoading: Task<Void, Never>?

    nonisolated(unsafe) private var observer: Any?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?

    init() {
        player.appliesMediaSelectionCriteriaAutomatically = false
        duckingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateDucking() }
        }
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.update(time: time)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let endedItem = notification.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, let endedItem, endedItem === self.player.currentItem else { return }
                self.audioMixer.pause()
                self.snapshot.isPlaying = false
                self.playbackRequested = false
                self.voicePlayer?.pause()
            }
        }
    }

    deinit {
        duckingTimer?.invalidate()
        trackLoading?.cancel()
        if let observer { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(url: URL) {
        load(asset: AVURLAsset(url: url))
    }

    func load(asset: AVAsset) {
        seekGeneration += 1
        isSeeking = false
        clearVoice()
        trackLoading?.cancel()
        audioMixer.reset()
        embeddedAudioTracks = []
        audioMixReady = false
        player.isMuted = false
        audioGroup = nil
        subtitleGroup = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrack = -1
        selectedSubtitleTrack = -1
        embeddedSubtitleText = ""
        errorMessage = nil
        let item = AVPlayerItem(asset: asset)
        let legible = EmbeddedSubtitleOutput()
        legible.onText = { [weak self, weak item] text in
            guard let self, let item, self.player.currentItem === item else { return }
            let visible = self.selectedSubtitleTrack >= 0 ? text : ""
            if self.embeddedSubtitleText != visible { self.embeddedSubtitleText = visible }
        }
        item.add(legible.output)
        subtitleOutput = legible
        player.replaceCurrentItem(with: item)
        let refresh: @Sendable () -> Void = { [weak self, weak item] in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else { return }
                self.update(time: self.player.currentTime())
            }
        }
        // Periodic time observers do not tick while paused. Metadata must still update.
        itemObservations = [
            item.observe(\.status, options: [.initial, .new]) { _, _ in refresh() },
            item.observe(\.duration, options: [.initial, .new]) { _, _ in refresh() },
            item.observe(\.presentationSize, options: [.initial, .new]) { _, _ in refresh() }
        ]
        snapshot = PlaybackSnapshot()
        videoSize = .zero
        player.pause()
        playbackRequested = false
        snapshot.isPlaying = false
        trackLoading = Task { [weak self] in
            do {
                let audio = try await item.asset.loadMediaSelectionGroup(for: .audible)
                let subtitles = try await item.asset.loadMediaSelectionGroup(for: .legible)
                guard !Task.isCancelled, let self, self.player.currentItem === item else { return }
                self.audioGroup = audio
                self.subtitleGroup = subtitles
                self.refreshTrackLanguage()
                if let audio, let selected = item.currentMediaSelection.selectedMediaOption(in: audio) ?? audio.defaultOption ?? audio.options.first,
                   let index = audio.options.firstIndex(of: selected) { self.selectAudio(index) }
                self.selectSubtitle(-1)
                let choices = try await self.audioMixer.prepare(asset: item.asset)
                guard !Task.isCancelled, self.player.currentItem === item else { return }
                self.embeddedAudioTracks = choices
                self.audioMixReady = !choices.isEmpty
                self.player.isMuted = self.audioMixReady
                self.audioMixer.player.volume = Float(self.volume)
                self.audioMixer.synchronize(with: self.player, force: true)
            } catch {
                guard !Task.isCancelled, let self, self.player.currentItem === item else { return }
                self.errorMessage = translationText("player.trackError")
            }
        }
    }

    private func applyOriginalGain() {
        let gain = Float(volume * ducking.gain)
        player.volume = gain
        audioMixer.player.volume = gain
    }

    func refreshTrackLanguage() {
        audioTracks = audioGroup?.options.enumerated().map { .init(id: $0.offset, title: $0.element.displayName(with: AppLocalization.locale)) } ?? []
        subtitleTracks = subtitleGroup?.options.enumerated().map { .init(id: $0.offset, title: $0.element.displayName(with: AppLocalization.locale)) } ?? []
        for index in embeddedAudioTracks.indices {
            let name = embeddedAudioTracks[index].languageCode.flatMap { AppLocalization.locale.localizedString(forLanguageCode: $0) }
                ?? translationText("player.primaryAudio")
            embeddedAudioTracks[index].title = "\(index + 1). \(name)"
        }
    }

    private func updateDucking() {
        voicePlayer?.updateMeters()
        let speaking = russianVoiceEnabled && russianVolume > 0 && voicePlayer?.isPlaying == true
            && (voicePlayer?.averagePower(forChannel: 0) ?? -160) > -42
        _ = ducking.update(speaking: speaking, enabled: duckingEnabled, attenuation: duckingLevel,
                           time: ProcessInfo.processInfo.systemUptime, elapsed: 0.05)
        applyOriginalGain()
    }

    func selectAudio(_ id: Int) {
        guard let audioGroup, audioGroup.options.indices.contains(id) else { return }
        player.currentItem?.select(audioGroup.options[id], in: audioGroup)
        selectedAudioTrack = id
        for index in embeddedAudioTracks.indices { embeddedAudioTracks[index].enabled = index == id }
        audioMixer.apply(embeddedAudioTracks)
    }

    func setAudioEnabled(_ id: Int, _ enabled: Bool) {
        guard embeddedAudioTracks.indices.contains(id) else { return }
        embeddedAudioTracks[id].enabled = enabled
        audioMixer.apply(embeddedAudioTracks)
    }

    func setAudioVolume(_ id: Int, _ volume: Double) {
        guard embeddedAudioTracks.indices.contains(id) else { return }
        embeddedAudioTracks[id].volume = min(1, max(0, volume))
        audioMixer.apply(embeddedAudioTracks)
    }

    func selectSubtitle(_ id: Int) {
        embeddedSubtitleText = ""
        guard let subtitleGroup else { selectedSubtitleTrack = -1; return }
        guard id == -1 || subtitleGroup.options.indices.contains(id) else { return }
        player.currentItem?.select(id == -1 ? nil : subtitleGroup.options[id], in: subtitleGroup)
        selectedSubtitleTrack = id
    }

    func togglePlayback() { playbackRequested ? pause() : play() }

    func play() {
        guard player.currentItem != nil else { return }
        playbackRequested = true
        player.play()
        snapshot.isPlaying = true
        synchronizeVoice(force: true)
    }

    func pause() {
        playbackRequested = false
        player.pause()
        snapshot.isPlaying = false
        synchronizeVoice(force: true)
    }

    func startWithSpeech(plan: [SpeechChunk]) {
        player.pause()
        playbackRequested = true
        snapshot.isPlaying = true
        beginSpeech(plan: plan)
        if !waitingForSpeech { player.play() }
    }

    func attachVoice(url: URL) throws {
        let audio = try AVAudioPlayer(contentsOf: url)
        audio.isMeteringEnabled = true
        audio.volume = Float(russianVolume)
        audio.prepareToPlay()
        voicePlayer?.stop()
        voicePlayer = audio
        hasRussianVoice = true
        externalVoiceName = url.lastPathComponent
        externalVoiceStatus = nil
        russianVoiceEnabled = true
        synchronizeVoice(force: true)
    }

    func clearVoice() {
        voicePlayer?.stop()
        voicePlayer = nil
        hasRussianVoice = false
        externalVoiceName = nil
        externalVoiceStatus = nil
        speechPlan = []
        speechFiles = [:]
        activeSpeechChunk = nil
        speechBufferSeconds = 0
        if waitingForSpeech && playbackRequested { player.play() }
        waitingForSpeech = false
    }

    func setExternalVoiceUnavailable() {
        clearVoice()
        externalVoiceStatus = translationText("attachment.audioMissing")
    }

    func beginSpeech(plan: [SpeechChunk]) {
        clearVoice()
        speechPlan = plan
        hasRussianVoice = !plan.isEmpty
        russianVoiceEnabled = true
        synchronizeVoice(force: true)
    }

    func acceptSpeech(_ chunks: [PreparedSpeechChunk]) {
        speechFiles = Dictionary(uniqueKeysWithValues: chunks.map { ($0.chunk.id, $0.audioURL) })
        synchronizeVoice(force: true)
    }

    private func synchronizeVoice(force: Bool = false) {
        guard !isSeeking else { return }
        defer { audioMixer.synchronize(with: player) }
        let position = player.currentTime().seconds
        guard position.isFinite else { return }
        var audioPosition = position
        if !speechPlan.isEmpty {
            let ready = Set(speechFiles.keys)
            speechBufferSeconds = SpeechChunkPlanner.bufferedSeconds(speechPlan, at: position, prepared: ready)
            let chunk = speechPlan.first { $0.start <= position && position < $0.end }
            if russianVoiceEnabled, let chunk {
                let remaining = max(0, (speechPlan.last?.end ?? position) - position)
                let enough = speechBufferSeconds >= min(8, remaining)
                if speechFiles[chunk.id] == nil || (waitingForSpeech && !enough) {
                    voicePlayer?.pause()
                    waitingForSpeech = playbackRequested
                    if playbackRequested { player.pause() }
                    return
                }
                if activeSpeechChunk != chunk.id, let url = speechFiles[chunk.id] {
                    do {
                        let audio = try AVAudioPlayer(contentsOf: url)
                        audio.isMeteringEnabled = true
                        audio.volume = Float(russianVolume)
                        audio.prepareToPlay()
                        voicePlayer?.stop()
                        voicePlayer = audio
                        activeSpeechChunk = chunk.id
                    } catch {
                        errorMessage = error.localizedDescription
                        playbackRequested = false
                        player.pause()
                        return
                    }
                }
                audioPosition -= chunk.start
            } else {
                voicePlayer?.pause()
                if waitingForSpeech && playbackRequested { player.play() }
                waitingForSpeech = false
                return
            }
            if waitingForSpeech && playbackRequested { player.play() }
            waitingForSpeech = false
        }
        guard let voicePlayer else { return }
        guard russianVoiceEnabled, audioPosition < voicePlayer.duration else { voicePlayer.pause(); return }
        if force || abs(voicePlayer.currentTime - audioPosition) > 0.15 { voicePlayer.currentTime = max(0, audioPosition) }
        if player.rate > 0 && player.timeControlStatus == .playing {
            if !voicePlayer.isPlaying { voicePlayer.play() }
        } else { voicePlayer.pause() }
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite, player.currentItem != nil else { return }
        embeddedSubtitleText = ""
        seekGeneration += 1
        let generation = seekGeneration
        isSeeking = true
        voicePlayer?.pause()
        audioMixer.pause()
        let position = min(max(0, seconds), snapshot.duration ?? max(0, seconds))
        snapshot.position = position
        let target = CMTime(seconds: position, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.isSeeking = false
                guard finished else { return }
                self.synchronizeVoice(force: true)
                self.audioMixer.synchronize(with: self.player, force: true)
            }
        }
    }

    private func update(time: CMTime) {
        if audioMixReady && audioMixer.player.currentItem?.status == .failed {
            audioMixer.reset()
            audioMixReady = false
            embeddedAudioTracks = []
            player.isMuted = false
            errorMessage = translationText("mixer.failed")
        }
        if player.currentItem?.status == .failed {
            errorMessage = translationText("player.unsupported")
            snapshot.isPlaying = false
        }
        if let size = player.currentItem?.presentationSize, size.width > 0, size.height > 0, size != videoSize {
            videoSize = size
        }
        let position = time.seconds.isFinite ? max(0, time.seconds) : 0
        let rawDuration = player.currentItem?.duration.seconds
        let duration = rawDuration?.isFinite == true && rawDuration! > 0 ? rawDuration : nil
        if !isSeeking { snapshot.position = position }
        snapshot.duration = duration
        synchronizeVoice()
    }
}
