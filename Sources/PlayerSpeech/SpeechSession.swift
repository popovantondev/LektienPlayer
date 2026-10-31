import Foundation
import CryptoKit
import Darwin
import PlayerCore

public struct SpeechResult: Sendable {
    public let audioURL: URL
    public let voice: String
}

public final class SpeechCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func cancel() { lock.withLock { stopped = true } }
    func check() throws { if lock.withLock({ stopped }) { throw SpeechFailure.stopped } }
}

public enum SpeechFailure: String, Error, LocalizedError {
    case stopped, missingRuntime, missingFFmpeg, failed, invalidAudio, busy, unsupportedVoice
    public var errorDescription: String? { AppLocalization.text(rawValue, bundle: SpeechSession.resources) }
}

public enum SpeechSession {
    static var resources: Bundle {
        Bundle.main.url(forResource: "LektienOnlineUebersetzung_PlayerSpeech", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? .module
    }

    public static func installedRuntime() -> URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("speech-runtime")
        let existing = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SRTVoiceover/.venv-silero")
        return [bundled, existing].compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("bin/python").path)
        }
    }

    public static func installedFFmpeg() -> URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/ffmpeg").path
        let runtime = Bundle.main.resourceURL?.appendingPathComponent("Runtime/bin/ffmpeg").path
        return [runtime, bundled, "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg",
                "/Applications/Subtitle Edit.app/Contents/MacOS/ffmpeg",
                "/Applications/Wondershare UniConverter 15.app/Contents/MacOS/ffmpeg"]
            .compactMap { $0 }.first(where: FileManager.default.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }

    public static func run(srt: String, videoURL: URL, voice: String, cancellation: SpeechCancellation,
                           pronunciation: SpeechPronunciation? = nil,
                           progress: @Sendable (Int, Int) -> Void) throws -> SpeechResult {
        guard voice == "kseniya" else { throw SpeechFailure.unsupportedVoice }
        try cancellation.check()
        let srt = try (pronunciation ?? SpeechPronunciation.load(video: videoURL)).prepare(srt: srt)
        let source = try SRTParser.parse(text: srt)
        guard !source.cues.isEmpty else { throw SpeechFailure.failed }
        let root = DerivedCacheLocation.directory(for: videoURL, category: "speech")
        let job = cacheURL(srt: srt, videoURL: videoURL, voice: voice).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(job.appendingPathComponent("session.lock").path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw SpeechFailure.busy }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SpeechFailure.busy }
        defer { flock(descriptor, LOCK_UN) }
        let final = job.appendingPathComponent("audio.wav")
        if FileManager.default.fileExists(atPath: final.path) {
            try validateWAV(final)
            return .init(audioURL: final, voice: voice)
        }
        guard let runtime = installedRuntime() else { throw SpeechFailure.missingRuntime }
        guard let ffmpeg = installedFFmpeg() else { throw SpeechFailure.missingFFmpeg }
        let temporary = job.appendingPathComponent("pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let inputURL = temporary.appendingPathComponent("input.srt")
        try Data(srt.utf8).write(to: inputURL)
        let outputURL = temporary.appendingPathComponent("audio.wav")
        let events = temporary.appendingPathComponent("progress.txt")
        FileManager.default.createFile(atPath: events.path, contents: nil)
        let output = try FileHandle(forWritingTo: events)
        let reader = try FileHandle(forReadingFrom: events)
        defer { try? output.close(); try? reader.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.currentDirectoryURL = temporary
        guard let engine = resources.url(forResource: "player_speech", withExtension: "rb", subdirectory: "Engine") else {
            throw SpeechFailure.missingRuntime
        }
        process.arguments = ["-EUTF-8:UTF-8", engine.path,
                             "--voice", "silero", "--silero-speaker", voice, "--rhythm", "smooth",
                             "--output", outputURL.path, inputURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["SRT_VOICEOVER_SILERO_DIR"] = runtime.path
        environment["SRT_VOICEOVER_DATA_DIR"] = temporary.path
        environment["LEKTIEN_PHRASE_CACHE"] = root.appendingPathComponent("phrases").path
        environment["LEKTIEN_FFMPEG"] = ffmpeg.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        // Finder launches without the UTF-8 shell locale. Ruby otherwise mixes
        // US-ASCII paths with Russian text before synthesis even starts.
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["PYTHONUTF8"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer {
            if process.isRunning {
                if kill(-process.processIdentifier, SIGTERM) != 0 { process.terminate() }
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
                // Workers remain in the process group even if their parent exits first.
                kill(-process.processIdentifier, SIGKILL)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        let pattern = try NSRegularExpression(pattern: "подготовлено ([0-9]+)/([0-9]+) фраз")
        var buffer = ""
        while process.isRunning {
            try cancellation.check()
            let bytes = try reader.read(upToCount: 65_536) ?? Data()
            buffer += String(decoding: bytes, as: UTF8.self)
            if let match = pattern.matches(in: buffer, range: NSRange(buffer.startIndex..., in: buffer)).last,
               let a = Range(match.range(at: 1), in: buffer), let b = Range(match.range(at: 2), in: buffer),
               let completed = Int(buffer[a]), let total = Int(buffer[b]) { progress(completed, total) }
            buffer = String(buffer.suffix(1000))
            Thread.sleep(forTimeInterval: 0.1)
        }
        // A finished clip remains reusable even if stop arrived at the completion boundary.
        if process.terminationStatus != 0 { try cancellation.check() }
        guard process.terminationStatus == 0 else {
            let length = try reader.seekToEnd()
            try reader.seek(toOffset: length > 4000 ? length - 4000 : 0)
            let tail = String(decoding: try reader.read(upToCount: 4000) ?? Data(), as: UTF8.self)
            if let reason = tail.components(separatedBy: .newlines).last(where: { $0.contains("Ошибка:") }) {
                throw NSError(domain: "PlayerSpeech", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: String(reason.prefix(500))])
            }
            throw SpeechFailure.failed
        }
        try validateWAV(outputURL)
        let audioFile = try FileHandle(forWritingTo: outputURL)
        try audioFile.synchronize()
        try audioFile.close()
        guard link(outputURL.path, final.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return .init(audioURL: final, voice: voice)
    }

    /// Inspect only the header of completed audio; never start a worker or create files.
    public static func silentAudio(duration: Double, videoURL: URL) throws -> URL {
        guard duration.isFinite, duration > 0, duration <= 600 else { throw SpeechFailure.invalidAudio }
        let count = Int((duration * 24_000).rounded())
        let destination = cacheURL(srt: "silence-pcm24-v1-\(count)", videoURL: videoURL, voice: "kseniya")
        if FileManager.default.fileExists(atPath: destination.path) { try validateWAV(destination); return destination }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data("RIFF".utf8)
        func append32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        append32(UInt32(36 + count * 2)); data.append(Data("WAVEfmt ".utf8)); append32(16)
        append16(1); append16(1); append32(24_000); append32(48_000); append16(2); append16(16)
        data.append(Data("data".utf8)); append32(UInt32(count * 2)); data.append(Data(count: count * 2))
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("silence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
        if link(temporary.path, destination.path) != 0 && errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try validateWAV(destination)
        return destination
    }

    /// Inspect only the header of completed audio; never start a worker or create files.
    public static func cachedAudio(srt: String, videoURL: URL, voice: String) throws -> URL? {
        guard voice == "kseniya" else { throw SpeechFailure.unsupportedVoice }
        let srt = try SpeechPronunciation.load(video: videoURL).prepare(srt: srt)
        let url = cacheURL(srt: srt, videoURL: videoURL, voice: voice)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try validateWAV(url)
        return url
    }

    private static func cacheURL(srt: String, videoURL: URL, voice: String) -> URL {
        let key = SHA256.hash(data: Data("speech-v2-natural-v5_5_ru\n\(voice)\n\(srt)".utf8)).map { String(format: "%02x", $0) }.joined()
        return DerivedCacheLocation.directory(for: videoURL, category: "speech").appendingPathComponent("\(key)/audio.wav")
    }

    private static func validateWAV(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 44) ?? Data()
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard header.count == 44, size > 44,
              String(decoding: header.prefix(4), as: UTF8.self) == "RIFF",
              String(decoding: header[8..<12], as: UTF8.self) == "WAVE" else { throw SpeechFailure.invalidAudio }
        let length = header[40..<44].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard length > 0, length + 44 == size else { throw SpeechFailure.invalidAudio }
    }
}
