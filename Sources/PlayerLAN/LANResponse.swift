import Foundation

/// Application-owned preparation. The HTTP layer never accepts filesystem paths.
public struct LANResponse: Sendable {
    public let status: Int
    public let data: Data
    public let file: URL?
    public let fileRoot: URL?
    public let media: LANStreamedMedia?
    public let contentType: String?
    public init(status: Int = 200, data: Data = Data(), file: URL? = nil,
                fileRoot: URL? = nil, media: LANStreamedMedia? = nil, contentType: String? = nil) {
        self.status = status; self.data = data; self.file = file
        self.fileRoot = fileRoot; self.media = media; self.contentType = contentType
    }
    public static func json<T: Encodable>(_ value: T) -> Self {
        guard let data = try? JSONEncoder().encode(value) else { return .init(status: 500) }
        return .init(data: data)
    }
}

/// A selected remote video. The HTTP server requests bounded ranges and never
/// receives its source URL, Telegram identifiers, or credentials.
public struct LANStreamedMedia: Sendable {
    public let size: UInt64
    public let contentType: String
    public let read: @Sendable (UInt64, Int) async throws -> Data
    public init(size: UInt64, contentType: String,
                read: @escaping @Sendable (UInt64, Int) async throws -> Data) {
        self.size = size; self.contentType = contentType; self.read = read
    }
}

public typealias LANRequestHandler = @Sendable (String, Data?) async -> LANResponse

public struct LANPreparationCommand: Codable, Sendable {
    public let id: String
    public let position: Double
    public let playing: Bool
    public let source: Int?
    public var isValid: Bool { id.count == 64 && id.allSatisfy(\.isHexDigit) && position.isFinite && position >= 0 }
}
