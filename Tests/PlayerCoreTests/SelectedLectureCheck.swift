import XCTest
import PlayerCore
import PlayerTranslation

final class SelectedLectureCheck: XCTestCase {
    func testExplicitlySelectedFirstNinetySeconds() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LEKTIEN_SELECTED_DE"], let output = environment["LEKTIEN_SELECTED_OUTPUT"] else {
            throw XCTSkip("Requires explicit user-selected source and output; uses Luna and Terra")
        }
        let complete = try SRTParser.parse(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let source = try SubtitleDocument(cues: Array(complete.cues.prefix { $0.end <= 90 }))
        let video = URL(fileURLWithPath: output).appendingPathComponent("First-90-seconds.mp4")
        let glossary = try TranslationPreparation.loadGlossary(for: URL(fileURLWithPath: path))
        let client = CodexClient(executable: try XCTUnwrap(CodexClient.installedExecutable()))
        let translated = try TranslationSession.run(document: source, videoURL: video,
            settings: .init(model: "gpt-5.6-luna", effort: "medium"), cancellation: .init(), glossary: glossary,
            translate: { cues, settings, control in try client.translate(cues: cues, settings: settings, cancellation: control, glossary: glossary) }, progress: { _ in })
        let selected = TranslationPreparation.reviewSelection(source: source, draft: translated.document, modelFlags: translated.uncertainIDs)
        let reviewed = try TranslationSession.run(document: source, videoURL: video,
            settings: .init(model: "gpt-5.6-terra", effort: "medium"), cancellation: .init(), reviewDraft: translated.document, reviewIDs: selected, glossary: glossary,
            translate: { cues, settings, control in
                let ids = Set(cues.map(\.id))
                return try client.translate(cues: cues, settings: settings, cancellation: control,
                    draft: translated.document.cues.filter { ids.contains($0.id) }.map { .init(id: $0.id, text: $0.text) },
                    glossary: glossary, context: TranslationPreparation.context(source: source, selectedIDs: ids))
            }, progress: { _ in })
        XCTAssertEqual(reviewed.document.cues.count, source.cues.count)
        print("Preview: \(reviewed.subtitleURL.path); Luna requests: \(translated.requests); Terra requests: \(reviewed.requests); reviewed: \(reviewed.reviewedCues)/\(source.cues.count)")
    }
}
