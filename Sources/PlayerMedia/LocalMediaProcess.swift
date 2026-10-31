import Foundation
import Darwin
import PlayerCore

public enum MediaFailure: String, Error, LocalizedError {
    case unavailable, failed, stopped, invalidOutput, busy
    public var errorDescription: String? { AppLocalization.coreText("media." + rawValue) }
}

public final class MediaCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func cancel() { lock.withLock { stopped = true } }
    public func check() throws { if lock.withLock({ stopped }) { throw MediaFailure.stopped } }
}

public enum LocalMediaProcess {
    /// File-backed output avoids pipe deadlocks and never exposes private arguments in errors.
    public static func run(_ executable: URL, _ arguments: [String], directory: URL,
                           cancellation: MediaCancellation) throws -> Data {
        try cancellation.check()
        let outputURL = directory.appendingPathComponent("process-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw MediaFailure.unavailable }
        defer {
            if process.isRunning {
                process.terminate()
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
        }
        while process.isRunning {
            try cancellation.check()
            Thread.sleep(forTimeInterval: 0.025)
        }
        try cancellation.check()
        guard process.terminationStatus == 0 else { throw MediaFailure.failed }
        let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 16 * 1024 * 1024 else { throw MediaFailure.invalidOutput }
        return try Data(contentsOf: outputURL)
    }
}

public enum MediaRuntime {
    public static var directory: URL {
        if let root = ProcessInfo.processInfo.environment["LEKTIEN_RUNTIME_DIRECTORY"] {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        return Bundle.main.resourceURL!.appendingPathComponent("Runtime", isDirectory: true)
    }
    public static func executable(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent("bin/" + name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw MediaFailure.unavailable }
        return url
    }
}
