import Combine
import Foundation
import PlayerCore

@MainActor
final class PreparationController: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case ready(SubtitlePreparationPlan)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var generation = UUID()

    func reset() { generation = UUID(); state = .idle }

    func prepare(document: SubtitleDocument) {
        let token = UUID()
        generation = token
        state = .preparing
        let work = Task.detached {
            try SubtitlePreparer.makePlan(document: document)
        }
        Task { [weak self] in
            do {
                let plan = try await work.value
                guard self?.generation == token else { return }
                self?.state = .ready(plan)
            } catch {
                guard self?.generation == token else { return }
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    var statusText: String? {
        switch state {
        case .idle: return nil
        case .preparing: return translationText("preparation.running")
        case .ready(let plan):
            let warning = plan.oversizedCueIDs.isEmpty ? "" : String(format: translationText("preparation.long"), plan.oversizedCueIDs.count)
            return String(format: translationText("preparation.complete"), plan.cueCount, plan.segments.count, warning)
        case .failed(let message): return message
        }
    }
}
