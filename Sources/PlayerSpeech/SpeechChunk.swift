import Foundation
import PlayerCore

public struct SpeechChunk: Identifiable, Equatable, Sendable {
    public let id: Int
    public let start: TimeInterval
    public let end: TimeInterval
    public let document: SubtitleDocument
    public init(id: Int, start: TimeInterval, end: TimeInterval, document: SubtitleDocument) {
        self.id = id; self.start = start; self.end = end; self.document = document
    }
}

public struct PreparedSpeechChunk: Equatable, Sendable {
    public let chunk: SpeechChunk
    public let audioURL: URL
    public init(chunk: SpeechChunk, audioURL: URL) { self.chunk = chunk; self.audioURL = audioURL }
}

public enum SpeechChunkPlanner {
    /// One voice cannot speak simultaneous cues. Display subtitles keep their original timing.
    public static func forSynthesis(_ document: SubtitleDocument) throws -> SubtitleDocument {
        var result: [SubtitleCue] = []
        for cue in document.cues {
            if let previous = result.last, cue.start < previous.end {
                result[result.count - 1] = .init(identifier: previous.id, start: previous.start,
                    end: max(previous.end, cue.end), text: previous.text + " " + cue.text)
            } else { result.append(cue) }
        }
        return try SubtitleDocument(cues: result)
    }

    /// Short first buffer, then larger windows. Never split a cue or cross
    /// overlapping cues; prefer a sentence ending or a genuine source pause.
    public static func makePlan(_ document: SubtitleDocument) throws -> [SpeechChunk] {
        let cues = document.cues
        guard cues.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end < 1_000_000_000 }) else {
            throw SpeechFailure.failed
        }
        var result: [SpeechChunk] = []
        var first = 0
        var start = 0.0
        var furthestEnd = 0.0
        for index in cues.indices {
            let cue = cues[index]
            furthestEnd = max(furthestEnd, cue.end)
            let last = index == cues.count - 1
            let nextStart = last ? furthestEnd : cues[index + 1].start
            let noOverlap = nextStart >= furthestEnd
            let sentenceEnd = cue.text.range(of: #"[.!?…][»\"')]*\s*$"#, options: .regularExpression) != nil
            let pause = nextStart - furthestEnd >= 1
            let target = result.isEmpty ? 12.0 : 40.0
            let enough = furthestEnd - start >= target
            if last || (noOverlap && enough && (sentenceEnd || pause || furthestEnd - start >= 90)) {
                let relative = try SubtitleDocument(cues: cues[first...index].map {
                    .init(identifier: $0.id, start: $0.start - start, end: $0.end - start, text: $0.text)
                })
                result.append(.init(id: result.count, start: start, end: nextStart, document: relative))
                first = index + 1
                start = nextStart
            }
        }
        return result
    }

    public static func needed(_ plan: [SpeechChunk], at position: TimeInterval,
                              prepared: Set<Int>, ahead: TimeInterval = 60) -> [SpeechChunk] {
        plan.filter { $0.end > position && $0.start < position + ahead && !prepared.contains($0.id) }
    }

    public static func bufferedSeconds(_ plan: [SpeechChunk], at position: TimeInterval, prepared: Set<Int>) -> TimeInterval {
        var end = position
        for chunk in plan where chunk.end > position {
            guard chunk.start <= end, prepared.contains(chunk.id) else { break }
            end = chunk.end
        }
        return max(0, end - position)
    }
}
