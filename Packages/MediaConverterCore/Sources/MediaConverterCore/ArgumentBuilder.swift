import Foundation

public enum ArgumentBuilder {
    static func videoToolboxQuality(fromCRF crf: Int) -> Int {
        max(1, min(100, 100 - crf * 2))
    }

    public static func build(settings s: ConversionSettings, input: String, output: String, source: MediaInfo) -> [String] {
        // GIF: let ffmpeg's gif muxer auto-select the encoder; strip audio; no codec/crf/tag flags.
        if s.container == .gif {
            return ["-hide_banner", "-y", "-i", input, "-an", output]
        }

        var args = ["-hide_banner", "-y", "-i", input]
        let mp4Family: Set<Container> = [.mp4, .mov, .m4v]

        // ---- video ----
        switch s.videoCodec {
        case .none:
            args += ["-vn"]
        case .copy:
            args += ["-c:v", "copy"]
            if source.videoCodecName == "hevc", mp4Family.contains(s.container) {
                args += ["-tag:v", "hvc1"]
            }
        default:
            if s.useHardware, let hw = s.videoCodec.hardwareEncoder {
                args += ["-c:v", hw, "-q:v", String(videoToolboxQuality(fromCRF: s.crf))]
            } else if let sw = s.videoCodec.softwareEncoder {
                args += ["-c:v", sw, "-crf", String(s.crf)]
                if s.videoCodec == .vp9 { args += ["-b:v", "0"] }
            }
            if s.videoCodec == .h264 || s.videoCodec == .hevc {
                args += ["-pix_fmt", "yuv420p"]
            }
            if s.videoCodec == .h264 {
                args += ["-profile:v", "high"]
            }
            if s.videoCodec == .hevc, mp4Family.contains(s.container) {
                args += ["-tag:v", "hvc1"]
            }
        }

        // ---- audio ----
        switch s.audioCodec {
        case .none:
            args += ["-an"]
        case .copy:
            args += ["-c:a", "copy"]
        default:
            if let enc = s.audioCodec.encoder {
                args += ["-c:a", enc]
                if s.audioCodec.supportsBitrate, let bitrate = s.audioBitrate.ffmpegArgument {
                    args += ["-b:a", bitrate]
                }
                if let ch = s.channels.count {
                    args += ["-ac", String(ch)]
                }
            }
        }

        // ---- container ----
        if s.container.supportsFaststart {
            args += ["-movflags", "+faststart"]
        }

        args.append(output)
        return args
    }
}
