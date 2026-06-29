import Foundation

public struct MediaInfo: Sendable, Equatable {
    public var durationSeconds: Double?
    public var videoCodecName: String?
    public var audioCodecName: String?

    public init(durationSeconds: Double? = nil, videoCodecName: String? = nil, audioCodecName: String? = nil) {
        self.durationSeconds = durationSeconds
        self.videoCodecName = videoCodecName
        self.audioCodecName = audioCodecName
    }
}
