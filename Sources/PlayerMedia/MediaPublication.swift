import Foundation
import CryptoKit
import Darwin
import PlayerCore

public enum MediaPublication {
    public static func writeNew(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".pending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        let file = try FileHandle(forWritingTo: temporary)
        try file.synchronize(); try file.close()
        guard link(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    public static func srt(_ document: SubtitleDocument) -> String {
        document.cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    public static func subtitles(_ document: SubtitleDocument, video: URL, language: String) throws -> URL {
        guard ["de", "ru", "en"].contains(language) else { throw MediaFailure.invalidOutput }
        let data = Data(srt(document).utf8)
        var base = video.deletingPathExtension()
        if ["de", "ru", "en"].contains(base.pathExtension.lowercased()) { base.deletePathExtension() }
        var suffix = 0
        while true {
            let extra = suffix == 0 ? "" : ".\(suffix)"
            let target = base.appendingPathExtension("\(language)\(extra).srt")
            do { try writeNew(data, to: target); return target }
            catch let error as POSIXError where error.code == .EEXIST {
                if (try? Data(contentsOf: target)) == data { return target }
                suffix += 1
            }
        }
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func timestamp(_ seconds: Double) -> String {
        let ms = Int64((seconds * 1000).rounded())
        return String(format: "%02lld:%02lld:%02lld,%03lld", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
