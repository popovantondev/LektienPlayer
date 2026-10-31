import Foundation
import XCTest
import PlayerCore
@testable import PlayerTranslation

final class TranslationSessionTests: XCTestCase {
    private let settings = TranslationSettings(model: "gpt-5.6-terra", effort: "medium")

    func testLiveCodexOnlyWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["LEKTIEN_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in network smoke test, synthetic subtitles only")
        }
        let executable = try XCTUnwrap(CodexClient.installedExecutable())
        let cues = [SubtitleCue(identifier: 1, start: 0, end: 2, text: "Guten Morgen."),
                    SubtitleCue(identifier: 2, start: 3, end: 5, text: "Heute sprechen wir über das Herz.")]
        let reply = try CodexClient(executable: executable).translate(cues: cues,
            settings: .init(model: "gpt-6-astra", effort: "low"), cancellation: .init())
        let rows = try reply.validated(for: [1, 2])
        XCTAssertTrue(rows[2]?.lowercased().contains("серд") == true)
        print("Synthetic translation: \(rows)")
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testStopResumePreservesPartsTimingAndExistingResult() throws {
        let root = try temporaryDirectory()
        let video = root.appendingPathComponent("lesson.mp4")
        let existing = root.appendingPathComponent("lesson.ru.srt")
        try Data("original result".utf8).write(to: existing)
        let document = try SubtitleDocument(cues: [
            SubtitleCue(identifier: 1, start: 1.125, end: 3.789, text: String(repeating: "a", count: 9_900)),
            SubtitleCue(identifier: 2, start: 4.5, end: 5.6, text: String(repeating: "b", count: 9_900))
        ])
        let control = TranslationCancellation()
        XCTAssertThrowsError(try TranslationSession.run(document: document, videoURL: video, settings: settings,
            cancellation: control, translate: { cues, _, _ in
                XCTAssertEqual(cues.map(\.identifier), [1])
                return TranslationResponse(translations: [.init(id: 1, text: "Первый")])
            }, progress: { _ in control.cancel() })) { error in
                XCTAssertEqual(error as? TranslationFailure, .stopped)
            }
        let resumed = try TranslationSession.run(document: document, videoURL: video, settings: settings,
            cancellation: TranslationCancellation(), translate: { cues, _, _ in
                XCTAssertEqual(cues.map(\.identifier), [2], "First part must come from disk")
                return TranslationResponse(translations: [.init(id: 2, text: "Второй")])
            }, progress: { _ in })
        XCTAssertNotEqual(resumed.subtitleURL, existing)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original result")
        XCTAssertEqual(resumed.document.cues.map(\.start), document.cues.map(\.start))
        XCTAssertEqual(resumed.document.cues.map(\.end), document.cues.map(\.end))
        XCTAssertEqual(try SRTParser.parse(data: Data(contentsOf: resumed.subtitleURL)), resumed.document)
        let cached = try TranslationSession.run(document: document, videoURL: video, settings: settings,
            cancellation: TranslationCancellation(), translate: { _, _, _ in
                XCTFail("A completed translation must not be requested again")
                throw TranslationFailure.service
            }, progress: { _ in })
        XCTAssertEqual(cached.subtitleURL, resumed.subtitleURL)
    }

    func testChangedSettingsDoNotReuseOldTranslation() throws {
        let root = try temporaryDirectory()
        let source = try SubtitleDocument(cues: [.init(identifier: 1, start: 0, end: 1, text: "Hallo")])
        for effort in ["low", "medium"] {
            let result = try TranslationSession.run(document: source, videoURL: root.appendingPathComponent("a.mp4"),
                settings: .init(model: "gpt-6-astra", effort: effort), cancellation: TranslationCancellation(),
                translate: { _, settings, _ in .init(translations: [.init(id: 1, text: settings.effort)]) }, progress: { _ in })
            XCTAssertEqual(result.document.cues.first?.text, effort)
        }
    }

    func testReviewHasSeparateCacheAndKeepsPriorTranslation() throws {
        let root = try temporaryDirectory()
        let video = root.appendingPathComponent("lesson.mp4")
        let source = try SubtitleDocument(cues: [.init(identifier: 1, start: 0, end: 2, text: "Herz")])
        let draft = try SubtitleDocument(cues: [.init(identifier: 1, start: 0, end: 2, text: "Лёгкие")])
        let original = root.appendingPathComponent("lesson.ru.srt")
        try Data(TranslationSession.srt(draft).utf8).write(to: original)
        let review = try TranslationSession.run(document: source, videoURL: video, settings: settings,
            cancellation: .init(), reviewDraft: draft,
            translate: { _, _, _ in .init(translations: [.init(id: 1, text: "Сердце")]) }, progress: { _ in })
        XCTAssertEqual(review.subtitleURL.lastPathComponent, "lesson.ru.reviewed.srt")
        XCTAssertEqual(try SRTParser.parse(data: Data(contentsOf: original)), draft)
        let cached = try TranslationSession.run(document: source, videoURL: video, settings: settings,
            cancellation: .init(), reviewDraft: draft,
            translate: { _, _, _ in XCTFail("Review should resume from disk"); throw TranslationFailure.service }, progress: { _ in })
        XCTAssertEqual(cached.subtitleURL, review.subtitleURL)
        let changedDraft = try SubtitleDocument(cues: [.init(identifier: 1, start: 0, end: 2, text: "Мозг")])
        XCTAssertThrowsError(try TranslationSession.run(document: source, videoURL: video, settings: settings,
            cancellation: .init(), reviewDraft: changedDraft,
            translate: { _, _, _ in throw TranslationFailure.stopped }, progress: { _ in })) {
                XCTAssertEqual($0 as? TranslationFailure, .stopped)
            }
    }

    func testLiveLunaTranslationAndTerraReviewOnlyWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["LEKTIEN_LIVE_SMOKE"] == "1" else { throw XCTSkip("Opt-in network check") }
        let client = CodexClient(executable: try XCTUnwrap(CodexClient.installedExecutable()))
        let cues = [SubtitleCue(identifier: 103001, start: 0, end: 3, text: "Heute sprechen wir über das Herz.")]
        let translated = try client.translate(cues: cues, settings: .init(model: "gpt-5.6-luna", effort: "medium"), cancellation: .init())
        XCTAssertTrue(try translated.validated(for: [103001])[103001]!.lowercased().contains("серд"))
        let checked = try client.translate(cues: cues, settings: .init(model: "gpt-5.6-terra", effort: "medium"), cancellation: .init(),
            draft: [.init(id: 103001, text: "Сегодня мы говорим о лёгких.")],
            context: [.init(id: 102010, text: "Guten Tag.")])
        XCTAssertTrue(try checked.validated(for: [103001])[103001]!.lowercased().contains("серд"))
    }

    func testInvalidReplyNotPersistedOrExported() throws {
        let root = try temporaryDirectory()
        let source = try SubtitleDocument(cues: [.init(identifier: 1, start: 0, end: 1, text: "Hallo")])
        XCTAssertThrowsError(try TranslationSession.run(document: source, videoURL: root.appendingPathComponent("a.mp4"),
            settings: settings, cancellation: TranslationCancellation(),
            translate: { _, _, _ in .init(translations: [.init(id: 99, text: "Привет")]) }, progress: { _ in }))
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        XCTAssertFalse(files.contains { $0.pathExtension == "json" || $0.pathExtension == "srt" })
    }

    func testDuplicateSourceIDsRejected() throws {
        let root = try temporaryDirectory()
        let cue = SubtitleCue(identifier: 1, start: 0, end: 1, text: "Hallo")
        XCTAssertThrowsError(try TranslationSession.run(document: SubtitleDocument(cues: [cue, cue]),
            videoURL: root.appendingPathComponent("a.mp4"), settings: settings, cancellation: TranslationCancellation(),
            translate: { _, _, _ in XCTFail(); throw TranslationFailure.service }, progress: { _ in }))
    }

    func testRepairRequestsOnlyDamagedCachedRowAndPreservesPreviousFiles() throws {
        let root = try temporaryDirectory()
        let video = root.appendingPathComponent("lesson.mp4")
        let source = try SubtitleDocument(cues: [.init(identifier: 1, start: 0, end: 2, text: "Hallo"),
            .init(identifier: 2, start: 3, end: 5, text: "Welt")])
        _ = try TranslationSession.run(document: source, videoURL: video, settings: settings, cancellation: .init(),
            publishAlongsideVideo: false, translate: { _, _, _ in .init(translations: [.init(id: 1, text: "Привет"), .init(id: 2, text: "Мир")]) }, progress: { _ in })
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        var previous: [URL: Data] = [:]
        for file in files where file.pathExtension == "json" {
            let old = try JSONDecoder().decode(TranslationResponse.self, from: Data(contentsOf: file))
            let damaged = TranslationResponse(translations: old.translations.map { .init(id: $0.id, text: $0.id == 2 ? "М��р" : $0.text) }, reviewIDs: old.reviewIDs)
            let data = try JSONEncoder().encode(damaged)
            try data.write(to: file); previous[file] = data
        }
        XCTAssertNil(try TranslationSession.cachedDocument(document: source, videoURL: video, settings: settings))
        XCTAssertEqual(try TranslationSession.cachedPartial(document: source, videoURL: video, settings: settings)?.0.cues.map(\.id), [1])
        let repaired = try TranslationSession.run(document: source, videoURL: video, settings: settings, cancellation: .init(),
            publishAlongsideVideo: false, translate: { cues, _, _ in
                XCTAssertEqual(cues.map(\.id), [2])
                return .init(translations: [.init(id: 2, text: "Мир")])
            }, progress: { _ in })
        XCTAssertEqual(repaired.requests, 1)
        XCTAssertEqual(repaired.document.cues.map(\.text), ["Привет", "Мир"])
        XCTAssertEqual(repaired.subtitleURL.lastPathComponent, "result.repaired.ru.srt")
        for (file, data) in previous { XCTAssertEqual(try Data(contentsOf: file), data) }
        let cached = try TranslationSession.run(document: source, videoURL: video, settings: settings, cancellation: .init(),
            publishAlongsideVideo: false, translate: { _, _, _ in XCTFail("Repaired rows must be cached"); throw TranslationFailure.service }, progress: { _ in })
        XCTAssertEqual(cached.requests, 0)
        XCTAssertEqual(cached.document, repaired.document)
        XCTAssertEqual(try TranslationSession.cachedDocument(document: source, videoURL: video, settings: settings)?.0, repaired.document)
    }

    func testFailedTextCorrectionIsBoundedAndNeverPublished() throws {
        let root = try temporaryDirectory()
        let source = try SubtitleDocument(cues: [.init(identifier: 1, start: 0, end: 2, text: "Hallo")])
        XCTAssertThrowsError(try TranslationSession.run(document: source, videoURL: root.appendingPathComponent("v.mp4"), settings: settings,
            cancellation: .init(), translate: { _, _, _ in .init(translations: [.init(id: 1, text: "�")]) }, progress: { _ in }))
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        XCTAssertFalse(files.contains { $0.pathExtension == "json" || $0.pathExtension == "srt" })
    }

    func testProcessSuccessTimeoutAndCancellation() throws {
        let root = try temporaryDirectory()
        let executable = root.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\"translations\":{\"1\":\"Привет\"},\"reviewIDs\":[]}"}}' '{"type":"turn.completed"}'
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let cues = [SubtitleCue(identifier: 1, start: 0, end: 1, text: "Hallo")]
        let reply = try CodexClient(executable: executable).translate(cues: cues, settings: settings, cancellation: .init())
        XCTAssertEqual(try reply.validated(for: [1])[1], "Привет")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
        XCTAssertThrowsError(try CodexClient(executable: executable, timeout: 0.1).translate(cues: cues, settings: settings,
            cancellation: .init())) { XCTAssertEqual($0 as? TranslationFailure, .timeout) }
        let control = TranslationCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { control.cancel() }
        let started = Date()
        XCTAssertThrowsError(try CodexClient(executable: executable).translate(cues: cues, settings: settings,
            cancellation: control)) { XCTAssertEqual($0 as? TranslationFailure, .stopped) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testServiceFailureQuotaAndToolUseRejected() throws {
        for (events, expected) in [
            (#"{"type":"turn.failed","error":{"message":"usage limit reached"}}"#, TranslationFailure.quota),
            (#"{"type":"turn.failed","error":{"message":"This model requires a newer version of Codex"}}"#, .updateCLI),
            (#"{"type":"item.started","item":{"type":"command_execution"}}"#, .invalidResponse),
            (#"{"type":"thread.started"}"#, .service)
        ] {
            XCTAssertThrowsError(try CodexClient.parseEvents(Data(events.utf8), exitCode: 1, cueIDs: [1])) {
                XCTAssertEqual($0 as? TranslationFailure, expected)
            }
        }
    }

    func testWarningDoesNotRejectCompletedTranslation() throws {
        let events = #"""
        {"type":"item.completed","item":{"type":"error","message":"Optional feature unavailable"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"{\"translations\":{\"1\":\"Привет\"},\"reviewIDs\":[]}"}}
        {"type":"turn.completed"}
        """#
        XCTAssertEqual(try CodexClient.parseEvents(Data(events.utf8), exitCode: 0, cueIDs: [1]).validated(for: [1])[1], "Привет")
    }
}
