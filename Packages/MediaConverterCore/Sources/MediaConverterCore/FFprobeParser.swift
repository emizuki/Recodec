import Foundation

public enum FFprobeParser {
    private struct Probe: Decodable {
        struct Tags: Decodable { let language: String? }
        struct Stream: Decodable {
            let codec_type: String?
            let codec_name: String?
            let tags: Tags?
        }
        struct Format: Decodable { let duration: String? }
        let streams: [Stream]?
        let format: Format?
    }

    public static func parse(_ data: Data) throws -> MediaInfo {
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        let video = probe.streams?.first { $0.codec_type == "video" }?.codec_name
        let audio = probe.streams?.first { $0.codec_type == "audio" }?.codec_name
        let duration = probe.format?.duration.flatMap(Double.init)
        // Subtitle order here must match ffmpeg's own `-disposition:s:<n>` index,
        // so keep untagged streams in place as empty strings rather than dropping them.
        let subtitles = probe.streams?
            .filter { $0.codec_type == "subtitle" }
            .map { $0.tags?.language ?? "" } ?? []
        return MediaInfo(durationSeconds: duration, videoCodecName: video,
                         audioCodecName: audio, subtitleLanguages: subtitles)
    }
}
