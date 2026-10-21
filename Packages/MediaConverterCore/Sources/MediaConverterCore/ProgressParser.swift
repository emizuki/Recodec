import Foundation

public struct ProgressParser {
    public private(set) var fraction: Double = 0
    public private(set) var isFinished: Bool = false
    private let durationSeconds: Double?
    /// Trailing text from the previous chunk that has not been terminated by a newline yet.
    private var pending = ""

    public init(durationSeconds: Double?) {
        self.durationSeconds = durationSeconds
    }

    public mutating func consume(_ text: String) {
        pending += text
        // Swift treats CRLF as a single grapheme cluster, so match by newline semantics instead of
        // searching for "\n"; a chunk ending in "\r" followed by one starting with "\n" still works.
        while let newline = pending.firstIndex(where: { $0.isNewline }) {
            let rawLine = String(pending[..<newline])
            let next = pending.index(after: newline)
            pending.removeSubrange(pending.startIndex..<next)
            parse(rawLine)
        }
    }

    private mutating func parse(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        switch key {
        case "out_time_us":
            if let us = Double(value), let dur = durationSeconds, dur > 0 {
                // ffmpeg's out_time_us is not monotonic: once a stream-copied audio track ends it
                // reports the audio's end while a slow video encoder is still behind, then falls
                // back to the video. The bar only moves forward.
                fraction = max(fraction, min(1.0, (us / 1_000_000.0) / dur))
            }
        case "progress":
            if value == "end" { isFinished = true; fraction = 1.0 }
        default:
            break
        }
    }
}
