import Foundation

public enum ProbeError: Error, Equatable {
    case failed(Int32)
}

public struct MediaProbe {
    private let ffprobe: String
    public init(ffprobe: String) { self.ffprobe = ffprobe }

    public func probe(_ fileURL: URL) async throws -> MediaInfo {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        // One decoded frame (`%+#1`) is enough to read the transfer function it carries. Measured
        // (median of 7): 25 ms -> 50 ms on a 4K 10-bit HEVC clip, no difference on a small one.
        process.arguments = ["-v", "quiet", "-print_format", "json",
                             "-show_format", "-show_streams",
                             "-show_frames", "-read_intervals", "%+#1", fileURL.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProbeError.failed(process.terminationStatus)
        }
        return try FFprobeParser.parse(data)
    }
}
