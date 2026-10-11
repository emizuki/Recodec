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
            && isAudioBitrateValid(settings.audioBitrate, for: settings.audioCodec, channels: settings.channels)
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

    /// Highest audio bitrate (kbps) each lossy encoder accepts or honours for `channels` output
    /// channels, measured against ffmpeg 9.0.2. A preset above it is rejected or silently
    /// clamped, so it must not be offered:
    ///   - opus: libopus allows 256 kbps per channel, so mono fails above 256, stereo above
    ///     512; 5.1 and 7.1 take the whole list.
    ///   - mp3: capped at 320 kbps whatever the layout; anything higher is clamped.
    ///   - ac3: capped at 640 kbps whatever the layout; anything higher is clamped.
    ///   - aac: never fails, but the encoder takes more per extra channel (about 220 kbps for
    ///     mono, 420 stereo, 1100 for 5.1, 1500+ for 7.1). Up to stereo it keeps the old 640
    ///     (ffmpeg clamps lower, silently); the 768+ presets are for surround.
    ///   - eac3: honours up to 1536 kbps for every layout it accepts.
    /// nil for codecs that take no bitrate.
    public static func maxAudioKbps(for codec: AudioCodec, channels: Int) -> Int? {
        switch codec {
        case .mp3:  return 320
        case .ac3:  return 640
        case .eac3: return 1536
        case .opus: return min(1536, 256 * max(channels, 1))
        case .aac:  return channels > 2 ? 1536 : 640
        default:    return nil
        }
    }

    /// Channel count the bitrate rules assume for a layout. "Same as source" is not known
    /// until a file is probed, so settings and the picker assume stereo; `ArgumentBuilder`
    /// applies the real count per file.
    static func assumedChannelCount(_ channels: AudioChannels) -> Int {
        channels.count ?? 2
    }

    public static func audioBitrateOptions(for codec: AudioCodec, channels: AudioChannels) -> [AudioBitrate] {
        guard let max = maxAudioKbps(for: codec, channels: assumedChannelCount(channels)) else {
            return AudioBitrate.presets
        }
        return AudioBitrate.presets.filter { if case .kbps(let k) = $0 { return k <= max }; return true }
    }

    public static func isAudioBitrateValid(_ bitrate: AudioBitrate, for codec: AudioCodec,
                                           channels: AudioChannels) -> Bool {
        guard let max = maxAudioKbps(for: codec, channels: assumedChannelCount(channels)),
              case .kbps(let k) = bitrate else { return true }
        return k <= max
    }
}
