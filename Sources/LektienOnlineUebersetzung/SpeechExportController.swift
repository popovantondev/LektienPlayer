import Combine
import Foundation
import PlayerCore
import PlayerSpeech
import PlayerMedia
import PlayerExport

@MainActor
final class SpeechExportController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress = 0.0
    @Published private(set) var result: URL?
    @Published private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    private var cancellation: MediaCancellation?
    private var generation = UUID()

    func start(plan: [SpeechChunk], prepared: [PreparedSpeechChunk], duration: Double,
               german: SubtitleDocument?, destination: URL, video: VideoExportRequest? = nil) {
        reset()
        let token = generation
        let control = MediaCancellation()
        cancellation = control
        isRunning = true
        let report: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor [weak self] in
                if self?.generation == token { self?.progress = value }
            }
        }
        task = Task { [weak self] in
            do {
                let url = try await Task.detached(priority: .utility) {
                    try SpeechExport.save(plan: plan, prepared: prepared, duration: duration, german: german,
                                          destination: destination, cancellation: control, video: video, progress: report)
                }.value
                guard let self, self.generation == token else { return }
                self.result = url
            } catch {
                guard let self, self.generation == token else { return }
                if !Task.isCancelled && (error as? MediaFailure) != .stopped { self.errorMessage = error.localizedDescription }
            }
            guard let self, self.generation == token else { return }
            self.isRunning = false
            self.cancellation = nil
            self.task = nil
        }
    }

    func reset() {
        generation = UUID()
        task?.cancel(); cancellation?.cancel()
        task = nil; cancellation = nil
        isRunning = false; progress = 0; result = nil; errorMessage = nil
    }
    deinit { task?.cancel(); cancellation?.cancel() }
}
