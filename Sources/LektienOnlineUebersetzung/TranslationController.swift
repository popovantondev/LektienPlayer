import Foundation
import Combine
import PlayerCore
import PlayerTranslation

func translationText(_ key: String) -> String {
    let resources = Bundle.main.url(forResource: "LektienOnlineUebersetzung_LektienOnlineUebersetzung", withExtension: "bundle")
        .flatMap(Bundle.init(url:)) ?? .module
    return AppLocalization.text(key, bundle: resources)
}

@MainActor
final class TranslationController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isReview = false
    @Published private(set) var status: String?
    @Published private(set) var progress: TranslationProgress?
    @Published private(set) var result: TranslationResult?
    private var cancellation: TranslationCancellation?
    private var generation = UUID()
    private var modelReviewIDs = Set<Int>()

    func start(document: SubtitleDocument, videoURL: URL, settings: TranslationSettings, reviewDraft: SubtitleDocument? = nil) {
        guard !isRunning else { return }
        guard let executable = CodexClient.installedExecutable() else {
            status = TranslationFailure.missingCLI.localizedDescription
            return
        }
        let token = UUID()
        let flags = modelReviewIDs
        generation = token
        let control = TranslationCancellation()
        cancellation = control
        isRunning = true
        isReview = reviewDraft != nil
        progress = nil
        result = nil
        status = translationText(reviewDraft == nil ? "translation.starting" : "review.starting")
        let observer: @Sendable (TranslationProgress) -> Void = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isRunning else { return }
                self.progress = value
                self.status = String(format: translationText(reviewDraft == nil ? "translation.progress" : "review.progress"), value.completed, value.total)
                    + String(format: translationText("translation.usage"), value.requests, value.cached)
            }
        }
        Task { [weak self] in
            let work = Task.detached {
                let glossary = TranslationPreparation.matchingTerms(try TranslationPreparation.loadGlossary(for: videoURL), cues: document.cues)
                let selected = reviewDraft.map { TranslationPreparation.reviewSelection(source: document, draft: $0, modelFlags: flags) }
                return try TranslationSession.run(document: document, videoURL: videoURL, settings: settings,
                                           cancellation: control,
                                           reviewDraft: reviewDraft,
                                           reviewIDs: selected,
                                           glossary: glossary,
                                           translate: { cues, settings, control in
                    let ids = Set(cues.map(\.identifier))
                    let draft = reviewDraft?.cues.filter { ids.contains($0.identifier) }
                        .map { TranslationResponse.Row(id: $0.identifier, text: $0.text) }
                    let context = TranslationPreparation.context(source: document, selectedIDs: ids)
                    return try CodexClient(executable: executable).translate(cues: cues, settings: settings, cancellation: control,
                        draft: draft, glossary: glossary, context: context)
                }, progress: observer)
            }
            do {
                let value = try await work.value
                guard let self, self.generation == token else { return }
                self.result = value
                self.modelReviewIDs = value.uncertainIDs
                self.status = (reviewDraft == nil ? String(format: translationText("translation.saved"), value.subtitleURL.lastPathComponent)
                    : String(format: translationText("review.saved"), value.reviewedCues, document.cues.count))
                    + String(format: translationText("translation.usage"), value.requests, value.cached)
            } catch {
                guard let self, self.generation == token else { return }
                self.status = error.localizedDescription
            }
            self?.isRunning = false
            self?.cancellation = nil
        }
    }

    func stop() {
        cancellation?.cancel()
        status = translationText("translation.stopping")
    }

    func reset() {
        cancellation?.cancel()
        cancellation = nil
        isRunning = false
        generation = UUID()
        status = nil
        progress = nil
        result = nil
        modelReviewIDs = []
    }

    deinit { cancellation?.cancel() }
}
