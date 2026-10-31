import Foundation
import Combine
import PlayerCore
import PlayerTranslation
import PlayerSpeech

@MainActor
final class SpeechController: ObservableObject {
    func refreshIdleLanguage() {
        guard !isRunning else { return }
        status = translationText(plan.isEmpty ? "speech.ready" : "speech.stoppedBuffer")
    }
    @Published private(set) var isRunning = false
    @Published private(set) var status = translationText("speech.ready")
    @Published private(set) var prepared: [PreparedSpeechChunk] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var activeChunk: Int?
    private(set) var plan: [SpeechChunk] = []
    private var available: [Int: SpeechChunk] = [:]
    private var preparationEnabled = true
    private var cancellation: SpeechCancellation?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var bufferAhead = 180.0
    var prepareWholeLecture = false
    private var position = 0.0

    func start(document: SubtitleDocument, videoURL: URL, voice: String, position: TimeInterval) {
        do {
            let chunks = try SpeechChunkPlanner.makePlan(document)
            start(plan: chunks, documents: chunks, videoURL: videoURL, voice: voice, position: position)
        } catch { errorMessage = error.localizedDescription; status = error.localizedDescription }
    }

    func startStreaming(plan: [SpeechChunk], videoURL: URL, voice: String, position: Double) {
        start(plan: plan, documents: [], videoURL: videoURL, voice: voice, position: position)
    }

    func supply(_ chunks: [SpeechChunk]) {
        for chunk in chunks where plan.contains(where: { $0.id == chunk.id && $0.start == chunk.start && $0.end == chunk.end }) {
            available[chunk.id] = chunk
        }
    }

    func setPreparationEnabled(_ enabled: Bool) {
        preparationEnabled = enabled
        if !enabled && !prepareWholeLecture { cancellation?.cancel() }
    }

    /// Re-check only speech caches after dictionary edits; translation keeps running unchanged.
    func reloadPronunciation(videoURL: URL, voice: String, position: Double) {
        let chunks = Array(available.values)
        let currentPlan = plan
        let enabled = preparationEnabled
        start(plan: currentPlan, documents: chunks, videoURL: videoURL, voice: voice, position: position)
        preparationEnabled = enabled
    }

    private func start(plan: [SpeechChunk], documents: [SpeechChunk], videoURL: URL, voice: String, position: Double) {
        let previousTask = task
        reset()
        guard !plan.isEmpty else { return }
        self.plan = plan
        available = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        let token = generation
        self.position = position
        preparationEnabled = true
        isRunning = true
        status = translationText("speech.starting")
        task = Task { [weak self] in
            // Wait for cancellation to release the old cache lock before starting another worker.
            await previousTask?.value
            var inspected = Set<Int>()
            while !Task.isCancelled {
                guard let self, self.generation == token else { return }
                let unchecked = self.available.values.filter { !inspected.contains($0.id) }
                if !unchecked.isEmpty {
                    do {
                        let cached = try await Task.detached {
                            try unchecked.compactMap { chunk -> PreparedSpeechChunk? in
                                if chunk.document.cues.isEmpty {
                                    return .init(chunk: chunk, audioURL: try SpeechSession.silentAudio(duration: chunk.end - chunk.start, videoURL: videoURL))
                                }
                                let url = try SpeechSession.cachedAudio(srt: TranslationSession.srt(SpeechChunkPlanner.forSynthesis(chunk.document)), videoURL: videoURL, voice: voice)
                                return url.map { .init(chunk: chunk, audioURL: $0) }
                            }
                        }.value
                        guard self.generation == token else { return }
                        self.prepared.append(contentsOf: cached)
                        inspected.formUnion(unchecked.map(\.id))
                    } catch {
                        guard self.generation == token else { return }
                        self.errorMessage = error.localizedDescription
                        self.status = error.localizedDescription
                        self.isRunning = false
                        return
                    }
                }
                let completed = Set(self.prepared.map { $0.chunk.id })
                if completed.count == self.plan.count {
                    self.status = translationText("speech.allReady")
                    self.isRunning = false
                    return
                }
                let nearby = SpeechChunkPlanner.needed(self.plan, at: self.position, prepared: completed, ahead: self.bufferAhead).first
                let required = nearby.flatMap { self.available[$0.id] } ?? (self.prepareWholeLecture ? self.plan.first { !completed.contains($0.id) && self.available[$0.id] != nil } : nil)
                guard self.preparationEnabled || self.prepareWholeLecture, let required, let chunk = self.available[required.id] else {
                    self.status = translationText(!self.preparationEnabled && !self.prepareWholeLecture ? "speech.disabled" : nearby != nil || self.prepareWholeLecture ? "speech.waitingTranslation" : "speech.bufferIdle")
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
                    continue
                }
                let control = SpeechCancellation()
                self.cancellation = control
                self.activeChunk = chunk.id
                self.status = String(format: translationText("speech.chunk"), chunk.id + 1, self.plan.count)
                do {
                    let result = try await Task.detached {
                        let source = TranslationSession.srt(try SpeechChunkPlanner.forSynthesis(chunk.document))
                        return try SpeechSession.run(srt: source, videoURL: videoURL, voice: voice, cancellation: control, progress: { _, _ in })
                    }.value
                    guard self.generation == token else { return }
                    self.prepared.append(.init(chunk: chunk, audioURL: result.audioURL))
                } catch {
                    guard self.generation == token else { return }
                    if Task.isCancelled { break }
                    if (error as? SpeechFailure) != .stopped {
                        self.errorMessage = error.localizedDescription
                        self.status = error.localizedDescription
                        self.isRunning = false
                        self.activeChunk = nil
                        self.cancellation = nil
                        return
                    }
                }
                self.activeChunk = nil
                self.cancellation = nil
            }
            guard let self, self.generation == token else { return }
            self.isRunning = false
            self.activeChunk = nil
            self.cancellation = nil
            self.status = translationText("speech.stoppedBuffer")
        }
    }

    func updatePosition(_ position: TimeInterval) {
        guard position.isFinite else { return }
        self.position = position
        if let activeChunk,
           !SpeechChunkPlanner.needed(plan, at: position, prepared: [], ahead: bufferAhead).contains(where: { $0.id == activeChunk }),
           !prepareWholeLecture || SpeechChunkPlanner.needed(plan, at: position, prepared: Set(prepared.map { $0.chunk.id }), ahead: bufferAhead).contains(where: { available[$0.id] != nil }) {
            cancellation?.cancel()
        }
    }

    func stop() { task?.cancel(); cancellation?.cancel(); status = translationText("speech.stopping") }
    func reset() {
        generation = UUID()
        task?.cancel(); cancellation?.cancel()
        task = nil; cancellation = nil
        isRunning = false; activeChunk = nil
        prepared = []; plan = []; available = [:]
        prepareWholeLecture = false
        errorMessage = nil
        status = translationText("speech.ready")
    }
    deinit { task?.cancel(); cancellation?.cancel() }
}
