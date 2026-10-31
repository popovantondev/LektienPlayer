import Foundation
import Combine
import PlayerCore
import PlayerSpeech
import PlayerTranslation

struct TranslationWindow: Identifiable, Sendable {
    let id: Int
    let chunks: [SpeechChunk]
    let source: SubtitleDocument
    var start: Double { chunks.first?.start ?? 0 }
    var end: Double { chunks.last?.end ?? 0 }

    static func plan(_ chunks: [SpeechChunk], source: SubtitleDocument) throws -> [TranslationWindow] {
        var groups: [[SpeechChunk]] = []
        var pending: [SpeechChunk] = []
        var characters = 0
        for chunk in chunks {
            let size = chunk.document.cues.reduce(0) { $0 + $1.text.count }
            if !pending.isEmpty && characters + size > 10_000 {
                groups.append(pending); pending = []; characters = 0
            }
            pending.append(chunk)
            characters += size
            // A short first packet reduces startup delay; later packets amortize request overhead.
            if (groups.isEmpty && pending.count >= 2) || chunk.end - pending[0].start >= 180 {
                groups.append(pending); pending = []; characters = 0
            }
        }
        if !pending.isEmpty { groups.append(pending) }
        return try groups.enumerated().map { index, chunks in
            let ids = Set(chunks.flatMap { $0.document.cues.map(\.id) })
            return .init(id: index, chunks: chunks, source: try SubtitleDocument(cues: source.cues.filter { ids.contains($0.id) }))
        }
    }

    func assembled(known: [SubtitleCue], received: SubtitleDocument) throws -> SubtitleDocument {
        var rows: [Int: String] = [:]
        for cue in known + received.cues { rows[cue.id] = cue.text }
        return try SubtitleDocument(cues: source.cues.map { cue in
            guard let text = rows[cue.id] else { throw TranslationFailure.invalidResponse }
            return .init(identifier: cue.id, start: cue.start, end: cue.end, text: text)
        })
    }

    func translatedChunks(_ document: SubtitleDocument) throws -> [SpeechChunk] {
        let rows = Dictionary(uniqueKeysWithValues: document.cues.map { ($0.id, $0) })
        return try chunks.map { chunk in
            let relative = try SubtitleDocument(cues: chunk.document.cues.map { cue in
                guard let row = rows[cue.id] else { throw TranslationFailure.invalidResponse }
                return .init(identifier: row.id, start: row.start - chunk.start, end: row.end - chunk.start, text: row.text)
            })
            return .init(id: chunk.id, start: chunk.start, end: chunk.end, document: relative)
        }
    }
}

private struct CachedTranslationWindow: Sendable {
    let window: TranslationWindow
    var draft: SubtitleDocument?
    var flags = Set<Int>()
    var known: [SubtitleCue] = []
    var reviewed: SubtitleDocument?
    var glossary: [GlossaryTerm] = []
}

