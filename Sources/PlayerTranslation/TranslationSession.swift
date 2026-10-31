import Foundation
import CryptoKit
import Darwin
import PlayerCore

public struct TranslationProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let document: SubtitleDocument
    public let requests: Int
    public let cached: Int
}

public struct TranslationResult: Sendable {
    public let document: SubtitleDocument
    public let subtitleURL: URL
    public let uncertainIDs: Set<Int>
    public let requests: Int
    public let cached: Int
    public let reviewedCues: Int
}

public enum TranslationSession {
    public typealias Translate = @Sendable ([SubtitleCue], TranslationSettings, TranslationCancellation) throws -> TranslationResponse

    public static func run(document: SubtitleDocument, videoURL: URL, settings: TranslationSettings,
                           cancellation: TranslationCancellation,
                           reviewDraft: SubtitleDocument? = nil,
                           reviewIDs: Set<Int>? = nil,
                           glossary: [GlossaryTerm] = [],
                           contextDocument: SubtitleDocument? = nil,
                           publishAlongsideVideo: Bool = true,
                           translate: Translate,
                           progress: @Sendable (TranslationProgress) -> Void) throws -> TranslationResult {
        let (root, _) = try location(document: document, videoURL: videoURL, settings: settings,
            reviewDraft: reviewDraft, reviewIDs: reviewIDs, glossary: glossary, contextDocument: contextDocument)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let descriptor = open(root.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw TranslationFailure.busy }
        defer { flock(descriptor, LOCK_UN) }
        let requested = try SubtitleDocument(cues: document.cues.filter { reviewDraft == nil || reviewIDs == nil || reviewIDs!.contains($0.id) })
        let plan = try SubtitlePreparer.makePlan(document: requested)
        var translated = Dictionary(uniqueKeysWithValues: (reviewDraft?.cues ?? []).map { ($0.id, $0.text) })
        var uncertainIDs = Set<Int>()
        var pronunciationHints: [PronunciationHint] = []
        var requests = 0
        var cached = 0
        let sharedParts = DerivedCacheLocation.directory(for: videoURL, category: "translation-parts")
        try FileManager.default.createDirectory(at: sharedParts, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        for segment in plan.segments {
            try cancellation.check()
            let part = root.appendingPathComponent("part-\(segment.index).json")
            struct PartIdentity: Encodable {
                let contract = "prepared-text-v2"
                let settings: TranslationSettings
                let source: [TranslationResponse.Row]
                let draft: [TranslationResponse.Row]?
                let context: [TranslationResponse.Row]
                let glossary: [GlossaryTerm]
            }
            let segmentIDs = Set(segment.cueIDs)
            let partIdentity = PartIdentity(settings: settings,
                source: segment.cues.map { .init(id: $0.id, text: $0.text) },
                draft: reviewDraft?.cues.filter { segmentIDs.contains($0.id) }.map { .init(id: $0.id, text: $0.text) },
                context: TranslationPreparation.context(source: contextDocument ?? document, selectedIDs: segmentIDs),
                glossary: TranslationPreparation.matchingTerms(glossary, cues: segment.cues))
            let partHash = SHA256.hash(data: try encoder.encode(partIdentity)).map { String(format: "%02x", $0) }.joined()
            let reusable = sharedParts.appendingPathComponent("\(partHash).json")
            let partLock = open(sharedParts.appendingPathComponent("\(partHash).lock").path, O_CREAT | O_RDWR, 0o600)
            guard partLock >= 0 else { throw POSIXError(.EACCES) }
            defer { close(partLock) }
            guard flock(partLock, LOCK_EX | LOCK_NB) == 0 else { throw TranslationFailure.busy }
            defer { flock(partLock, LOCK_UN) }
            var reply: TranslationResponse
            let stored = [repairedURL(part), repairedURL(reusable), part, reusable].first { FileManager.default.fileExists(atPath: $0.path) }
            if let stored {
                cached += 1
                do {
                    reply = try JSONDecoder().decode(TranslationResponse.self, from: Data(contentsOf: stored))
                    try reply.validateIdentifiers(for: segment.cueIDs)
                } catch { throw TranslationFailure.corruptCache }
            } else {
                requests += 1
                reply = try translate(segment.cues, settings, cancellation)
            }
            try reply.validateIdentifiers(for: segment.cueIDs)
            let invalid = invalidTextIDs(reply)
            if !invalid.isEmpty {
                // A single bounded correction keeps every valid row and its timing, including old caches.
                requests += 1
                let correction = try translate(segment.cues.filter { invalid.contains($0.id) }, settings, cancellation)
                let corrected = try correction.validated(for: segment.cueIDs.filter { invalid.contains($0) })
                reply = .init(translations: reply.translations.map { .init(id: $0.id, text: corrected[$0.id] ?? $0.text) },
                    reviewIDs: Set(reply.reviewIDs ?? []).subtracting(invalid).union(correction.reviewIDs ?? []).sorted(),
                    pronunciations: (reply.pronunciations ?? []).filter { !invalid.contains($0.id) } + (correction.pronunciations ?? []))
            }
            _ = try reply.validated(for: segment.cueIDs)
            // Corrections are new sidecars; previously saved files remain untouched.
            _ = try publishResponse(reply, to: reusable, encoder: encoder)
            _ = try publishResponse(reply, to: part, encoder: encoder)
            try PronunciationHintCache.store(reply, video: videoURL)
            pronunciationHints += reply.pronunciations ?? []
            translated.merge(try reply.validated(for: segment.cueIDs)) { _, new in new }
            uncertainIDs.formUnion(reply.reviewIDs ?? [])
            let partial = try replacing(document, with: translated)
            progress(.init(completed: segment.index, total: plan.segments.count, document: partial, requests: requests, cached: cached))
        }
        try cancellation.check()
        let result = try replacing(document, with: translated)
        let data = Data(srt(result).utf8)
        let completion = TranslationResponse(translations: result.cues.map { .init(id: $0.id, text: $0.text) },
            reviewIDs: uncertainIDs.sorted(), pronunciations: pronunciationHints.isEmpty ? nil : pronunciationHints)
        let completionURL = try publishResponse(completion, to: root.appendingPathComponent("completed.json"), encoder: encoder)
        if !publishAlongsideVideo {
            let destination = root.appendingPathComponent(completionURL.lastPathComponent == "completed.json" ? "result.ru.srt" : "result.repaired.ru.srt")
            try publishOrVerify(data, to: destination)
            return .init(document: result, subtitleURL: destination, uncertainIDs: uncertainIDs,
                         requests: requests, cached: cached, reviewedCues: reviewDraft == nil ? 0 : requested.cues.count)
        }
        let destination = try export(document: result, videoURL: videoURL, reviewed: reviewDraft != nil)
        return .init(document: result, subtitleURL: destination, uncertainIDs: uncertainIDs,
                     requests: requests, cached: cached, reviewedCues: reviewDraft == nil ? 0 : requested.cues.count)
    }

    /// Publish only a complete document, never overwrite an existing subtitle file.
    public static func export(document: SubtitleDocument, videoURL: URL, reviewed: Bool = false) throws -> URL {
        let data = Data(srt(document).utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var base = videoURL.deletingPathExtension()
        if ["ru", "de"].contains(base.pathExtension.lowercased()) { base.deletePathExtension() }
        let stem = base.lastPathComponent
        let parent = videoURL.deletingLastPathComponent()
        let language = reviewed ? "ru.reviewed" : "ru"
        var suffix = 0
        while true {
            let name = suffix == 0 ? "\(stem).\(language).srt" : "\(stem).\(language).\(hash.prefix(10)).\(suffix).srt"
            let destination = parent.appendingPathComponent(name)
            do { try publishNew(data, to: destination); return destination }
            catch let error as POSIXError where error.code == .EEXIST {
                if (try? Data(contentsOf: destination)) == data { return destination }
                suffix += 1
            }
        }
    }

    /// Recover validated parts of the previous whole-document session without any requests.
    public static func cachedPartial(document: SubtitleDocument, videoURL: URL, settings: TranslationSettings,
                                     glossary: [GlossaryTerm] = []) throws -> (SubtitleDocument, Set<Int>)? {
        let (root, _) = try location(document: document, videoURL: videoURL, settings: settings,
            reviewDraft: nil, reviewIDs: nil, glossary: glossary, contextDocument: nil)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        var rows: [Int: String] = [:]
        var flags = Set<Int>()
        for segment in try SubtitlePreparer.makePlan(document: document).segments {
            let file = preferredURL(root.appendingPathComponent("part-\(segment.index).json"))
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                let response = try JSONDecoder().decode(TranslationResponse.self, from: Data(contentsOf: file))
                try response.validateIdentifiers(for: segment.cueIDs)
                let invalid = invalidTextIDs(response)
                let valid = response.translations.filter { !invalid.contains($0.id) }
                if !valid.isEmpty {
                    rows.merge(try TranslationResponse(translations: valid).validated(for: valid.map(\.id))) { _, new in new }
                    try PronunciationHintCache.store(.init(translations: valid, pronunciations: response.pronunciations), video: videoURL)
                }
                flags.formUnion(Set(response.reviewIDs ?? []).intersection(Set(valid.map(\.id))))
            } catch { throw TranslationFailure.corruptCache }
        }
        guard !rows.isEmpty else { return nil }
        return (try replacing(document, with: rows), flags)
    }

    /// Journal a complete window assembled from validated old and new translations.
    public static func storeCompleted(source: SubtitleDocument, document: SubtitleDocument, videoURL: URL,
                                      settings: TranslationSettings, uncertainIDs: Set<Int>, glossary: [GlossaryTerm],
                                      contextDocument: SubtitleDocument) throws {
        guard source.cues.map(\.id) == document.cues.map(\.id),
              zip(source.cues, document.cues).allSatisfy({ $0.start == $1.start && $0.end == $1.end }) else {
            throw TranslationFailure.invalidResponse
        }
        let reply = TranslationResponse(translations: document.cues.map { .init(id: $0.id, text: $0.text) }, reviewIDs: uncertainIDs.sorted())
        _ = try reply.validated(for: source.cues.map(\.id))
        let (root, _) = try location(document: source, videoURL: videoURL, settings: settings,
            reviewDraft: nil, reviewIDs: nil, glossary: glossary, contextDocument: contextDocument)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(root.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw TranslationFailure.busy }
        defer { flock(descriptor, LOCK_UN) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        _ = try publishResponse(reply, to: root.appendingPathComponent("completed.json"), encoder: encoder)
    }

    /// Read completed text without starting a process or creating a cache directory.
    public static func cachedDocument(document: SubtitleDocument, videoURL: URL, settings: TranslationSettings,
                                      reviewDraft: SubtitleDocument? = nil, reviewIDs: Set<Int>? = nil,
                                      glossary: [GlossaryTerm] = [], contextDocument: SubtitleDocument? = nil) throws -> (SubtitleDocument, Set<Int>)? {
        let (root, _) = try location(document: document, videoURL: videoURL, settings: settings,
            reviewDraft: reviewDraft, reviewIDs: reviewIDs, glossary: glossary, contextDocument: contextDocument)
        let url = preferredURL(root.appendingPathComponent("completed.json"))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let response = try JSONDecoder().decode(TranslationResponse.self, from: Data(contentsOf: url))
            try response.validateIdentifiers(for: document.cues.map(\.id))
            if !invalidTextIDs(response).isEmpty { return nil }
            let rows = try response.validated(for: document.cues.map(\.id))
            try PronunciationHintCache.store(response, video: videoURL)
            return (try replacing(document, with: rows), Set(response.reviewIDs ?? []))
        } catch { throw TranslationFailure.corruptCache }
    }

    private static func invalidTextIDs(_ response: TranslationResponse) -> Set<Int> {
        Set(response.translations.filter {
            (try? TranslationResponse(translations: [$0]).validated(for: [$0.id])) == nil
        }.map(\.id))
    }

    private static func repairedURL(_ url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("repaired.json") }
    private static func preferredURL(_ url: URL) -> URL {
        let repaired = repairedURL(url)
        return FileManager.default.fileExists(atPath: repaired.path) ? repaired : url
    }

    private static func publishResponse(_ response: TranslationResponse, to url: URL, encoder: JSONEncoder) throws -> URL {
        _ = try response.validated(for: response.translations.map(\.id))
        let data = try encoder.encode(response)
        var destination = url
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try JSONDecoder().decode(TranslationResponse.self, from: Data(contentsOf: url))
            try existing.validateIdentifiers(for: response.translations.map(\.id))
            if let existingRows = try? existing.validated(for: response.translations.map(\.id)),
               existingRows == (try response.validated(for: response.translations.map(\.id))),
               Set(existing.reviewIDs ?? []) == Set(response.reviewIDs ?? []) { return url }
            guard !invalidTextIDs(existing).isEmpty else { throw TranslationFailure.corruptCache }
            destination = repairedURL(url)
        }
        try publishOrVerify(data, to: destination)
        return destination
    }

