import Foundation

public enum Container: String, CaseIterable, Sendable {
    case mp4, mov, m4v, mkv, webm, m4a, mp3, gif

    public var fileExtension: String { rawValue }
    public var isAudioOnly: Bool { self == .m4a || self == .mp3 }
    /// mp4/mov family supports the `+faststart` movflag.
    public var supportsFaststart: Bool {
        switch self { case .mp4, .mov, .m4v, .m4a: return true; default: return false }
    }
}

public enum EncoderPreset: String, CaseIterable, Sendable {
    case ultrafast, superfast, veryfast, faster, fast, medium, slow, slower, veryslow

    /// x264/x265 use the case name directly.
    public var x264Name: String { rawValue }

    /// SVT-AV1 uses a numeric preset (0 = slowest/best … 13 = fastest).
    public var svtAV1Value: Int {
        switch self {
        case .ultrafast: return 13
        case .superfast: return 12
        case .veryfast:  return 10
        case .faster:    return 9
        case .fast:      return 8
        case .medium:    return 6
        case .slow:      return 4
        case .slower:    return 3
        case .veryslow:  return 2
        }
    }
}

public enum VideoCodec: String, CaseIterable, Sendable {
    case h264, hevc, av1, vp9, copy, none

    /// Re-encode software encoder (nil for copy/none).
    public var softwareEncoder: String? {
        switch self {
        case .h264: return "libx264"
        case .hevc: return "libx265"
        case .av1:  return "libsvtav1"
        case .vp9:  return "libvpx-vp9"
        case .copy, .none: return nil
        }
    }
    /// VideoToolbox hardware encoder where available.
    public var hardwareEncoder: String? {
        switch self {
        case .h264: return "h264_videotoolbox"
        case .hevc: return "hevc_videotoolbox"
        default:    return nil
        }
    }
    /// ffprobe-style codec name for compatibility checks (nil for copy/none).
    public var canonicalName: String? {
        switch self {
        case .h264: return "h264"
        case .hevc: return "hevc"
        case .av1:  return "av1"
        case .vp9:  return "vp9"
        case .copy, .none: return nil
        }
    }
    public var isIPhoneReady: Bool { self == .h264 || self == .hevc }
    public var supportsCRF: Bool { self != .copy && self != .none }
    /// Whether this codec accepts an encoder preset (software x264/x265/SVT-AV1).
    public var supportsPreset: Bool {
        switch self { case .h264, .hevc, .av1: return true; default: return false }
    }
    public var defaultCRF: Int {
        switch self {
        case .h264: return 23
        case .hevc: return 28
        case .av1:  return 30
        case .vp9:  return 31
        case .copy, .none: return 23
        }
    }
    public var crfRange: ClosedRange<Int> {
        switch self {
        case .av1, .vp9: return 0...63
        default:         return 0...51
        }
    }
}

public enum AudioCodec: String, CaseIterable, Sendable {
    case aac, mp3, alac, opus, copy, none

    public var encoder: String? {
        switch self {
        case .aac:  return "aac"
        case .mp3:  return "libmp3lame"
        case .alac: return "alac"
        case .opus: return "libopus"
        case .copy, .none: return nil
        }
    }
    public var canonicalName: String? {
        switch self {
        case .aac:  return "aac"
        case .mp3:  return "mp3"
        case .alac: return "alac"
        case .opus: return "opus"
        case .copy, .none: return nil
        }
    }
    public var isIPhoneReady: Bool { self == .aac || self == .mp3 || self == .alac }
    /// ALAC is lossless (bitrate ignored); copy/none have no bitrate.
    public var supportsBitrate: Bool { self == .aac || self == .mp3 || self == .opus }
}

public enum AudioChannels: String, CaseIterable, Sendable {
    case source, mono, stereo, surround51

    /// nil = do not pass `-ac` (keep source channel count).
    public var count: Int? {
        switch self {
        case .source:     return nil
        case .mono:       return 1
        case .stereo:     return 2
        case .surround51: return 6
        }
    }
}

public enum AudioBitrate: Sendable, Equatable, Hashable {
    case auto
    case kbps(Int)

    /// nil = omit `-b:a` (use encoder default).
    public var ffmpegArgument: String? {
        switch self {
        case .auto:          return nil
        case .kbps(let k):   return "\(k)k"
        }
    }
    public static let presets: [AudioBitrate] = [.auto, .kbps(96), .kbps(128), .kbps(160), .kbps(192), .kbps(256), .kbps(320)]
}

public struct ConversionSettings: Sendable, Equatable {
    public var container: Container
    public var videoCodec: VideoCodec
    public var audioCodec: AudioCodec
    public var crf: Int
    public var channels: AudioChannels
    public var audioBitrate: AudioBitrate
    public var useHardware: Bool
    public var preset: EncoderPreset

    public init(container: Container, videoCodec: VideoCodec, audioCodec: AudioCodec,
                crf: Int, channels: AudioChannels = .source,
                audioBitrate: AudioBitrate = .auto, useHardware: Bool = false,
                preset: EncoderPreset = .medium) {
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.crf = crf
        self.channels = channels
        self.audioBitrate = audioBitrate
        self.useHardware = useHardware
        self.preset = preset
    }

    public static let iPhoneDefault = ConversionSettings(
        container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 28)
}
