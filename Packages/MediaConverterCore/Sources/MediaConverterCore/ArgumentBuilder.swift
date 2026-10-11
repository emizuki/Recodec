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
        // Hardware decode (`-hwaccel`) is added for H.264 and HEVC only: there it cuts
        // wall time and CPU by roughly a quarter to a half, and ffmpeg falls back to its
        // software decoder if the hardware cannot take a profile. For AV1 it would force
        // the hardware-only decoder, which fails outright on Macs without AV1 decode
        // hardware, so every other codec is decoded in software.
        let hwDecodes = source.videoCodecName == "h264" || source.videoCodecName == "hevc"
        let hwInput: [String] = toneMap
            ? ["-init_hw_device", "videotoolbox=vt", "-filter_hw_device", "vt"]
                + (hwDecodes ? ["-hwaccel", "videotoolbox"] : [])
            : []
        // With every stream kept there can be a cover picture besides the video: `hvc1`
        // must only tag the first video stream, or the MP4 muxer rejects the picture.
        let tagVideo = s.preserveAllStreams ? "-tag:v:0" : "-tag:v"
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
                videoTag = [tagVideo, "hvc1"]
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
                videoTag = [tagVideo, "hvc1"]
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

        // The picker only offers bitrates the chosen layout accepts, but "same as source"
        // leaves the layout to the file: a mono source asked for 512 kbps Opus would be
        // rejected by libopus (256 kbps per channel). Apply the ceiling with the real channel
        // count of the stream that gets encoded so such a request is lowered instead of failing
        // the run: the one ffmpeg selects by itself, or the first one when every stream is kept
        // (`-c:a:0`). Never raised, and an unknown count assumes stereo.
        var audioBitrate = s.audioBitrate
        let encodedChannels = s.channels.count
            ?? (s.preserveAllStreams ? source.firstAudioChannels : source.audioChannels) ?? 2
        if case .kbps(let requested) = s.audioBitrate,
           let ceiling = CodecCompatibility.maxAudioKbps(for: s.audioCodec, channels: encodedChannels) {
            audioBitrate = .kbps(min(requested, ceiling))
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
                    if s.audioCodec.supportsBitrate, let bitrate = audioBitrate.ffmpegArgument {
                        audioArgs += ["-b:a:0", bitrate]
                    }
                    if let ch = s.channels.count {
                        audioArgs += ["-ac:a:0", String(ch)]
                    }
                } else {
                    audioArgs = ["-c:a", enc]
                    if s.audioCodec.supportsBitrate, let bitrate = audioBitrate.ffmpegArgument {
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
                    // Optional (`?`): an audio-only source has no video stream to map.
                    mapArgs += ["-map", s.videoCodec == .copy ? "0:v?" : "0:V?"]
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
                    // `-default` clears only that flag; `-disposition:s 0` would also wipe
                    // `forced`, so forced-subtitle tracks would stop showing on their own.
                    dispositionArgs = ["-disposition:s", "-default"]
                case .language(let code):
                    let wanted = SubtitleDefault.canonicalLanguage(code)
                    let idx = source.subtitleLanguages.firstIndex {
                        SubtitleDefault.canonicalLanguage($0) == wanted
                    }
                    // Clear every subtitle default first, then set the match.
                    dispositionArgs = ["-disposition:s", "-default"]
                    if let idx {
                        dispositionArgs += ["-disposition:s:\(idx)", "+default"]
                    }
                }
            } else {
                // Audio-only targets carry no video or subtitles. MP3, FLAC and WAV hold
                // exactly one audio stream; M4A takes any number.
                mapArgs = ["-map", s.container == .m4a ? "0:a" : "0:a:0"]
            }
        }

        if s.effectiveTwoPass {
            // Pass 1 must map the video the way pass 2 does: each encoder opens its stats
            // file by output index, and ffmpeg's default selection would pick a single
            // video, leaving a source with several real video streams without logs.
            let pass1Map: [String] = s.preserveAllStreams ? ["-map", "0:V?"] : []
            let pass1 = inputArgs + videoEncode + pass1Map
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
