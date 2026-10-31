import Foundation
import Combine
import PlayerCore
import PlayerMedia
import PlayerTranscription
import PlayerSpeech

@MainActor
final class RecognitionController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var ready: [RecognitionChunk] = []
    @Published private(set) var activeRange: ClosedRange<Double>?
    @Published private(set) var status: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var completedURL: URL?
    private(set) var plan: [RecognitionChunk] = []
    var bufferAhead = 600.0
    var prepareWholeLecture = false
    private var position = 0.0
    private var task: Task<Void, Never>?
    private var cancellation: MediaCancellation?
    private var generation = UUID()

    var speechPlan: [SpeechChunk] {
        plan.map { .init(id: $0.id, start: $0.start, end: $0.end, document: $0.document) }
    }
    var sourceChunks: [SpeechChunk] {
        ready.compactMap { chunk in
            guard let relative = try? SubtitleDocument(cues: chunk.document.cues.map {
                .init(identifier: $0.id, start: $0.start - chunk.start, end: $0.end - chunk.start, text: $0.text)
            }) else { return nil }
            return .init(id: chunk.id, start: chunk.start, end: chunk.end, document: relative)
        }
    }
    var document: SubtitleDocument? {
        try? SubtitleDocument(cues: ready.sorted { $0.id < $1.id }.flatMap { $0.document.cues })
    }

    func start(video: URL, streamIndex: Int, duration: Double, position: Double,
               mediaURL: URL? = nil, mediaIdentity: String? = nil) {
        reset()
        do { plan = try RecognitionChunk.plan(duration: duration) }
        catch { errorMessage = error.localizedDescription; return }
        self.position = position
        isRunning = true
        status = translationText("recognition.loading")
        let token = generation
        let setupControl = MediaCancellation()
        cancellation = setupControl
        let planned = plan
        task = Task { [weak self] in
            do {
                let setup = try await Task.detached {
                    let session: RecognitionSession
                    if let mediaURL, let mediaIdentity {
                        session = try RecognitionSession(video: video, mediaURL: mediaURL, identity: mediaIdentity,
                                                         streamIndex: streamIndex, duration: duration, cancellation: setupControl)
                    } else {
                        session = try RecognitionSession(video: video, streamIndex: streamIndex, duration: duration, cancellation: setupControl)
                    }
                    return (session, try planned.compactMap { try session.cached($0) })
                }.value
                guard self?.generation == token else { return }
                self?.ready = setup.1
                while !Task.isCancelled {
                    guard let self, self.generation == token else { return }
                    if self.ready.count == self.plan.count {
                        guard let document = self.document else { throw MediaFailure.invalidOutput }
                        let url = try await Task.detached { try MediaPublication.subtitles(document, video: video, language: "de") }.value
                        guard self.generation == token else { return }
                        self.completedURL = url
                        self.status = translationText("recognition.complete")
                        break
                    }
                    let completed = Set(self.ready.map(\.id))
                    let start = Self.windowStart(at: self.position)
                    let nearby = self.plan.first { $0.end > start && $0.start < self.position + self.bufferAhead && !completed.contains($0.id) }
                    guard let chunk = nearby ?? (self.prepareWholeLecture ? self.plan.first { !completed.contains($0.id) } : nil) else {
                        self.activeRange = nil
                        self.status = translationText("recognition.bufferReady")
                        try await Task.sleep(for: .milliseconds(200))
                        continue
                    }
                    let control = MediaCancellation()
                    self.cancellation = control
                    self.activeRange = chunk.start...chunk.end
                    self.status = String(
                        format: translationText("recognition.chunk"),
                        self.ready.count,
                        self.plan.count,
                        chunk.id + 1
                    )
                    do {
                        let recognized = try await Task.detached { try setup.0.recognize(chunk, cancellation: control) }.value
                        guard self.generation == token else { return }
                        self.ready.append(recognized)
                    } catch {
                        guard self.generation == token else { return }
                        if Task.isCancelled { throw MediaFailure.stopped }
                        if (error as? MediaFailure) != .stopped { throw error }
                    }
                    self.activeRange = nil
                }
            } catch {
                guard let self, self.generation == token else { return }
                if Task.isCancelled || (error as? MediaFailure) == .stopped { self.status = translationText("recognition.stopped") }
                else { self.errorMessage = error.localizedDescription; self.status = error.localizedDescription }
            }
            guard let self, self.generation == token else { return }
            self.isRunning = false; self.activeRange = nil; self.cancellation = nil
        }
    }

    static func windowStart(at position: Double) -> Double {
        let index = Int(max(0, position) / 30)
        return index == 0 ? 0 : Double(1 + ((index - 1) / 3) * 3) * 30
    }
    func updatePosition(_ position: Double) {
        guard position.isFinite else { return }
        self.position = max(0, position)
        let completed = Set(ready.map(\.id))
        let needsNearby = plan.contains { $0.end > Self.windowStart(at: position) && $0.start < position + bufferAhead && !completed.contains($0.id) }
        if let range = activeRange, range.upperBound <= Self.windowStart(at: position) || range.lowerBound >= position + bufferAhead,
           !prepareWholeLecture || needsNearby {
            cancellation?.cancel()
        }
    }
    func stop() { task?.cancel(); cancellation?.cancel() }
    func reset() {
        generation = UUID(); stop(); task = nil; cancellation = nil
        isRunning = false; ready = []; plan = []; activeRange = nil
        status = nil; errorMessage = nil; completedURL = nil; prepareWholeLecture = false
    }
    deinit { task?.cancel(); cancellation?.cancel() }
}
