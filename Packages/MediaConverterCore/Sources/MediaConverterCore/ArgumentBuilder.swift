import Foundation

public enum ArgumentBuilder {
    static func videoToolboxQuality(fromCRF crf: Int) -> Int {
        max(1, min(100, 100 - crf * 2))
    }

    /// Builds the ffmpeg command(s) for a conversion. Returns one command for
    /// every mode except software 2-pass bitrate, which returns `[pass1, pass2]`.
    /// `passLog` is the `-passlogfile` prefix (used only for 2-pass).
    public static func build(settings s: ConversionSettings, input: String, output: String,
                             source: MediaInfo, passLog: String = "") -> [[String]] {
        if s.container == .gif {
            return [["-hide_banner", "-y", "-i", input, "-an", output]]
        }

        let mp4Family: Set<Container> = [.mp4, .mov, .m4v]
        let inputArgs = ["-hide_banner", "-y", "-i", input]

        // Video encode args (codec + rate control + preset + pix_fmt + profile).
        // `videoTag` (container hvc1) is kept separate so pass 1 can omit it.
        var videoEncode: [String] = []
        var videoTag: [String] = []

        switch s.videoCodec {
        case .none:
            videoEncode = ["-vn"]
        case .copy:
            videoEncode = ["-c:v", "copy"]
            if source.videoCodecName == "hevc", mp4Family.contains(s.container) {
                videoTag = ["-tag:v", "hvc1"]
            }
        case .prores:
            if s.useHardware, let hw = s.videoCodec.hardwareEncoder {
                videoEncode = ["-c:v", hw, "-profile:v", String(s.proResProfile.ffmpegValue)]
            } else if let sw = s.videoCodec.softwareEncoder {
                videoEncode = ["-c:v", sw, "-profile:v", String(s.proResProfile.ffmpegValue)]
            }
        default: // h264 / hevc / av1 / vp9
            if s.useHardware, let hw = s.videoCodec.hardwareEncoder {
                videoEncode = ["-c:v", hw]
                videoEncode += s.usesBitrate
                    ? ["-b:v", "\(s.videoBitrateKbps)k"]
                    : ["-q:v", String(videoToolboxQuality(fromCRF: s.crf))]
            } else if let sw = s.videoCodec.softwareEncoder {
                videoEncode = ["-c:v", sw]
                if s.videoCodec.supportsPreset {
                    videoEncode += s.videoCodec == .av1
                        ? ["-preset", String(s.preset.svtAV1Value)]
                        : ["-preset", s.preset.x264Name]
                }
                if s.usesBitrate {
                    videoEncode += ["-b:v", "\(s.videoBitrateKbps)k"]
                } else {
                    videoEncode += ["-crf", String(s.crf)]
                    if s.videoCodec == .vp9 { videoEncode += ["-b:v", "0"] }
                }
            }
            if s.videoCodec == .h264 || s.videoCodec == .hevc {
                videoEncode += ["-pix_fmt", "yuv420p"]
            }
            if s.videoCodec == .h264 {
                videoEncode += ["-profile:v", "high"]
            }
            if s.videoCodec == .hevc, mp4Family.contains(s.container) {
                videoTag = ["-tag:v", "hvc1"]
            }
        }

        var audioArgs: [String] = []
        switch s.audioCodec {
        case .none:
            audioArgs = ["-an"]
        case .copy:
            audioArgs = ["-c:a", "copy"]
        default:
            if let enc = s.audioCodec.encoder {
                audioArgs = ["-c:a", enc]
                if s.audioCodec.supportsBitrate, let bitrate = s.audioBitrate.ffmpegArgument {
                    audioArgs += ["-b:a", bitrate]
                }
                if let ch = s.channels.count {
                    audioArgs += ["-ac", String(ch)]
                }
            }
        }

        let faststart = s.container.supportsFaststart ? ["-movflags", "+faststart"] : []

        if s.effectiveTwoPass {
            let pass1 = inputArgs + videoEncode
                + ["-pass", "1", "-passlogfile", passLog, "-an", "-f", "null", "/dev/null"]
            let pass2 = inputArgs + videoEncode
                + ["-pass", "2", "-passlogfile", passLog] + videoTag + audioArgs + faststart + [output]
            return [pass1, pass2]
        }
        return [inputArgs + videoEncode + videoTag + audioArgs + faststart + [output]]
    }
}