    private static func location(document: SubtitleDocument, videoURL: URL, settings: TranslationSettings,
                                 reviewDraft: SubtitleDocument?, reviewIDs: Set<Int>?, glossary: [GlossaryTerm],
                                 contextDocument: SubtitleDocument?) throws -> (URL, String) {
        let ids = document.cues.map(\.identifier)
        guard !ids.isEmpty, Set(ids).count == ids.count,
              document.cues.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end < 1_000_000_000 }) else {
            throw TranslationFailure.invalidInput
        }
        let source = srt(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var identity = Data("translation-v1\n".utf8)
        identity.append(try encoder.encode(settings))
        identity.append(Data(source.utf8))
        let matchingTerms = TranslationPreparation.matchingTerms(glossary, cues: document.cues)
        if !matchingTerms.isEmpty { identity.append(try encoder.encode(matchingTerms)) }
        if let reviewDraft {
            guard reviewDraft.cues.map(\.identifier) == ids,
                  zip(document.cues, reviewDraft.cues).allSatisfy({ $0.start == $1.start && $0.end == $1.end }) else {
                throw TranslationFailure.invalidInput
            }
            identity.append(Data("\nreview-v1\n".utf8))
            identity.append(Data(srt(reviewDraft).utf8))
            if let reviewIDs { identity.append(try encoder.encode(reviewIDs.sorted())) }
        }
        if let contextDocument {
            identity.append(Data("\nexternal-context-v1\n".utf8))
            identity.append(try encoder.encode(TranslationPreparation.context(source: contextDocument, selectedIDs: Set(ids))))
        }
        let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return (DerivedCacheLocation.directory(for: videoURL, category: "translations").appendingPathComponent(hash), hash)
    }

    private static func publishOrVerify(_ data: Data, to url: URL) throws {
        do { try publishNew(data, to: url) }
        catch let error as POSIXError where error.code == .EEXIST {
            guard try Data(contentsOf: url) == data else { throw TranslationFailure.corruptCache }
        }
    }

    private static func replacing(_ source: SubtitleDocument, with text: [Int: String]) throws -> SubtitleDocument {
        try SubtitleDocument(cues: source.cues.compactMap { cue in
            text[cue.identifier].map { SubtitleCue(identifier: cue.identifier, start: cue.start, end: cue.end, text: $0) }
        })
    }

    public static func srt(_ document: SubtitleDocument) -> String {
        document.cues.map { "\($0.identifier)\n\(timestamp($0.start)) --> \(timestamp($0.end))\n\($0.text)\n" }
            .joined(separator: "\n")
    }

    private static func timestamp(_ time: TimeInterval) -> String {
        let ms = Int64((time * 1000).rounded())
        return String(format: "%02lld:%02lld:%02lld,%03lld", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    private static func publishNew(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".pending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close() }
        try file.synchronize()
        // link is atomic and never replaces an existing destination, including a symlink.
        guard link(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
