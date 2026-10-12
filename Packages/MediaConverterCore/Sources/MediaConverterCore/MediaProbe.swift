import Foundation

public enum ProbeError: Error, Equatable {
    case failed(Int32)
}

public struct MediaProbe {
    private let ffprobe: String
    public init(ffprobe: String) { self.ffprobe = ffprobe }

    public func probe(_ fileURL: URL) async throws -> MediaInfo {
        let streams = try run(["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", fileURL.path])
        let info = try FFprobeParser.parse(streams)
        guard info.videoCodecName != nil else { return info }

        // The transfer function of the first decoded video frame, in a read of its own. It cannot share
        // the call above: `-select_streams v:0` would hide the audio and subtitle streams from it, and
        // `-read_intervals %+#1` counts packets, so with the audio first the one packet read is audio and
        // no frame comes back. Measured (median of 9) on a 4K 10-bit HEVC clip: 25 ms for the call above,
        // 48 ms for this one (it decodes a frame). Best effort: a file whose frame cannot be read keeps
        // its stream-level value instead of becoming unreadable.
        guard let frame = try? run(["-v", "quiet", "-print_format", "json", "-select_streams", "v:0",
                                    "-show_frames", "-read_intervals", "%+#1",
                                    "-show_entries", "frame=stream_index,media_type,color_transfer",
                                    fileURL.path]) else { return info }
        return try FFprobeParser.parse(streams, firstVideoFrame: frame)
    }

    private func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProbeError.failed(process.terminationStatus)
        }
        return data
    }
}
