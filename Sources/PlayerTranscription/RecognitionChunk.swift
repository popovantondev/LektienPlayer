import Foundation
import PlayerCore
import PlayerMedia

public struct RecognitionChunk: Identifiable, Equatable, Sendable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let document: SubtitleDocument

    public init(id: Int, start: Double, end: Double, document: SubtitleDocument) {
        self.id = id; self.start = start; self.end = end; self.document = document
    }

    public static func plan(duration: Double) throws -> [Self] {
        guard duration.isFinite, duration > 0, duration <= 604_800 else { throw MediaFailure.invalidOutput }
        let empty = try SubtitleDocument(cues: [])
        return (0..<Int(ceil(duration / 30))).map { index in
            .init(id: index, start: Double(index) * 30, end: min(duration, Double(index + 1) * 30), document: empty)
        }
    }

    public func withDocument(_ document: SubtitleDocument) throws -> Self {
        guard document.cues.count < 1000 else { throw MediaFailure.invalidOutput }
        let cues = try SubtitleDocument(cues: document.cues.enumerated().map { index, cue in
            // SRT persists millisecond timestamps; the final video interval can end between milliseconds.
            guard cue.start >= start - 0.00051, cue.end <= end + 0.00051 else { throw MediaFailure.invalidOutput }
            return .init(identifier: id * 1000 + index + 1, start: max(start, cue.start), end: min(end, cue.end), text: cue.text)
        })
        return .init(id: id, start: start, end: end, document: cues)
    }
}

/// Padded decoding provides acoustic context; only words owned by this interval are published.
public enum RecognitionOutput {
    private struct Output: Decodable { let transcription: [Segment] }
    private struct Offset: Decodable { let from: Double; let to: Double }
    private struct Token: Decodable { let text: String; let offsets: Offset; let id: Int }
    private struct Segment: Decodable { let text: String; let offsets: Offset; let tokens: [Token]? }
    private struct Word { var text: String; let start: Double; var end: Double }

    public static func parse(_ data: Data, chunk: RecognitionChunk, inputStart: Double) throws -> RecognitionChunk {
        let output = try JSONDecoder().decode(Output.self, from: data)
        var cues: [SubtitleCue] = []
        for segment in output.transcription {
            let start = inputStart + segment.offsets.from / 1000
            let end = inputStart + segment.offsets.to / 1000
            guard start.isFinite, end.isFinite, end >= start else { throw MediaFailure.invalidOutput }
            guard end > chunk.start, start < chunk.end else { continue }
            var text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var ownedStart = max(start, chunk.start)
            var ownedEnd = min(end, chunk.end)
            if start < chunk.start || end > chunk.end {
                var words: [Word] = []
                for token in segment.tokens ?? [] where token.id < 50257 {
                    let a = inputStart + token.offsets.from / 1000
                    let b = inputStart + token.offsets.to / 1000
                    guard a.isFinite, b.isFinite, b >= a else { continue }
                    if token.text.first?.isWhitespace == true || words.isEmpty {
                        words.append(.init(text: token.text, start: a, end: b))
                    } else {
                        words[words.count - 1].text += token.text
                        words[words.count - 1].end = max(words[words.count - 1].end, b)
                    }
                }
                // A different token clock must fail visibly instead of silently discarding a sentence.
                if !words.isEmpty, words.allSatisfy({ $0.end <= start || $0.start >= end }) {
                    throw MediaFailure.invalidOutput
                }
                let owned = words.filter { let midpoint = ($0.start + $0.end) / 2; return midpoint >= chunk.start && midpoint < chunk.end }
                text = owned.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                ownedStart = max(ownedStart, owned.first?.start ?? ownedStart)
                ownedEnd = min(ownedEnd, owned.last?.end ?? ownedEnd)
            }
            guard !text.isEmpty, ownedEnd > ownedStart else { continue }
            cues.append(.init(identifier: cues.count + 1, start: ownedStart, end: ownedEnd, text: text))
        }
        let texts = cues.map { $0.text.lowercased() }
        if texts.count >= 4 {
            for index in 3..<texts.count where texts[index].count > 12 && Set(texts[(index - 3)...index]).count == 1 {
                throw MediaFailure.invalidOutput
            }
        }
        // Decoder timestamps can overlap at a speaker change. Merge connected intervals,
        // retaining decoder text order instead of moving the end of a sentence after the next speaker.
        var groups: [[(Int, SubtitleCue)]] = []
        for item in cues.enumerated().sorted(by: { $0.element.start < $1.element.start }) {
            if let previous = groups.last, item.element.start < previous.map({ $0.1.end }).max()! {
                groups[groups.count - 1].append((item.offset, item.element))
            } else { groups.append([(item.offset, item.element)]) }
        }
        let normalized = groups.enumerated().map { index, group in
            SubtitleCue(identifier: index + 1, start: group.map { $0.1.start }.min()!, end: group.map { $0.1.end }.max()!,
                        text: group.sorted { $0.0 < $1.0 }.map { $0.1.text }.joined(separator: " "))
        }
        return try chunk.withDocument(SubtitleDocument(cues: normalized))
    }
}
