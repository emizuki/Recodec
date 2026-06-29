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
        process.arguments = ["-v", "quiet", "-print_format", "json",
                             "-show_format", "-show_streams", fileURL.path]
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
