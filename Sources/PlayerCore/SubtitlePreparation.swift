import Foundation

public struct SubtitlePreparationSegment: Identifiable, Equatable, Sendable {
    public let index: Int
    public let cues: [SubtitleCue]
    public let estimatedCharacterCount: Int

    public var id: Int { index }
    public var cueIDs: [Int] { cues.map(\.identifier) }
}

public struct SubtitlePreparationPlan: Equatable, Sendable {
    public let segments: [SubtitlePreparationSegment]
    public let oversizedCueIDs: [Int]

    public var cueCount: Int { segments.reduce(0) { $0 + $1.cues.count } }
    public var estimatedCharacterCount: Int { segments.reduce(0) { $0 + $1.estimatedCharacterCount } }
}

public enum SubtitlePreparationError: LocalizedError, Equatable {
    case invalidLimits

    public var errorDescription: String? {
        switch self {
        case .invalidLimits: return AppLocalization.coreText("preparation.invalidLimits")
        }
    }
}

public enum SubtitlePreparer {
    public static func makePlan(
        document: SubtitleDocument,
        preferredCharacterLimit: Int = 10_000,
        hardCharacterLimit: Int = 14_000
    ) throws -> SubtitlePreparationPlan {
        guard preferredCharacterLimit > 0, hardCharacterLimit >= preferredCharacterLimit else {
            throw SubtitlePreparationError.invalidLimits
        }

        var segments: [SubtitlePreparationSegment] = []
        var pending: [SubtitleCue] = []
        var pendingCharacters = 0
        var oversized: [Int] = []

        func appendPending() {
            guard !pending.isEmpty else { return }
            segments.append(.init(index: segments.count + 1, cues: pending, estimatedCharacterCount: pendingCharacters))
            pending = []
            pendingCharacters = 0
        }

        for cue in document.cues {
            let size = estimatedSerializedLength(cue)
            if size > hardCharacterLimit { oversized.append(cue.identifier) }

            let nextSize = pendingCharacters + size
            let hasUsefulSize = pendingCharacters >= preferredCharacterLimit * 3 / 4
            if !pending.isEmpty && (nextSize > hardCharacterLimit || (nextSize > preferredCharacterLimit && hasUsefulSize)) {
                appendPending()
            }
            pending.append(cue)
            pendingCharacters += size
        }
        appendPending()
        return .init(segments: segments, oversizedCueIDs: oversized)
    }

    private static func estimatedSerializedLength(_ cue: SubtitleCue) -> Int {
        cue.text.utf16.count + 64
    }
}
