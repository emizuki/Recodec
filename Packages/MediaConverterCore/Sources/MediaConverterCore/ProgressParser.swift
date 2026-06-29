import Foundation

public struct ProgressParser {
    public private(set) var fraction: Double = 0
    public private(set) var isFinished: Bool = false
    private let durationSeconds: Double?

    public init(durationSeconds: Double?) {
        self.durationSeconds = durationSeconds
    }

    public mutating func consume(_ text: String) {
        for rawLine in text.split(separator: "\n") {
            let parts = rawLine.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "out_time_us":
                if let us = Double(value), let dur = durationSeconds, dur > 0 {
                    fraction = min(1.0, (us / 1_000_000.0) / dur)
                }
            case "progress":
                if value == "end" { isFinished = true; fraction = 1.0 }
            default:
                break
            }
        }
    }
}
