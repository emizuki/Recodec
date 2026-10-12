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

    /// What happens to one subtitle track when every stream is kept and mapped into a container.
    public enum SubtitleHandling: Equatable {
        /// Passed through untouched.
        case copy
        /// Re-encoded with this ffmpeg subtitle encoder: text stays text, only the format changes.
        case convert(to: String)
        /// No way into this container: bitmap subtitles cannot become text.
        case unsupported
    }

    /// Measured against ffmpeg 9.0.2 (stream copy, then `-c:s <encoder>`): MP4, MOV and M4V hold only
    /// mov_text, WebM only WebVTT, Matroska every text format but mov_text; PGS is kept by Matroska
    /// and rejected by the rest. Codecs outside these two sets (VobSub, DVB, ...) were not measured and
    /// are left to ffmpeg, which reports its own reason if the container refuses them.
    private static let textSubtitleCodecs: Set<String> = ["subrip", "ass", "webvtt", "mov_text"]
    private static let bitmapSubtitleCodecs: Set<String> = ["hdmv_pgs_subtitle"]

    public static func subtitleHandling(for codec: String, in container: Container) -> SubtitleHandling {
        if bitmapSubtitleCodecs.contains(codec) { return container == .mkv ? .copy : .unsupported }
        guard textSubtitleCodecs.contains(codec) else { return .copy }
        switch container {
        case .mp4, .mov, .m4v: return codec == "mov_text" ? .copy : .convert(to: "mov_text")
        // Styled ASS stays ASS in Matroska; only mov_text has to change.
        case .mkv:             return codec == "mov_text" ? .convert(to: "srt") : .copy
        case .webm:            return codec == "webvtt" ? .copy : .convert(to: "webvtt")
        default:               return .copy
        }
    }

    /// Whether stream copy of an audio track of `codec` (ffprobe's name) into `container` works.
    /// Measured against ffmpeg 9.0.2, one codec at a time (`testAudioCopyTableMatchesFfmpeg` repeats
    /// the measurement): MKV takes everything; MP4 everything but TrueHD (experimental); MOV
    /// additionally refuses FLAC and Opus; M4V and M4A (the `ipod` muxer) hold only AAC, AC-3 and
    /// ALAC; WebM only Opus and Vorbis; MP3 and FLAC only their own codec; WAV takes everything but
    /// ALAC, Opus and TrueHD. Codecs outside the measured set are assumed to work.
    public static func canCopyAudio(_ codec: String, into container: Container) -> Bool {
        switch container {
        case .mkv:        return true
        case .mp4:        return codec != "truehd"
        case .mov:        return !["flac", "opus", "truehd"].contains(codec)
        case .m4v, .m4a:  return ["aac", "ac3", "alac"].contains(codec)
        case .webm:       return ["opus", "vorbis"].contains(codec)
        case .mp3:        return codec == "mp3"
        case .flac:       return codec == "flac"
        case .wav:        return !["alac", "opus", "truehd"].contains(codec)
        case .gif:        return false
        }
    }

    private static func displayName(ofCodec codec: String) -> String {
        let names = ["hdmv_pgs_subtitle": "PGS", "dvd_subtitle": "VobSub", "ac3": "AC-3", "eac3": "E-AC-3",
                     "truehd": "TrueHD", "dts": "DTS", "alac": "ALAC", "opus": "Opus"]
        if codec.hasPrefix("pcm_") { return "PCM" }
        return names[codec] ?? codec.uppercased()
    }

    /// Why this file cannot be converted with these settings although the codec lists accept them:
    /// a track of its own that the target container cannot hold. nil when nothing stands in the way.
    /// Only checked with every stream kept; otherwise ffmpeg picks its own streams.
    public static func sourceProblem(_ settings: ConversionSettings, source: MediaInfo) -> String? {
        guard settings.preserveAllStreams, settings.container != .gif else { return nil }
        let container = settings.container
        let target = container.fileExtension.uppercased()

        if container.supportsSubtitles {
            for (index, codec) in source.subtitleCodecs.enumerated()
            where subtitleHandling(for: codec, in: container) == .unsupported {
                return "Subtitle track \(index + 1) (\(displayName(ofCodec: codec))) can't go into \(target). "
                    + "Use MKV, or turn off Keep all tracks."
            }
        }

        // Audio that is copied rather than re-encoded: every track with Copy, every track but the
        // first otherwise (see `ArgumentBuilder`: `-c:a copy -c:a:0 <encoder>`). MP3, FLAC and WAV
        // hold one audio stream, so only the first track is mapped at all.
        let mapped = [Container.mp3, .flac, .wav].contains(container)
            ? Array(source.audioCodecs.prefix(1)) : source.audioCodecs
        let firstCopiedTrack: Int
        switch settings.audioCodec {
        case .none: return nil
        case .copy: firstCopiedTrack = 0
        default:    firstCopiedTrack = 1
        }
        for (index, codec) in mapped.enumerated()
        where index >= firstCopiedTrack && !canCopyAudio(codec, into: container) {
            let what = "Audio track \(index + 1) (\(displayName(ofCodec: codec))) can't go into \(target)."
            // A copied first track is the user's own choice; turning Keep all off would not change it.
            return index == 0
                ? "\(what) Pick another audio codec, or use MKV."
                : "\(what) Use MKV, or turn off Keep all tracks."
        }
        return nil
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

    /// Highest audio bitrate (kbps) offered for each lossy encoder at `channels` output channels,
    /// measured against ffmpeg 9.0.2. A preset above it is rejected or silently clamped:
    ///   - opus: libopus allows 256 kbps per channel, so mono fails above 256, stereo above
    ///     512; 5.1 and 7.1 take the whole list.
    ///   - mp3: capped at 320 kbps whatever the layout; anything higher is clamped.
    ///   - ac3: capped at 640 kbps whatever the layout; anything higher is clamped.
    ///   - aac: never refuses a value, but the encoder takes more per extra channel and plateaus
    ///     (about 220 kbps for mono, 420 stereo, 1100 for 5.1, 1500+ for 7.1 on noise). This is a
    ///     picker policy, not a hard limit: up to stereo the list keeps its old 640, surround gets
    ///     the 768+ presets.
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

    /// Channel count the settings-level bitrate rules assume for a layout. "Same as source" is
    /// not known until a file is probed and a batch can mix layouts, so it stays permissive (the
    /// widest ceiling) and never hides a preset that some file in the batch can take;
    /// `ArgumentBuilder` lowers the request to each file's real ceiling when converting.
    static func assumedChannelCount(_ channels: AudioChannels) -> Int {
        channels.count ?? AudioChannels.surround71.count!
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
