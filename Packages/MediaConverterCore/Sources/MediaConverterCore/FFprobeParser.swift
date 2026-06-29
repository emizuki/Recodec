import Foundation

public enum FFprobeParser {
    private struct Probe: Decodable {
        struct Stream: Decodable { let codec_type: String?; let codec_name: String? }
        struct Format: Decodable { let duration: String? }
        let streams: [Stream]?
        let format: Format?
    }

    public static func parse(_ data: Data) throws -> MediaInfo {
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        let video = probe.streams?.first { $0.codec_type == "video" }?.codec_name
        let audio = probe.streams?.first { $0.codec_type == "audio" }?.codec_name
        let duration = probe.format?.duration.flatMap(Double.init)
        return MediaInfo(durationSeconds: duration, videoCodecName: video, audioCodecName: audio)
    }
}
