import Foundation

public enum ArgumentBuilder {
    static func videoToolboxQuality(fromCRF crf: Int) -> Int {
        max(1, min(100, 100 - crf * 2))
    }

    /// VideoToolbox HDR→SDR filter graph, run on software frames that `hwupload`
    /// moves onto the device.
    ///
    /// `scale=out_range=tv` first: `hwupload` creates video-range buffers, so a
    /// full-range source would otherwise be read as limited range and come out
    /// with lifted blacks, capped whites and a `pc` tag on limited-range pixels.
    /// `format=p010le` then makes every source — 8-bit, 10-bit, 4:2:2 — enter the
    /// device as the one format `scale_vt` hands back as `p010le`: `hwdownload`
    /// can only return the frame context's own format, so without it 8-bit
    /// sources fail with "Invalid output format p010le for hwframe download".
    static let toneMapFilter = [
        "scale=out_range=tv",
        "format=p010le",
        "hwupload",
        "scale_vt=color_matrix=bt709:color_primaries=bt709:color_transfer=bt709",
        "hwdownload",
        "format=p010le",
        "sidedata=mode=delete:type=MASTERING_DISPLAY_METADATA",
        "sidedata=mode=delete:type=CONTENT_LIGHT_LEVEL",
    ].joined(separator: ",")

    /// Builds the ffmpeg command(s) for a conversion. Returns one command for
    /// every mode except software 2-pass bitrate, which returns `[pass1, pass2]`.
    /// `passLog` is the `-passlogfile` prefix (used only for 2-pass).
    public static func build(settings s: ConversionSettings, input: String, output: String,
                             source: MediaInfo, passLog: String = "") -> [[String]] {
        if s.container == .gif {
            return [["-hide_banner", "-y", "-i", input, "-an", output]]
        }

        let mp4Family: Set<Container> = [.mp4, .mov, .m4v]
        // Only HDR sources are tone mapped: the graph is built for them and the
        // toggle is shared by the whole batch, so SDR files must pass untouched.
        let toneMap = s.effectiveToneMapHDR && source.isHDR
        // `scale_vt` runs on a VideoToolbox device declared by `-init_hw_device`.
        // No `-hwaccel`: it made no measurable difference to speed, and it forces
        // ffmpeg's hardware-only AV1 decoder, which fails outright on Macs without
        // AV1 decode hardware instead of falling back to a software decoder.
        let hwInput: [String] = toneMap
            ? ["-init_hw_device", "videotoolbox=vt", "-filter_hw_device", "vt"]
            : []
        let inputArgs = ["-hide_banner", "-y"] + hwInput + ["-i", input]

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

        if toneMap {
            // `scale_vt` is Apple's tone mapper (the same one QuickTime uses). It
            // returns 10-bit VT frames, so download via p010le — nv12 is rejected —
            // and let the encoder's own `-pix_fmt` narrow to 8-bit where wanted.
            // hwdownload leaves the bt2020nc matrix tag on bt709 pixels and passes
            // the HDR mastering/CLL side data through, which makes players
            // misinterpret chroma or re-flag the file as HDR: drop the side data
            // in the graph and stamp the encoder colour tags explicitly.
            videoEncode += ["-vf", Self.toneMapFilter,
                            "-colorspace", "bt709", "-color_primaries", "bt709",
                            "-color_trc", "bt709"]
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
        //
        // With it on, streams are mapped by kind. A blanket `-map 0` also pulls in
        // data streams (iPhone `mebx` timed metadata, the text track MP4 uses for
        // chapters), cover art and attachments, which most muxers reject; and in
        // 2-pass runs it lets cover art or an audio-first source move the video off
        // output index 0, where pass 1 wrote its stats file.
        var mapArgs: [String] = []
        var dispositionArgs: [String] = []
        if s.preserveAllStreams {
            if s.container.supportsSubtitles {
                // `0:V` skips attached pictures: a re-encode would turn cover art into
                // a second video track. Video copy takes `0:v` so the picture survives.
                if s.videoCodec != .none {
                    mapArgs += ["-map", s.videoCodec == .copy ? "0:v" : "0:V"]
                }
                mapArgs += ["-map", "0:a?", "-map", "0:s?"]
                // Only Matroska stores attachments (fonts for styled subtitles).
                if s.container == .mkv { mapArgs += ["-map", "0:t?"] }
                // Subtitles are re-muxed, never re-encoded, so copy them through.
                mapArgs += ["-c:s", "copy"]
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
                // Audio-only targets carry no video or subtitles. MP3, FLAC and WAV hold
                // exactly one audio stream; M4A takes any number.
                mapArgs = ["-map", s.container == .m4a ? "0:a" : "0:a:0"]
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
