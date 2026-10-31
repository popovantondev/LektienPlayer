import Foundation
import PlayerCore

public struct TranslationSettings: Codable, Sendable {
    public let model: String
    public let effort: String
    public init(model: String, effort: String) {
        self.model = model
        self.effort = effort
    }
}

public enum TranslationFailure: String, Error, LocalizedError {
    case stopped, timeout, service, quota, missingCLI, updateCLI, invalidInput, invalidResponse, busy, corruptCache
    public var errorDescription: String? {
        let resources = Bundle.main.url(forResource: "LektienOnlineUebersetzung_PlayerTranslation", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? .module
        return AppLocalization.text(rawValue, bundle: resources)
    }
}

public final class TranslationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public func check() throws {
        if lock.withLock({ cancelled }) { throw TranslationFailure.stopped }
    }
}
