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
                if s.preserveAllStreams {
                    // With every stream mapped, a bare `-c:a` would re-encode all of
                    // them — turning a secondary AC-3 compatibility track into a
                    // second-generation lossy copy at the primary track's bitrate.
                    // Transcode the first audio stream only and carry the rest through.
                    audioArgs = ["-c:a", "copy", "-c:a:0", enc]
                    if s.audioCodec.supportsBitrate, let bitrate = s.audioBitrate.ffmpegArgument {
                        audioArgs += ["-b:a:0", bitrate]
                    }
                    if let ch = s.channels.count {
                        audioArgs += ["-ac:a:0", String(ch)]
                    }
                } else {
                    audioArgs = ["-c:a", enc]
                    if s.audioCodec.supportsBitrate, let bitrate = s.audioBitrate.ffmpegArgument {
                        audioArgs += ["-b:a", bitrate]
                    }
                    if let ch = s.channels.count {
                        audioArgs += ["-ac", String(ch)]
                    }
                }
            }
        }

        let faststart = s.container.supportsFaststart ? ["-movflags", "+faststart"] : []

        // Stream mapping is opt-in. Without it ffmpeg picks one stream of each
        // kind (its default selection), which is the historical behaviour and
        // stays byte-identical when `preserveAllStreams` is off.
        var mapArgs: [String] = []
        var dispositionArgs: [String] = []
        if s.preserveAllStreams {
            if s.container.supportsSubtitles {
                // Subtitles are re-muxed, never re-encoded, so copy them through.
                mapArgs = ["-map", "0", "-c:s", "copy"]
                switch s.subtitleDefault {
                case .unchanged:
                    break
                case .none:
                    dispositionArgs = ["-disposition:s", "0"]
                case .language(let code):
                    let idx = source.subtitleLanguages.firstIndex {
                        $0.caseInsensitiveCompare(code) == .orderedSame
                    }
                    // Clear every subtitle default first, then set the match.
                    dispositionArgs = ["-disposition:s", "0"]
                    if let idx {
                        dispositionArgs += ["-disposition:s:\(idx)", "default"]
                    }
                }
            } else {
                // Audio-only/GIF targets cannot carry subtitles; mapping them in
                // would abort the run, so drop subtitle streams explicitly.
                mapArgs = ["-map", "0", "-sn"]
            }
        }

        if s.effectiveTwoPass {
            let pass1 = inputArgs + videoEncode
                + ["-pass", "1", "-passlogfile", passLog, "-an", "-f", "null", "/dev/null"]
            let pass2 = inputArgs + videoEncode
                + ["-pass", "2", "-passlogfile", passLog] + videoTag + audioArgs
                + mapArgs + dispositionArgs + faststart + [output]
            return [pass1, pass2]
        }
        return [inputArgs + videoEncode + videoTag + audioArgs
                + mapArgs + dispositionArgs + faststart + [output]]
    }
}
