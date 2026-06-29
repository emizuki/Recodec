import Foundation

public struct FFmpegTools: Sendable, Equatable {
    public let ffmpeg: String
    public let ffprobe: String
    public init(ffmpeg: String, ffprobe: String) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
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
