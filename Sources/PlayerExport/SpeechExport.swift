import AVFoundation
import Darwin
import Foundation
import PlayerCore
import PlayerMedia
import PlayerSpeech

/// Places cached clips on the video clock without changing their tempo or subtitle timing.
public enum SpeechExport {
    private static let sampleRate = 24_000.0
    private static let blockSize: AVAudioFrameCount = 16_384

    public static func save(plan: [SpeechChunk], prepared: [PreparedSpeechChunk], duration: Double,
                            german: SubtitleDocument?, destination: URL, cancellation: MediaCancellation,
                            video: VideoExportRequest? = nil,
                            progress: @Sendable (Double) -> Void = { _ in }) throws -> URL {
        try cancellation.check()
        let clips = try orderedClips(plan: plan, prepared: prepared, duration: duration)
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".lektien-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let pcm = temporary.appendingPathComponent("assembly.caf")
        try assemble(clips: clips, duration: duration, to: pcm, cancellation: cancellation, progress: progress)
        let audio = temporary.appendingPathComponent("voice.ru.m4a")
        _ = try LocalMediaProcess.run(MediaRuntime.executable("ffmpeg"),
            ["-nostdin", "-v", "error", "-n", "-i", pcm.path, "-map", "0:a:0", "-c:a", "aac",
             "-b:a", "96k", "-threads", "1", "-metadata:s:a:0", "language=rus", "-movflags", "+faststart", audio.path],
            directory: temporary, cancellation: cancellation)
        let rendered = try AVAudioFile(forReading: audio)
        guard abs(Double(rendered.length) / rendered.fileFormat.sampleRate - duration) < 0.15 else {
            throw MediaFailure.invalidOutput
        }
        let russian = try SubtitleDocument(cues: clips.flatMap { prepared in
            prepared.chunk.document.cues.map {
                SubtitleCue(identifier: $0.id, start: $0.start + prepared.chunk.start,
                            end: $0.end + prepared.chunk.start, text: $0.text)
            }
        })
        try MediaPublication.writeNew(Data(MediaPublication.srt(russian).utf8), to: temporary.appendingPathComponent("voice.ru.srt"))
        if let german {
            try MediaPublication.writeNew(Data(MediaPublication.srt(german).utf8), to: temporary.appendingPathComponent("voice.de.srt"))
        }
        try FileManager.default.removeItem(at: pcm)
        if let video {
            progress(0.9)
            try VideoExport.add(to: temporary, request: video, cancellation: cancellation)
        }
        let file = try FileHandle(forWritingTo: audio)
        try file.synchronize(); try file.close()
        try cancellation.check()
        // Publish the complete set together. RENAME_EXCL also protects against a concurrent exporter.
        var suffix = 0
        while true {
            try cancellation.check()
            let target = suffix == 0 ? destination : parent.appendingPathComponent(destination.lastPathComponent + " (\(suffix))", isDirectory: true)
            if renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 { progress(1); return target }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            suffix += 1
        }
    }

    private static func orderedClips(plan: [SpeechChunk], prepared: [PreparedSpeechChunk], duration: Double) throws -> [PreparedSpeechChunk] {
        guard duration.isFinite, duration > 0, duration < Double(Int64.max) / sampleRate,
              !plan.isEmpty, plan.count == prepared.count, Set(plan.map(\.id)).count == plan.count,
              Set(prepared.map { $0.chunk.id }).count == prepared.count else { throw MediaFailure.invalidOutput }
        let byID = Dictionary(uniqueKeysWithValues: prepared.map { ($0.chunk.id, $0) })
        var end = 0.0
        return try plan.sorted { $0.start < $1.start }.map { chunk in
            guard chunk.start.isFinite, chunk.end.isFinite, chunk.start >= end, chunk.end > chunk.start,
                  chunk.end <= duration + 0.001, let clip = byID[chunk.id],
                  clip.chunk.start == chunk.start, clip.chunk.end == chunk.end,
                  clip.chunk.document.cues.allSatisfy({ $0.start >= 0 && $0.end <= chunk.end - chunk.start + 0.001 }) else {
                throw MediaFailure.invalidOutput
            }
            end = chunk.end
            return clip
        }
    }

    private static func assemble(clips: [PreparedSpeechChunk], duration: Double, to url: URL,
                                 cancellation: MediaCancellation, progress: @Sendable (Double) -> Void) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize) else { throw MediaFailure.invalidOutput }
        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        var written: AVAudioFramePosition = 0
        func silence(until end: AVAudioFramePosition) throws {
            while written < end {
                try cancellation.check()
                buffer.frameLength = AVAudioFrameCount(min(Int64(blockSize), end - written))
                buffer.floatChannelData![0].update(repeating: 0, count: Int(buffer.frameLength))
                try output.write(from: buffer)
                written += Int64(buffer.frameLength)
            }
        }
        for (index, clip) in clips.enumerated() {
            try cancellation.check()
            let start = Int64((clip.chunk.start * sampleRate).rounded())
            let end = Int64((min(duration, clip.chunk.end) * sampleRate).rounded())
            let input = try AVAudioFile(forReading: clip.audioURL)
            guard input.processingFormat == format, input.length > 0,
                  input.length <= end - start + 1 else { throw MediaFailure.invalidOutput }
            try silence(until: start)
            while input.framePosition < input.length {
                try cancellation.check()
                // Only a one-sample rounding discrepancy may be trimmed; speech overruns are errors.
                let remaining = min(input.length - input.framePosition, end - written)
                if remaining <= 0 { break }
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(blockSize), remaining)))
                guard buffer.frameLength > 0 else { throw MediaFailure.invalidOutput }
                try output.write(from: buffer)
                written += Int64(buffer.frameLength)
            }
            progress(Double(index + 1) / Double(clips.count) * 0.8)
        }
        try silence(until: Int64((duration * sampleRate).rounded()))
    }
}
