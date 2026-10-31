import AVFoundation
import Foundation
import CryptoKit
import Darwin
import PlayerCore
import PlayerMedia

public struct RecognitionSession: Sendable {
    /// A conservative decoder hint, never a post-processing replacement. The
    /// filename is used only locally to choose a subject area and is not stored
    /// in cache names or sent to a service.
    public static func initialPrompt(for video: URL) -> String {
        let name = video.deletingPathExtension().lastPathComponent.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        )
        let ITMarkers = ["umschulung", "windows", "netzwerk", "active-directory", "hyper-v", "it-"]
        if ITMarkers.contains(where: name.contains) {
            return [
                "Deutsche IT-Unterrichtsaufzeichnung.",
                "Fachbegriffe: Windows, Windows Server, Active Directory, Registry, Backup,",
                "Wiederherstellungspunkt, Partitionierung, Treiber, Netzwerk, WLAN, VPN,",
                "Hyper-V, Virtualisierung, Client, Server, ISO, LTSC, Lizenz,",
                "Service Level Agreement, SLA.",
            ].joined(separator: " ")
        }
        return [
            "Deutsche Vorlesung. Fachbegriffe und Eigennamen bitte vollständig",
            "transkribieren; keine Sätze auslassen.",
        ].joined(separator: " ")
    }

    public let video: URL
    public let streamIndex: Int
    public let duration: Double
    public let directory: URL
    private let executable: URL
    private let model: URL
    private let ffmpeg: URL
    private let inputSource: String

    private struct Stored: Codable {
        let id: Int
        let start: Double
        let end: Double
        let srt: String
        let checksum: String
    }

    public init(video: URL, streamIndex: Int, duration: Double, cancellation: MediaCancellation) throws {
        guard streamIndex >= 0 else { throw MediaFailure.invalidOutput }
        _ = try RecognitionChunk.plan(duration: duration)
        self.video = video; self.streamIndex = streamIndex; self.duration = duration
        inputSource = video.path
        executable = try MediaRuntime.executable("whisper-cli")
        ffmpeg = try MediaRuntime.executable("ffmpeg")
        model = MediaRuntime.directory.appendingPathComponent("models/ggml-large.bin")
        // Hash contents, not personal paths: moves preserve the cache and changed audio invalidates it.
        let identity = try [video, model, executable].map { try Self.hashFile($0, cancellation: cancellation) }.joined(separator: "\n")
        let key = MediaPublication.hash(Data("recognition-v4-de-original-clock-padded-30-terminology\n\(streamIndex)\n\(duration)\n\(identity)".utf8))
        directory = DerivedCacheLocation.directory(for: video, category: "recognition").appendingPathComponent(key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// A remote byte-range source uses a stable, non-secret identity for its local cache.
    /// The media URL is loopback-only and is never included in cache names or model input.
    public init(video: URL, mediaURL: URL, identity: String, streamIndex: Int, duration: Double,
                cancellation: MediaCancellation) throws {
        guard !mediaURL.isFileURL, streamIndex >= 0, !identity.isEmpty else { throw MediaFailure.invalidOutput }
        _ = try RecognitionChunk.plan(duration: duration)
        self.video = video; self.streamIndex = streamIndex; self.duration = duration
        inputSource = mediaURL.absoluteString
        executable = try MediaRuntime.executable("whisper-cli")
        ffmpeg = try MediaRuntime.executable("ffmpeg")
        model = MediaRuntime.directory.appendingPathComponent("models/ggml-large.bin")
        let runtimeIdentity = try [model, executable].map { try Self.hashFile($0, cancellation: cancellation) }.joined(separator: "\n")
        let key = MediaPublication.hash(Data("recognition-v4-de-original-clock-padded-30-terminology\n\(streamIndex)\n\(duration)\n\(identity)\n\(runtimeIdentity)".utf8))
        directory = DerivedCacheLocation.directory(for: video, category: "recognition").appendingPathComponent(key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public func cached(_ chunk: RecognitionChunk) throws -> RecognitionChunk? {
        let url = destination(chunk)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: url))
        guard stored.id == chunk.id, stored.start == chunk.start, stored.end == chunk.end,
              stored.checksum == MediaPublication.hash(Data(stored.srt.utf8)) else { throw MediaFailure.invalidOutput }
        return try chunk.withDocument(SRTParser.parse(text: stored.srt))
    }

    public func recognize(_ chunk: RecognitionChunk, cancellation: MediaCancellation) throws -> RecognitionChunk {
        try cancellation.check()
        let descriptor = open(directory.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw MediaFailure.busy }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw MediaFailure.busy }
        defer { flock(descriptor, LOCK_UN) }
        if let cached = try cached(chunk) { return cached }
        let temporary = directory.appendingPathComponent("pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = temporary.appendingPathComponent("audio.wav")
        let output = temporary.appendingPathComponent("result")
        let inputStart = max(0, chunk.start - 2)
        let inputEnd = min(duration, chunk.end + 2)
        _ = try LocalMediaProcess.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
            "-ss", String(inputStart), "-i", inputSource, "-t", String(inputEnd - inputStart),
            "-map", "0:\(streamIndex)", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", input.path],
            directory: temporary, cancellation: cancellation)
        let recognized: RecognitionChunk
        if try Self.isDigitalSilence(input, cancellation: cancellation) {
            // A decoder can hallucinate a closing phrase on zeros. Quiet speech is never thresholded away.
            recognized = try chunk.withDocument(SubtitleDocument(cues: []))
        } else {
            // whisper.cpp's VAD remaps segments but leaves tokens on compressed audio time.
            // Continuous decoding keeps word ownership on the original clock throughout.
            _ = try LocalMediaProcess.run(executable, ["-m", model.path, "-f", input.path, "-l", "de",
                "-t", "4", "-mc", "0", "-ml", "84", "-sow", "-bo", "5", "-bs", "5", "-tp", "0", "-tpi", "0", "-nf",
                "--prompt", Self.initialPrompt(for: video),
                "-ojf", "-of", output.path],
                directory: temporary, cancellation: cancellation)
            recognized = try RecognitionOutput.parse(Data(contentsOf: output.appendingPathExtension("json")), chunk: chunk, inputStart: inputStart)
        }
        let srt = MediaPublication.srt(recognized.document)
        let stored = Stored(id: chunk.id, start: chunk.start, end: chunk.end, srt: srt, checksum: MediaPublication.hash(Data(srt.utf8)))
        try MediaPublication.writeNew(JSONEncoder().encode(stored), to: destination(chunk))
        return recognized
    }

    private func destination(_ chunk: RecognitionChunk) -> URL { directory.appendingPathComponent("\(chunk.id).json") }

    static func isDigitalSilence(_ url: URL, cancellation: MediaCancellation) throws -> Bool {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else { throw MediaFailure.invalidOutput }
        while file.framePosition < file.length {
            try cancellation.check()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { throw MediaFailure.invalidOutput }
            if (0..<Int(buffer.frameLength)).contains(where: { samples[$0] != 0 }) { return false }
        }
        return true
    }

    private static func hashFile(_ url: URL, cancellation: MediaCancellation) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw MediaFailure.unavailable }
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try cancellation.check()
            let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
