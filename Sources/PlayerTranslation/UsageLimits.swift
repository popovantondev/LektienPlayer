import Foundation
import Darwin

public struct UsageWindow: Decodable, Sendable, Equatable {
    public let usedPercent: Double?
    public let windowDurationMins: Int?
    public let resetsAt: Double?
    public var remaining: Int? { usedPercent.flatMap { $0.isFinite ? Int(max(0, min(100, 100 - $0)).rounded(.down)) : nil } }
}

public struct UsageBucket: Decodable, Sendable {
    public let limitId: String?
    public let limitName: String?
    public let planType: String?
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public var windows: [UsageWindow] { [primary, secondary].compactMap { $0 } }
    fileprivate var isSpark: Bool { [limitId, limitName].compactMap { $0 }.joined(separator: " ").lowercased().contains("spark") }
}

public struct UsageLimits: Decodable, Sendable {
    public let rateLimits: UsageBucket?
    public let rateLimitsByLimitId: [String: UsageBucket]?
    public var buckets: [UsageBucket] {
        if let map = rateLimitsByLimitId, !map.isEmpty {
            let filtered = map.filter { !$0.key.lowercased().contains("spark") && !$0.value.isSpark }
            if let main = filtered["codex"] { return [main] }
            return filtered.sorted { $0.key < $1.key }.map(\.value)
        }
        return rateLimits.flatMap { $0.isSpark ? nil : [$0] } ?? []
    }
}

/// Read-only app-server RPC. Never starts a model turn or reads credentials directly.
public enum UsageLimitsClient {
    public static func read(executable: URL, cancellation: TranslationCancellation) throws -> UsageLimits {
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let until = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < until { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close()
        }
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "lektien_player", "version": "preview"]]])
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        var bytes = [UInt8](repeating: 0, count: 16384)
        var buffer = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            try cancellation.check()
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 { buffer.append(contentsOf: bytes.prefix(count)) }
            guard buffer.count < 2_000_000 else { throw TranslationFailure.invalidResponse }
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer[..<end]
                buffer.removeSubrange(...end)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any], let id = message["id"] as? Int else { continue }
                guard message["error"] == nil else { throw TranslationFailure.service }
                if id == 1 {
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2, let result = message["result"] {
                    return try JSONDecoder().decode(UsageLimits.self, from: JSONSerialization.data(withJSONObject: result))
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw TranslationFailure.timeout
    }
}
