import Foundation

public struct MediaInfo: Sendable, Equatable {
    public var durationSeconds: Double?
    public var videoCodecName: String?
    public var audioCodecName: String?
    /// ISO 639-2 language tag of every subtitle stream, in source order.
    /// Streams with no language tag appear as an empty string so the indices
    /// stay aligned with ffmpeg's `-disposition:s:<n>` numbering.
    public var subtitleLanguages: [String]
    /// ffprobe `codec_name` of every subtitle stream, in the same order as `subtitleLanguages`
    /// (`subrip`, `ass`, `mov_text`, `webvtt`, `hdmv_pgs_subtitle`, ...). Empty when unknown.
    public var subtitleCodecs: [String]
    /// ffprobe `color_transfer` of the first video stream (e.g. `smpte2084`,
    /// `arib-std-b67`, `bt709`). nil when untagged or audio-only.
    public var colorTransfer: String?
    /// Channel count of the audio stream ffmpeg picks when nothing is mapped explicitly: the one
    /// flagged `default`, else the one with the most channels, the first of equals. Needed to apply
    /// the per-layout audio bitrate ceiling when the output layout is "same as source".
    /// nil when there is no audio stream or the count is unknown.
    public var audioChannels: Int?
    /// Channel count of the first audio stream: with every stream kept, the first one is the one
    /// `-c:a:0` re-encodes. nil when unknown.
    public var firstAudioChannels: Int?

    public init(durationSeconds: Double? = nil, videoCodecName: String? = nil,
                audioCodecName: String? = nil, subtitleLanguages: [String] = [],
                subtitleCodecs: [String] = [],
                colorTransfer: String? = nil, audioChannels: Int? = nil,
                firstAudioChannels: Int? = nil) {
        self.durationSeconds = durationSeconds
        self.videoCodecName = videoCodecName
        self.audioCodecName = audioCodecName
        self.subtitleLanguages = subtitleLanguages
        self.subtitleCodecs = subtitleCodecs
        self.colorTransfer = colorTransfer
        self.audioChannels = audioChannels
        self.firstAudioChannels = firstAudioChannels ?? audioChannels
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
