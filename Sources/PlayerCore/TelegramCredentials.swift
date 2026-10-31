import Foundation
import Security

/// Credentials issued for the owner's own Telegram client application.
/// They are deliberately separate from an installed Telegram application's session.
public struct TelegramCredentials: Equatable, Sendable {
    public let apiID: Int32
    public let apiHash: String

    public init(apiID: Int32, apiHash: String) {
        self.apiID = apiID
        self.apiHash = apiHash
    }

    public static func validated(apiID: String, apiHash: String) throws -> TelegramCredentials {
        guard let identifier = Int32(apiID.trimmingCharacters(in: .whitespacesAndNewlines)), identifier > 0 else {
            throw TelegramCredentialsError.invalidAPIID
        }
        let hash = apiHash.trimmingCharacters(in: .whitespacesAndNewlines)
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard hash.count == 32, hash.unicodeScalars.allSatisfy(hexadecimal.contains) else {
            throw TelegramCredentialsError.invalidAPIHash
        }
        return TelegramCredentials(apiID: identifier, apiHash: hash.lowercased())
    }
}

public enum TelegramCredentialsError: LocalizedError, Equatable, Sendable {
    case invalidAPIID
    case invalidAPIHash
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidAPIID: return AppLocalization.coreText("telegram.error.apiID")
        case .invalidAPIHash: return AppLocalization.coreText("telegram.error.apiHash")
        case .keychain: return AppLocalization.coreText("telegram.error.keychain")
        }
    }
}

public struct TelegramCredentialsStore: Sendable {
    private static let service = "com.lektien.player.telegram"
    private static let apiIDAccount = "api-id"
    private static let apiHashAccount = "api-hash"

    public init() {}

    public func load() throws -> TelegramCredentials? {
        guard let id = try value(for: Self.apiIDAccount), let hash = try value(for: Self.apiHashAccount) else { return nil }
        return try TelegramCredentials.validated(apiID: id, apiHash: hash)
    }

    public func save(_ credentials: TelegramCredentials) throws {
        try replace(String(credentials.apiID), account: Self.apiIDAccount)
        do {
            try replace(credentials.apiHash, account: Self.apiHashAccount)
        } catch {
            try? remove(account: Self.apiIDAccount)
            throw error
        }
    }

    public func removeAll() throws {
        try remove(account: Self.apiIDAccount)
        try remove(account: Self.apiHashAccount)
    }

    private func value(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw TelegramCredentialsError.keychain(status)
        }
        return value
    }

    private func replace(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw TelegramCredentialsError.keychain(update) }
        var addition = query
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let creation = SecItemAdd(addition as CFDictionary, nil)
        guard creation == errSecSuccess else { throw TelegramCredentialsError.keychain(creation) }
    }

    private func remove(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TelegramCredentialsError.keychain(status) }
    }
}
