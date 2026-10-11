import Foundation

public enum FFprobeParser {
    private struct Probe: Decodable {
        struct Tags: Decodable { let language: String? }
        struct Disposition: Decodable { let `default`: Int? }
        struct Stream: Decodable {
            let codec_type: String?
            let codec_name: String?
            let color_transfer: String?
            let channels: Int?
            let disposition: Disposition?
            let tags: Tags?
        }
        struct Format: Decodable { let duration: String? }
        let streams: [Stream]?
        let format: Format?
    }

    /// The audio stream ffmpeg selects when nothing is mapped (ffmpeg's `map_auto_audio`). Its score
    /// is `channels + 5_000_000 * default + 100_000_000 * (packets seen while probing)`; the first of
    /// equals wins. The packet term cannot be read from ffprobe's output (it depends on the probe
    /// window), so this models the usual case: a stream flagged `default` outranks the channel count,
    /// then the most channels wins. A track that only starts after the probe window loses in ffmpeg
    /// but is not seen here; that can only matter for the Opus bitrate ceiling.
    private static func autoSelectedAudio(_ streams: [Probe.Stream]) -> Probe.Stream? {
        var best: (stream: Probe.Stream, score: Int)?
        for stream in streams {
            let score = (stream.channels ?? 0) + ((stream.disposition?.default ?? 0) != 0 ? 5_000_000 : 0)
            if best == nil || score > best!.score { best = (stream, score) }
        }
        return best?.stream
    }

    public static func parse(_ data: Data) throws -> MediaInfo {
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        let videoStream = probe.streams?.first { $0.codec_type == "video" }
        let video = videoStream?.codec_name
        let audioStreams = probe.streams?.filter { $0.codec_type == "audio" } ?? []
        let audioStream = audioStreams.first
        let audio = audioStream?.codec_name
        let duration = probe.format?.duration.flatMap(Double.init)
        // Subtitle order here must match ffmpeg's own `-disposition:s:<n>` index,
        // so keep untagged streams in place as empty strings rather than dropping them.
        let subtitles = probe.streams?
            .filter { $0.codec_type == "subtitle" }
            .map { $0.tags?.language ?? "" } ?? []
        return MediaInfo(durationSeconds: duration, videoCodecName: video,
                         audioCodecName: audio, subtitleLanguages: subtitles,
                         colorTransfer: videoStream?.color_transfer,
                         audioChannels: autoSelectedAudio(audioStreams)?.channels,
                         firstAudioChannels: audioStream?.channels)
    }
}
