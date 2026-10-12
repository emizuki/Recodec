import Foundation

public struct FFmpegTools: Sendable, Equatable {
    public let ffmpeg: String
    public let ffprobe: String
    public init(ffmpeg: String, ffprobe: String) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }
}

extension FFmpegTools {
    /// Whether this ffmpeg build has the filter (`ffmpeg -filters`, about 20 ms). The VideoToolbox
    /// filters exist only in builds made with VideoToolbox support.
    public func hasFilter(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-hide_banner", "-filters"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let listing = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Self.filterListing(listing, contains: name)
    }

    /// `-filters` prints one filter per line: flags, name, pins, description. Match the name column
    /// only, so `scale_v` does not find `scale_vt` and a word in a description finds nothing.
    static func filterListing(_ listing: String, contains name: String) -> Bool {
        listing.split(whereSeparator: \.isNewline).contains { line in
            let columns = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            return columns.count > 1 && columns[1] == name
        }
    }
}

public enum FFmpegLocator {
    public static let defaultSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    public static let overrideDefaultsKey = "ffmpegDirectory"

    /// Pure selection logic: first directory containing BOTH ffmpeg and ffprobe.
    public static func locate(searchPaths: [String], fileExists: (String) -> Bool) -> FFmpegTools? {
        for dir in searchPaths {
            let ffmpeg = dir + "/ffmpeg"
            let ffprobe = dir + "/ffprobe"
            if fileExists(ffmpeg) && fileExists(ffprobe) {
                return FFmpegTools(ffmpeg: ffmpeg, ffprobe: ffprobe)
            }
        }
        return nil
    }

    /// Real lookup: honours a user-set directory override, then the default search paths.
    public static func locate() -> FFmpegTools? {
        let fm = FileManager.default
        let exists: (String) -> Bool = { fm.isExecutableFile(atPath: $0) }
        if let override = UserDefaults.standard.string(forKey: overrideDefaultsKey), !override.isEmpty,
           let tools = locate(searchPaths: [override], fileExists: exists) {
            return tools
        }
        return locate(searchPaths: defaultSearchPaths, fileExists: exists)
    }
}
