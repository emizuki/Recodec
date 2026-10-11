import Foundation

public struct MediaInfo: Sendable, Equatable {
    public var durationSeconds: Double?
    public var videoCodecName: String?
    public var audioCodecName: String?
    /// ISO 639-2 language tag of every subtitle stream, in source order.
    /// Streams with no language tag appear as an empty string so the indices
    /// stay aligned with ffmpeg's `-disposition:s:<n>` numbering.
    public var subtitleLanguages: [String]
    /// ffprobe `color_transfer` of the first video stream (e.g. `smpte2084`,
    /// `arib-std-b67`, `bt709`). nil when untagged or audio-only.
    public var colorTransfer: String?
    /// Channel count of the first audio stream. Needed to apply the per-layout audio
    /// bitrate ceiling when the output layout is "same as source". nil when unknown.
    public var audioChannels: Int?

    public init(durationSeconds: Double? = nil, videoCodecName: String? = nil,
                audioCodecName: String? = nil, subtitleLanguages: [String] = [],
                colorTransfer: String? = nil, audioChannels: Int? = nil) {
        self.durationSeconds = durationSeconds
        self.videoCodecName = videoCodecName
        self.audioCodecName = audioCodecName
        self.subtitleLanguages = subtitleLanguages
        self.colorTransfer = colorTransfer
        self.audioChannels = audioChannels
    }

    /// True when the video stream carries an HDR transfer function (PQ or HLG).
    /// Such sources look washed out on SDR displays unless tone mapped.
    public var isHDR: Bool {
        switch colorTransfer {
        case "smpte2084", "arib-std-b67": return true
        default: return false
        }
    }
}
