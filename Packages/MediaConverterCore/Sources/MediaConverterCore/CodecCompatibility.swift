import Foundation

/// Maps each Container to the VideoCodec and AudioCodec values that are valid for it,
/// and provides a pre-flight combo check used before invoking ffmpeg.
public enum CodecCompatibility {
    public static func videoCodecs(for container: Container) -> [VideoCodec] {
        switch container {
        case .mp4:  return [.h264, .hevc, .av1, .copy, .none]
        case .mov:  return [.h264, .hevc, .copy, .none]
        case .m4v:  return [.h264, .hevc, .copy, .none]
        case .mkv:  return [.h264, .hevc, .av1, .vp9, .copy, .none]
        case .webm: return [.vp9, .av1, .copy, .none]
        case .m4a:  return [.none]
        case .mp3:  return [.none]
        case .gif:  return [.none]
        }
    }

    public static func audioCodecs(for container: Container) -> [AudioCodec] {
        switch container {
        case .mp4:  return [.aac, .mp3, .alac, .copy, .none]
        case .mov:  return [.aac, .mp3, .alac, .copy, .none]
        case .m4v:  return [.aac, .mp3, .alac, .copy, .none]
        case .mkv:  return [.aac, .mp3, .alac, .opus, .copy, .none]
        case .webm: return [.opus, .copy, .none]
        case .m4a:  return [.aac, .alac, .copy, .none]
        case .mp3:  return [.mp3, .copy, .none]
        case .gif:  return [.none]
        }
    }

    /// Returns true when ffmpeg can mux the chosen codecs into the container.
    /// GIF is always valid — codec selection is ignored for gif conversions.
    public static func isValidCombo(_ settings: ConversionSettings) -> Bool {
        if settings.container == .gif { return true }
        return videoCodecs(for: settings.container).contains(settings.videoCodec)
            && audioCodecs(for: settings.container).contains(settings.audioCodec)
    }
}
