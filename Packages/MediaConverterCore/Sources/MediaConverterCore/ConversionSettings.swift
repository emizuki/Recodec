import Foundation

public enum Container: String, CaseIterable, Sendable {
    case mp4, mov, m4v, mkv, webm, m4a, mp3, gif, flac, wav

    public var fileExtension: String { rawValue }
    public var isAudioOnly: Bool {
        switch self { case .m4a, .mp3, .flac, .wav: return true; default: return false }
    }
    /// mp4/mov family supports the `+faststart` movflag.
    public var supportsFaststart: Bool {
        switch self { case .mp4, .mov, .m4v, .m4a: return true; default: return false }
    }
    /// Containers that can carry subtitle streams at all. Audio-only containers
    /// and GIF cannot, so mapping every source stream into them must drop subs.
    public var supportsSubtitles: Bool {
        switch self { case .mp4, .mov, .m4v, .mkv, .webm: return true; default: return false }
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

/// ProRes uses discrete profiles instead of a CRF/quality scale.
public enum ProResProfile: String, CaseIterable, Sendable {
    case proxy, lt, standard, hq, prores4444

    /// `-profile:v` value for prores_ks / prores_videotoolbox.
    public var ffmpegValue: Int {
        switch self {
        case .proxy:      return 0
        case .lt:         return 1
        case .standard:   return 2
        case .hq:         return 3
        case .prores4444: return 4
        }
    }
}

public enum VideoCodec: String, CaseIterable, Sendable {
    case h264, hevc, av1, vp9, prores, copy, none

    /// Re-encode software encoder (nil for copy/none).
    public var softwareEncoder: String? {
        switch self {
        case .h264:   return "libx264"
        case .hevc:   return "libx265"
        case .av1:    return "libsvtav1"
        case .vp9:    return "libvpx-vp9"
        case .prores: return "prores_ks"
        case .copy, .none: return nil
        }
    }
    /// VideoToolbox hardware encoder where available.
    public var hardwareEncoder: String? {
        switch self {
        case .h264:   return "h264_videotoolbox"
        case .hevc:   return "hevc_videotoolbox"
        case .prores: return "prores_videotoolbox"
        default:      return nil
        }
    }
    /// ffprobe-style codec name for compatibility checks (nil for copy/none).
    public var canonicalName: String? {
        switch self {
        case .h264:   return "h264"
        case .hevc:   return "hevc"
        case .av1:    return "av1"
        case .vp9:    return "vp9"
        case .prores: return "prores"
        case .copy, .none: return nil
        }
    }
    public var isIPhoneReady: Bool { self == .h264 || self == .hevc }
    /// CRF applies to the quality-controlled software encoders; ProRes uses a profile,
    /// copy/none use nothing.
    public var supportsCRF: Bool {
        switch self { case .copy, .none, .prores: return false; default: return true }
    }
    /// Whether this codec accepts an encoder preset (software x264/x265/SVT-AV1).
    public var supportsPreset: Bool {
        switch self { case .h264, .hevc, .av1: return true; default: return false }
    }
    public var defaultCRF: Int {
        switch self {
        case .h264: return 20
        case .hevc: return 25
        case .av1:  return 28
        case .vp9:  return 28
        case .prores, .copy, .none: return 20
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
    case aac, mp3, alac, opus, flac, pcm, ac3, eac3, copy, none

    public var encoder: String? {
        switch self {
        case .aac:  return "aac"
        case .mp3:  return "libmp3lame"
        case .alac: return "alac"
        case .opus: return "libopus"
        case .flac: return "flac"
        case .pcm:  return "pcm_s16le"
        case .ac3:  return "ac3"
        case .eac3: return "eac3"
        case .copy, .none: return nil
        }
    }
    public var canonicalName: String? {
        switch self {
        case .aac:  return "aac"
        case .mp3:  return "mp3"
        case .alac: return "alac"
        case .opus: return "opus"
        case .flac: return "flac"
        case .pcm:  return "pcm_s16le"
        case .ac3:  return "ac3"
        case .eac3: return "eac3"
        case .copy, .none: return nil
        }
    }
    public var isIPhoneReady: Bool { self == .aac || self == .mp3 || self == .alac }
    /// Lossy codecs take a bitrate; lossless (alac/flac), uncompressed (pcm), and copy/none do not.
    public var supportsBitrate: Bool {
        switch self { case .aac, .mp3, .opus, .ac3, .eac3: return true; default: return false }
    }
}

public enum AudioChannels: String, CaseIterable, Sendable {
    case source, mono, stereo, surround51, surround71

    /// nil = do not pass `-ac` (keep source channel count).
    public var count: Int? {
        switch self {
        case .source:     return nil
        case .mono:       return 1
        case .stereo:     return 2
        case .surround51: return 6
        case .surround71: return 8
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
    public static let presets: [AudioBitrate] = [
        .auto, .kbps(96), .kbps(128), .kbps(160), .kbps(192), .kbps(256),
        .kbps(320), .kbps(384), .kbps(448), .kbps(512), .kbps(640),
        .kbps(768), .kbps(1024), .kbps(1536),
    ]
}

public enum RateControl: String, CaseIterable, Sendable {
    case quality, bitrate
}

/// Which subtitle track, if any, is marked as the default one in the output.
/// Only consulted when `preserveAllStreams` is on, since without stream mapping
/// there is at most one subtitle track to flag.
public enum SubtitleDefault: Sendable, Equatable, Hashable {
    /// Leave every disposition exactly as ffmpeg's stream copy produced it.
    case unchanged
    /// Clear `default` on all subtitle tracks, then set it on the first track
    /// whose language tag matches (case-insensitive ISO 639-2, e.g. "eng").
    case language(String)
    /// Clear `default` on every subtitle track.
    case none

    public static let presets: [SubtitleDefault] = [
        .unchanged, .none, .language("eng"), .language("ger"),
        .language("fre"), .language("spa"), .language("ita"),
    ]
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
    public var proResProfile: ProResProfile
    public var rateControl: RateControl
    public var videoBitrateKbps: Int
    public var twoPass: Bool
    /// Map every stream from the source instead of letting ffmpeg pick one of
    /// each kind. Off by default: it changes long-standing output behaviour and
    /// can fail when the target container cannot hold every source stream
    /// (e.g. PGS subtitles in MP4).
    public var preserveAllStreams: Bool
    /// Subtitle default-flag handling. Requires `preserveAllStreams`.
    public var subtitleDefault: SubtitleDefault
    /// Tone map HDR (PQ/HLG, BT.2020) video to Rec.709 SDR via VideoToolbox's
    /// `scale_vt`. Off by default; the view model switches it on when a loaded
    /// source is HDR. Ignored for video copy/none.
    public var toneMapHDR: Bool

    public init(container: Container, videoCodec: VideoCodec, audioCodec: AudioCodec,
                crf: Int, channels: AudioChannels = .source,
                audioBitrate: AudioBitrate = .auto, useHardware: Bool = false,
                preset: EncoderPreset = .slow, proResProfile: ProResProfile = .hq,
                rateControl: RateControl = .quality, videoBitrateKbps: Int = 2000,
                twoPass: Bool = true, preserveAllStreams: Bool = false,
                subtitleDefault: SubtitleDefault = .unchanged,
                toneMapHDR: Bool = false) {
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.crf = crf
        self.channels = channels
        self.audioBitrate = audioBitrate
        self.useHardware = useHardware
        self.preset = preset
        self.proResProfile = proResProfile
        self.rateControl = rateControl
        self.videoBitrateKbps = videoBitrateKbps
        self.twoPass = twoPass
        self.preserveAllStreams = preserveAllStreams
        self.subtitleDefault = subtitleDefault
        self.toneMapHDR = toneMapHDR
    }

    public static let iPhoneDefault = ConversionSettings(
        container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 25)
}

extension ConversionSettings {
    /// Bitrate mode only applies to software-encodable video codecs; for
    /// copy/none/ProRes it is ignored and the conversion behaves as quality mode.
    public var usesBitrate: Bool { rateControl == .bitrate && videoCodec.supportsCRF }

    /// True only when ffmpeg should run two passes: bitrate mode, the toggle on,
    /// and a software encoder (VideoToolbox cannot 2-pass).
    public var effectiveTwoPass: Bool { usesBitrate && twoPass && !useHardware }

    /// Approximate audio bitrate folded into the size estimate. Lossless/PCM are
    /// variable and not modeled (treated as 0); the estimate is labeled `≈`.
    public var estimatedAudioKbps: Int {
        switch audioCodec {
        case .none: return 0
        case .copy: return 128
        default:
            guard audioCodec.supportsBitrate else { return 0 }
            if case .kbps(let k) = audioBitrate { return k }
            return 128
        }
    }

    /// Tone mapping needs the video decoded and re-encoded; copy/none/GIF have
    /// no encoder to feed.
    public var effectiveToneMapHDR: Bool {
        toneMapHDR && videoCodec != .copy && videoCodec != .none && container != .gif
    }

    /// Estimated output size in bytes for bitrate mode, from the target video
    /// bitrate, the estimated audio bitrate, and the source duration.
    public func estimatedOutputBytes(durationSeconds: Double) -> Int {
        Int(Double(videoBitrateKbps + estimatedAudioKbps) * 1000 / 8 * durationSeconds)
    }
}

extension ConversionSettings {
    /// Audio codec to default to for a freshly-loaded source: Copy when the source audio is
    /// already AAC (avoid a needless re-encode), otherwise AAC.
    public static func recommendedAudioCodec(forSource source: MediaInfo) -> AudioCodec {
        source.audioCodecName == "aac" ? .copy : .aac
    }
}