@MainActor
final class StreamingTranslationController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var ready: [SpeechChunk] = []
    @Published private(set) var activeRange: ClosedRange<Double>?
    @Published private(set) var status: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var completedURL: URL?
    private(set) var requestCount = 0
    private(set) var cacheHitCount = 0
    private(set) var plan: [SpeechChunk] = []
    var bufferAhead = 240.0
    var prepareWholeLecture = false
    private var position = 0.0
    private var task: Task<Void, Never>?
    private var cancellation: TranslationCancellation?
    private var generation = UUID()
    private var recognized: [Int: SpeechChunk] = [:]

    func supplyRecognized(_ chunks: [SpeechChunk]) {
        for chunk in chunks where plan.contains(where: { $0.id == chunk.id && $0.start == chunk.start && $0.end == chunk.end }) {
            recognized[chunk.id] = chunk
        }
    }

    func startRecognizing(plan: [SpeechChunk], videoURL: URL, translation: TranslationSettings, review: TranslationSettings,
                          position: Double, translate: TranslationSession.Translate? = nil) {
        guard let empty = try? SubtitleDocument(cues: []) else { return }
        start(source: empty, videoURL: videoURL, translation: translation, review: review,
              position: position, translate: translate, recognitionPlan: plan)
    }

    private func recognizedWindows() throws -> [TranslationWindow] {
        var windows: [TranslationWindow] = []
        var index = 0
        while index < plan.count {
            let end = min(plan.count, index + (index == 0 ? 1 : 3))
            let ids = plan[index..<end].map(\.id)
            let chunks = ids.compactMap { recognized[$0] }
            if chunks.count == ids.count {
                let document = try SubtitleDocument(cues: chunks.flatMap { chunk in
                    chunk.document.cues.map { .init(identifier: $0.id, start: $0.start + chunk.start, end: $0.end + chunk.start, text: $0.text) }
                })
                windows.append(.init(id: index, chunks: chunks, source: document))
            }
            index = end
        }
        return windows
    }

    var document: SubtitleDocument? {
        try? SubtitleDocument(cues: ready.sorted { $0.id < $1.id }.flatMap { chunk in
            chunk.document.cues.map { .init(identifier: $0.id, start: $0.start + chunk.start, end: $0.end + chunk.start, text: $0.text) }
        })
    }

    func start(source: SubtitleDocument, videoURL: URL, translation: TranslationSettings, review: TranslationSettings,
               position: Double, translate: TranslationSession.Translate? = nil, recognitionPlan: [SpeechChunk]? = nil) {
        reset()
        let windows: [TranslationWindow]
        do {
            plan = try recognitionPlan ?? SpeechChunkPlanner.makePlan(source)
            windows = try recognitionPlan == nil ? TranslationWindow.plan(plan, source: source) : []
            guard !plan.isEmpty else { throw TranslationFailure.invalidInput }
        } catch { errorMessage = error.localizedDescription; status = errorMessage; return }
        self.position = position
        isRunning = true
        status = translationText("stream.loading")
        let token = generation
        let control = TranslationCancellation()
        cancellation = control
        task = Task { [weak self] in
            do {
                let setup = try await Task.detached {
                    let allTerms = try TranslationPreparation.loadGlossary(for: videoURL)
                    let glossary = recognitionPlan == nil ? TranslationPreparation.matchingTerms(allTerms, cues: source.cues) : allTerms
                    let legacy = try source.cues.isEmpty ? nil : TranslationSession.cachedPartial(document: source, videoURL: videoURL, settings: translation, glossary: glossary)
                    let legacyRows = Dictionary(uniqueKeysWithValues: (legacy?.0.cues ?? []).map { ($0.id, $0) })
                    let cached = try windows.map { window in
                        var value = CachedTranslationWindow(window: window)
                        value.glossary = TranslationPreparation.matchingTerms(glossary, cues: window.source.cues)
                        value.known = window.source.cues.compactMap { legacyRows[$0.id] }
                        value.flags = (legacy?.1 ?? []).intersection(Set(value.known.map(\.id)))
                        var cachedDraft = try TranslationSession.cachedDocument(document: window.source, videoURL: videoURL,
                            settings: translation, glossary: glossary, contextDocument: source)
                        if cachedDraft == nil && window.source.cues.allSatisfy({ legacyRows[$0.id] != nil }) {
                            cachedDraft = (try SubtitleDocument(cues: value.known), value.flags)
                        }
                        if let draft = cachedDraft {
                            value.draft = draft.0; value.flags = draft.1
                            let ids = TranslationPreparation.reviewSelection(source: window.source, draft: draft.0, modelFlags: draft.1)
                            value.reviewed = try TranslationSession.cachedDocument(document: window.source, videoURL: videoURL,
                                settings: review, reviewDraft: draft.0, reviewIDs: ids, glossary: glossary, contextDocument: source)?.0
                        }
                        return value
                    }
                    return (glossary, cached)
                }.value
                guard self?.generation == token else { return }
                let glossary = setup.0
                var cached = setup.1
                var requests = 0
                var hits = cached.reduce(0) { $0 + ($1.draft == nil ? 0 : 1) + ($1.reviewed == nil ? 0 : 1) }
                self?.cacheHitCount = hits
                self?.ready = try cached.flatMap { entry in
                    try entry.reviewed.map { try entry.window.translatedChunks($0) } ?? []
                }
                while !Task.isCancelled {
                    guard let self, self.generation == token else { return }
                    if recognitionPlan != nil {
                        let knownWindows = Set(cached.map { $0.window.id })
                        let incoming = try self.recognizedWindows().filter { !knownWindows.contains($0.id) }
                        if !incoming.isEmpty {
                            let entries = try await Task.detached {
                                try incoming.map { window in
                                    var entry = CachedTranslationWindow(window: window)
                                    entry.glossary = TranslationPreparation.matchingTerms(glossary, cues: window.source.cues)
                                    if window.source.cues.isEmpty {
                                        entry.reviewed = window.source
                                    } else if let draft = try TranslationSession.cachedDocument(document: window.source, videoURL: videoURL,
                                        settings: translation, glossary: entry.glossary, contextDocument: window.source) {
                                        entry.draft = draft.0; entry.flags = draft.1
                                        let ids = TranslationPreparation.reviewSelection(source: window.source, draft: draft.0, modelFlags: draft.1)
                                        entry.reviewed = try TranslationSession.cachedDocument(document: window.source, videoURL: videoURL,
                                            settings: review, reviewDraft: draft.0, reviewIDs: ids, glossary: entry.glossary, contextDocument: window.source)?.0
                                    }
                                    return entry
                                }
                            }.value
                            guard self.generation == token else { return }
                            hits += entries.reduce(0) { $0 + ($1.draft == nil ? 0 : 1) + ($1.reviewed == nil ? 0 : 1) }
                            self.cacheHitCount = hits
                            for entry in entries {
                                if let document = entry.reviewed { self.ready.append(contentsOf: try entry.window.translatedChunks(document)) }
                            }
                            cached.append(contentsOf: entries)
                            cached.sort { $0.window.start < $1.window.start }
                        }
                    }
                    if !cached.isEmpty && cached.allSatisfy({ $0.reviewed != nil }) && self.ready.count == self.plan.count {
                        guard let document = self.document else { throw TranslationFailure.invalidResponse }
                        let url = try await Task.detached { try TranslationSession.export(document: document, videoURL: videoURL, reviewed: true) }.value
                        guard self.generation == token else { return }
                        self.completedURL = url
                        self.status = translationText("stream.complete") + Self.usage(requests, hits)
                        self.isRunning = false
                        self.activeRange = nil
                        self.cancellation = nil
                        return
                    }
                    let nearby = cached.firstIndex(where: { $0.window.end > self.position && $0.window.start < self.position + self.bufferAhead && $0.reviewed == nil })
                    guard let index = nearby ?? (self.prepareWholeLecture ? cached.firstIndex(where: { $0.reviewed == nil }) : nil) else {
                        self.activeRange = nil
                        let readyIDs = Set(self.ready.map(\.id))
                        let waiting = recognitionPlan != nil && self.plan.contains { $0.end > self.position && $0.start < self.position + self.bufferAhead && !readyIDs.contains($0.id) }
                        self.status = translationText(waiting ? "recognition.waiting" : "stream.bufferReady") + Self.usage(requests, hits)
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    let entry = cached[index]
                    let context = recognitionPlan == nil ? source : entry.window.source
                    let reviewing = entry.draft != nil
                    self.activeRange = entry.window.start...entry.window.end
                    self.status = translationText(reviewing ? "stream.reviewing" : "stream.translating") + Self.usage(requests, hits)
                    let result = try await Task.detached {
                        let selected = entry.draft.map { TranslationPreparation.reviewSelection(source: entry.window.source, draft: $0, modelFlags: entry.flags) }
                        let knownIDs = Set(entry.known.map(\.id))
                        let requested = try SubtitleDocument(cues: entry.window.source.cues.filter { reviewing || !knownIDs.contains($0.id) })
                        let result = try TranslationSession.run(document: requested, videoURL: videoURL,
                            settings: reviewing ? review : translation, cancellation: control, reviewDraft: entry.draft,
                            reviewIDs: selected, glossary: entry.glossary, contextDocument: context, publishAlongsideVideo: false,
                            translate: { cues, settings, cancellation in
                                if let translate { return try translate(cues, settings, cancellation) }
                                guard let executable = CodexClient.installedExecutable() else { throw TranslationFailure.missingCLI }
                                let ids = Set(cues.map(\.id))
                                let draft = entry.draft?.cues.filter { ids.contains($0.id) }.map { TranslationResponse.Row(id: $0.id, text: $0.text) }
                                return try CodexClient(executable: executable).translate(cues: cues, settings: settings, cancellation: cancellation,
                                    draft: draft, glossary: entry.glossary, context: TranslationPreparation.context(source: context, selectedIDs: ids))
                            }, progress: { _ in })
                        let document = reviewing ? result.document : try entry.window.assembled(known: entry.known, received: result.document)
                        let flags = reviewing ? result.uncertainIDs : result.uncertainIDs.union(entry.flags)
                        if !reviewing && !entry.known.isEmpty {
                            try TranslationSession.storeCompleted(source: entry.window.source, document: document, videoURL: videoURL,
                                settings: translation, uncertainIDs: flags, glossary: entry.glossary, contextDocument: context)
                        }
                        return (result, document, flags)
                    }.value
                    guard self.generation == token else { return }
                    requests += result.0.requests; hits += result.0.cached
                    self.requestCount = requests; self.cacheHitCount = hits
                    if reviewing {
                        cached[index].reviewed = result.1
                        self.ready.append(contentsOf: try entry.window.translatedChunks(result.1))
                    } else {
                        cached[index].draft = result.1
                        cached[index].flags = result.2
                    }
                    // Finish and cache an in-flight response; choose the next request at the latest seek position.
                    self.activeRange = nil
                }
            } catch {
                guard let self, self.generation == token else { return }
                if Task.isCancelled || (error as? TranslationFailure) == .stopped {
                    self.status = translationText("stream.stopped")
                } else {
                    self.errorMessage = error.localizedDescription
                    self.status = error.localizedDescription
                }
            }
            guard let self, self.generation == token else { return }
            self.isRunning = false
            self.activeRange = nil
            self.cancellation = nil
        }
    }

    func updatePosition(_ value: Double) { if value.isFinite { position = max(0, value) } }
    func stop() { task?.cancel(); cancellation?.cancel() }
    func reset() {
        generation = UUID()
        stop()
        task = nil; cancellation = nil
        isRunning = false; ready = []; plan = []; activeRange = nil
        status = nil; errorMessage = nil; completedURL = nil
        recognized = [:]
        prepareWholeLecture = false
        requestCount = 0; cacheHitCount = 0
    }
    private static func usage(_ requests: Int, _ hits: Int) -> String {
        String(format: translationText("translation.usage"), requests, hits)
    }
    deinit { task?.cancel(); cancellation?.cancel() }
}
