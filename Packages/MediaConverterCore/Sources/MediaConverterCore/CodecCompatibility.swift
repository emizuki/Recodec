import Foundation

/// Maps each Container to the VideoCodec and AudioCodec values that are valid for it,
/// and provides a pre-flight combo check used before invoking ffmpeg.
public enum CodecCompatibility {
    public static func videoCodecs(for container: Container) -> [VideoCodec] {
        switch container {
        case .mp4:  return [.h264, .hevc, .av1, .vp9, .copy, .none]
        case .mov:  return [.h264, .hevc, .prores, .copy, .none]
        // .m4v uses ffmpeg's restrictive `ipod` muxer: H.264 only (HEVC is rejected even with hvc1).
        case .m4v:  return [.h264, .copy, .none]
        case .mkv:  return [.h264, .hevc, .av1, .vp9, .prores, .copy, .none]
        case .webm: return [.vp9, .av1, .copy, .none]
        case .m4a:  return [.none]
        case .mp3:  return [.none]
        case .gif:  return [.none]
        case .flac: return [.none]
        case .wav:  return [.none]
        }
    }

    public static func audioCodecs(for container: Container) -> [AudioCodec] {
        switch container {
        case .mp4:  return [.aac, .mp3, .alac, .opus, .flac, .pcm, .ac3, .eac3, .copy, .none]
        case .mov:  return [.aac, .mp3, .alac, .ac3, .eac3, .pcm, .copy, .none]
        // .m4v (ipod muxer): AAC/ALAC/AC-3 only — MP3 is rejected by the container.
        case .m4v:  return [.aac, .alac, .ac3, .copy, .none]
        case .mkv:  return [.aac, .mp3, .alac, .opus, .flac, .ac3, .eac3, .pcm, .copy, .none]
        case .webm: return [.opus, .copy, .none]
        case .m4a:  return [.aac, .alac, .ac3, .copy, .none]
        case .mp3:  return [.mp3, .copy, .none]
        case .gif:  return [.none]
        case .flac: return [.flac, .copy, .none]
        case .wav:  return [.pcm, .aac, .mp3, .flac, .ac3, .eac3, .copy, .none]
        }
    }

    /// Returns true when ffmpeg can mux the chosen codecs into the container.
    /// GIF is always valid — codec selection is ignored for gif conversions.
    public static func isValidCombo(_ settings: ConversionSettings) -> Bool {
        if settings.container == .gif { return true }
        return videoCodecs(for: settings.container).contains(settings.videoCodec)
            && audioCodecs(for: settings.container).contains(settings.audioCodec)
            && channelOptions(for: settings.audioCodec).contains(settings.channels)
    }

    /// Channel layouts each audio encoder actually accepts. ffmpeg aborts the run
    /// with "Specified channel layout is not supported by the <x> encoder" rather
    /// than down-mixing, so unsupported combinations must not be offered.
    ///
    /// Measured against ffmpeg 9.0.1 (`ffmpeg -h encoder=<name>`):
    ///   - mp3: mono/stereo only.
    ///   - ac3 / eac3: up to 5.1. 7.1 E-AC-3 (Dolby Digital Plus) requires
    ///     Dolby's own encoder, which ffmpeg does not ship.
    ///   - alac: has no standard 7.1; its 8-channel layout is 7.1(wide), which
    ///     places the side channels as front-wide. Offering it as "7.1" would
    ///     mislabel the output, so ALAC is capped at 5.1 here.
    ///   - aac / opus / flac / pcm: accept 8 channels.
    public static func channelOptions(for codec: AudioCodec) -> [AudioChannels] {
        switch codec {
        case .mp3:
            return [.source, .mono, .stereo]
        case .ac3, .eac3, .alac:
            return [.source, .mono, .stereo, .surround51]
        case .aac, .opus, .flac, .pcm:
            return AudioChannels.allCases
        case .copy, .none:
            // No encoder runs, so `-ac` is never emitted; keep the picker inert.
            return [.source]
        }
    }
}
