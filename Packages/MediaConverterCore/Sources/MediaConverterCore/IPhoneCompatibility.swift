import Foundation

public struct IPhoneCompatibility: Sendable, Equatable {
    public let isCompatible: Bool
    public let reason: String?
    public init(isCompatible: Bool, reason: String?) {
        self.isCompatible = isCompatible
        self.reason = reason
    }
}

public enum IPhoneCompatibilityChecker {
    private static let videoCodecs: Set<String> = ["h264", "hevc"]
    private static let audioCodecs: Set<String> = ["aac", "mp3", "alac"]
    private static let containers: Set<Container> = [.mp4, .mov, .m4v, .m4a, .mp3]

    public static func evaluate(_ s: ConversionSettings, source: MediaInfo) -> IPhoneCompatibility {
        guard containers.contains(s.container) else {
            return .init(isCompatible: false,
                         reason: "\(s.container.fileExtension.uppercased()) files don't play on iPhone")
        }
        if !s.container.isAudioOnly && s.videoCodec != .none {
            let name = (s.videoCodec == .copy) ? source.videoCodecName : s.videoCodec.canonicalName
            if !(name.map(videoCodecs.contains) ?? false) {
                return .init(isCompatible: false, reason: videoReason(s.videoCodec, source: source))
            }
        }
        if s.audioCodec != .none {
            let name = (s.audioCodec == .copy) ? source.audioCodecName : s.audioCodec.canonicalName
            if !(name.map(audioCodecs.contains) ?? false) {
                return .init(isCompatible: false, reason: audioReason(s.audioCodec, source: source))
            }
        }
        return .init(isCompatible: true, reason: nil)
    }

    private static func videoReason(_ c: VideoCodec, source: MediaInfo) -> String {
        switch c {
        case .av1:  return "AV1 video only plays on iPhone 15 Pro and newer"
        case .vp9:  return "VP9 video doesn't play on iPhone"
        case .copy: return "The source video (\(source.videoCodecName ?? "none")) isn't H.264 or HEVC"
        default:    return "This video codec doesn't play on iPhone"
        }
    }
    private static func audioReason(_ c: AudioCodec, source: MediaInfo) -> String {
        switch c {
        case .opus: return "Opus audio doesn't play on iPhone"
        case .copy: return "The source audio (\(source.audioCodecName ?? "none")) isn't AAC, MP3, or ALAC"
        default:    return "This audio codec doesn't play on iPhone"
        }
    }
}
