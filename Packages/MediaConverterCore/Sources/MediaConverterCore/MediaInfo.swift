import Foundation

public struct MediaInfo: Sendable, Equatable {
    public var durationSeconds: Double?
    public var videoCodecName: String?
    public var audioCodecName: String?
    /// ISO 639-2 language tag of every subtitle stream, in source order.
    /// Streams with no language tag appear as an empty string so the indices
    /// stay aligned with ffmpeg's `-disposition:s:<n>` numbering.
    public var subtitleLanguages: [String]

    public init(durationSeconds: Double? = nil, videoCodecName: String? = nil,
                audioCodecName: String? = nil, subtitleLanguages: [String] = []) {
        self.durationSeconds = durationSeconds
        self.videoCodecName = videoCodecName
        self.audioCodecName = audioCodecName
        self.subtitleLanguages = subtitleLanguages
    }
}
