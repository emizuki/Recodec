import XCTest
@testable import MediaConverterCore

final class ArgumentBuilderTests: XCTestCase {
    let src = MediaInfo(durationSeconds: 10, videoCodecName: "hevc", audioCodecName: "aac")
    /// A multi-track source: 3 subtitle streams, English second.
    let multiTrack = MediaInfo(durationSeconds: 10, videoCodecName: "hevc",
                               audioCodecName: "truehd",
                               subtitleLanguages: ["ger", "eng", "fre"])

    // MARK: - Stream preservation (opt-in)

    func testPreserveAllStreamsOffEmitsNoMapping() {
        // Regression guard: the default path must stay byte-identical to the
        // behaviour that shipped before stream preservation existed.
        let s = ConversionSettings(container: .mkv, videoCodec: .copy, audioCodec: .eac3,
                                   crf: 20, channels: .surround51, audioBitrate: .kbps(1536))
        let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mkv",
                                         source: multiTrack)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y", "-i", "/in.mkv",
            "-c:v", "copy",
            "-c:a", "eac3", "-b:a", "1536k", "-ac", "6",
            "/out.mkv"
        ]])
        XCTAssertFalse(args[0].contains("-map"))
        XCTAssertFalse(args[0].contains("-disposition:s"))
    }

    /// Values of every `-map` in an argv, in order.
    private func maps(_ args: [String]) -> [String] {
        args.indices.dropLast().filter { args[$0] == "-map" }.map { args[$0 + 1] }
    }

    func testPreserveAllStreamsMapsByKindNeverEverything() {
        // A blanket `-map 0` also maps data streams (iPhone `mebx`, MP4 chapter text
        // tracks), attachments and cover art, which most muxers reject.
        func mapped(_ container: Container, _ video: VideoCodec, audio: AudioCodec = .aac) -> [String] {
            var s = ConversionSettings(container: container, videoCodec: video, audioCodec: audio, crf: 20)
            s.preserveAllStreams = true
            let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out", source: multiTrack)
            return maps(args[0])
        }
        // Video maps are optional (`?`): an audio-only source has no video stream, and a
        // required map would abort the run for it.
        // Re-encode: `0:V` leaves cover art out instead of encoding it as a second video track.
        XCTAssertEqual(mapped(.mp4, .h264), ["0:V?", "0:a?", "0:s?"])
        // Video copy: `0:v` so an attached picture is carried through untouched.
        XCTAssertEqual(mapped(.mp4, .copy), ["0:v?", "0:a?", "0:s?"])
        // Only Matroska stores attachments.
        XCTAssertEqual(mapped(.mkv, .copy), ["0:v?", "0:a?", "0:s?", "0:t?"])
        // No video encoder, nothing to map for it.
        XCTAssertEqual(mapped(.mp4, .none), ["0:a?", "0:s?"])
        // MP3/FLAC/WAV muxers hold exactly one audio stream, M4A any number.
        XCTAssertEqual(mapped(.mp3, .none, audio: .mp3), ["0:a:0"])
        XCTAssertEqual(mapped(.flac, .none, audio: .flac), ["0:a:0"])
        XCTAssertEqual(mapped(.wav, .none, audio: .pcm), ["0:a:0"])
        XCTAssertEqual(mapped(.m4a, .none), ["0:a"])
    }

    func testPreserveAllStreamsMapsVideoFirstSoTwoPassStatsLineUp() {
        // Pass 1 (default selection) writes `<log>-0.log` for the video. Pass 2 opens the
        // log by output stream index, so the video must be output stream 0 here too.
        var s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20)
        s.rateControl = .bitrate
        s.videoBitrateKbps = 2500
        s.preserveAllStreams = true
        let cmds = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mp4",
                                         source: multiTrack, passLog: "/tmp/log")
        XCTAssertEqual(cmds.count, 2)
        XCTAssertEqual(maps(cmds[1]).first, "0:V?")
    }

    func testPreserveAllStreamsTranscodesOnlyFirstAudioTrack() {
        // Regression: a bare `-c:a eac3` applies to every mapped audio stream, so a
        // secondary AC-3 track gets re-encoded lossy->lossy at the primary bitrate.
        var s = ConversionSettings(container: .mkv, videoCodec: .copy, audioCodec: .eac3,
                                   crf: 20, channels: .surround51, audioBitrate: .kbps(1536))
        s.preserveAllStreams = true
        let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mkv",
                                         source: multiTrack)[0]
        // Every encode option must be stream-qualified, and `-c:a copy` must precede it.
        XCTAssertTrue(args.contains("-c:a:0"))
        XCTAssertTrue(args.contains("-b:a:0"))
        XCTAssertTrue(args.contains("-ac:a:0"))
        XCTAssertFalse(args.contains("-b:a"), "unqualified -b:a would hit every audio stream")
        XCTAssertFalse(args.contains("-ac"), "unqualified -ac would hit every audio stream")
        let cIdx = args.firstIndex(of: "-c:a")!
        XCTAssertEqual(args[cIdx + 1], "copy")
        XCTAssertLessThan(cIdx, args.firstIndex(of: "-c:a:0")!)
        // The qualified options must also carry the chosen values, not just exist.
        XCTAssertEqual(args[args.firstIndex(of: "-b:a:0")! + 1], "1536k")
        XCTAssertEqual(args[args.firstIndex(of: "-ac:a:0")! + 1], "6")
    }

    /// Pairs of adjacent arguments, for asserting a flag is followed by its value.
    private func pairs(_ args: [String]) -> [[String]] {
        zip(args, args.dropFirst()).map { [$0, $1] }
    }

    func testPreserveAllStreamsTagsOnlyTheFirstVideoStream() {
        // A cover picture may follow the video; `-tag:v hvc1` would hit it too and the
        // MP4 muxer rejects the combination. Off by default: argv stays unchanged.
        let hevcSource = MediaInfo(durationSeconds: 10, videoCodecName: "hevc", audioCodecName: "aac")
        for video in [VideoCodec.hevc, .copy] {
            var s = ConversionSettings(container: .mp4, videoCodec: video, audioCodec: .aac, crf: 20)
            s.preserveAllStreams = true
            let on = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4", source: hevcSource)[0]
            XCTAssertTrue(pairs(on).contains(["-tag:v:0", "hvc1"]), "\(video)")
            XCTAssertFalse(on.contains("-tag:v"), "\(video)")
            s.preserveAllStreams = false
            let off = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4", source: hevcSource)[0]
            XCTAssertTrue(pairs(off).contains(["-tag:v", "hvc1"]), "\(video)")
        }
    }

    func testPreserveAllStreamsWithCopyAudioIsUnqualified() {
        // Audio: Copy needs no per-stream override — everything is copied anyway.
        var s = ConversionSettings(container: .mkv, videoCodec: .copy, audioCodec: .copy, crf: 20)
        s.preserveAllStreams = true
        let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mkv",
                                         source: multiTrack)[0]
        XCTAssertFalse(args.contains("-c:a:0"))
        XCTAssertTrue(args.contains("-c:a"))
    }

    func testSubtitleDefaultByLanguageUsesSubtitleRelativeIndex() {
        var s = ConversionSettings(container: .mkv, videoCodec: .copy, audioCodec: .copy, crf: 20)
        s.preserveAllStreams = true
        s.subtitleDefault = .language("eng")
        let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mkv",
                                         source: multiTrack)
        // "eng" is the 2nd subtitle stream -> index 1, not its absolute stream index.
        XCTAssertEqual(pairs(args[0]).filter { $0[0].hasPrefix("-disposition:s") },
                       [["-disposition:s", "-default"], ["-disposition:s:1", "+default"]])
    }

    func testSubtitleDefaultLanguageMissingClearsOnly() {
        var s = ConversionSettings(container: .mkv, videoCodec: .copy, audioCodec: .copy, crf: 20)
        s.preserveAllStreams = true
        s.subtitleDefault = .language("jpn")
        let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mkv",
                                         source: multiTrack)
        XCTAssertTrue(args[0].contains("-disposition:s"))
        XCTAssertFalse(args[0].contains(where: { $0.hasPrefix("-disposition:s:") }))
    }

    func testSubtitleDefaultNoneClearsAll() {
        var s = ConversionSettings(container: .mkv, videoCodec: .copy, audioCodec: .copy, crf: 20)
        s.preserveAllStreams = true
        s.subtitleDefault = .none
        let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mkv",
                                         source: multiTrack)
        XCTAssertEqual(pairs(args[0]).filter { $0[0].hasPrefix("-disposition:s") },
                       [["-disposition:s", "-default"]])
    }

    func testSubtitleDefaultMatchesBibliographicAndTerminologyCodes() {
        // ISO 639-2 gives German two codes (ger/deu) and French two (fre/fra); MP4 and many
        // encoders write the terminology form while the picker offers the bibliographic one.
        let source = MediaInfo(durationSeconds: 10, videoCodecName: "hevc", audioCodecName: "aac",
                               subtitleLanguages: ["DEU", "eng", "fra"])
        func indexFlagged(for code: String) -> [String]? {
            var s = ConversionSettings(container: .mkv, videoCodec: .copy, audioCodec: .copy, crf: 20)
            s.preserveAllStreams = true
            s.subtitleDefault = .language(code)
            let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mkv", source: source)[0]
            return pairs(args).first { $0[0].hasPrefix("-disposition:s:") }
        }
        XCTAssertEqual(indexFlagged(for: "ger"), ["-disposition:s:0", "+default"])
        XCTAssertEqual(indexFlagged(for: "fre"), ["-disposition:s:2", "+default"])
        XCTAssertEqual(indexFlagged(for: "eng"), ["-disposition:s:1", "+default"])
        XCTAssertNil(indexFlagged(for: "spa"), "no track in that language: only the clearing runs")
    }

    func testCanonicalLanguageMapsTerminologyToBibliographicOnly() {
        XCTAssertEqual(SubtitleDefault.canonicalLanguage("deu"), "ger")
        XCTAssertEqual(SubtitleDefault.canonicalLanguage("FRA"), "fre")
        XCTAssertEqual(SubtitleDefault.canonicalLanguage("zho"), "chi")
        XCTAssertEqual(SubtitleDefault.canonicalLanguage("ger"), "ger")
        // Most languages have a single code and must pass through (lowercased).
        XCTAssertEqual(SubtitleDefault.canonicalLanguage("ENG"), "eng")
        XCTAssertEqual(SubtitleDefault.canonicalLanguage("jpn"), "jpn")
    }

    func testCanonicalLanguageCoversEveryBibliographicTerminologyPair() {
        // The 20 ISO 639-2 languages that have two codes (Library of Congress table), written
        // out independently of the implementation's own dictionary.
        let pairs: [(bibliographic: String, terminology: String)] = [
            ("alb", "sqi"), ("arm", "hye"), ("baq", "eus"), ("bur", "mya"), ("chi", "zho"),
            ("cze", "ces"), ("dut", "nld"), ("fre", "fra"), ("geo", "kat"), ("ger", "deu"),
            ("gre", "ell"), ("ice", "isl"), ("mac", "mkd"), ("mao", "mri"), ("may", "msa"),
            ("per", "fas"), ("rum", "ron"), ("slo", "slk"), ("tib", "bod"), ("wel", "cym"),
        ]
        XCTAssertEqual(pairs.count, 20)
        for (b, t) in pairs {
            XCTAssertEqual(SubtitleDefault.canonicalLanguage(t), b, "\(t) -> \(b)")
            XCTAssertEqual(SubtitleDefault.canonicalLanguage(b), b, "\(b) stays")
            XCTAssertEqual(SubtitleDefault.canonicalLanguage(t.uppercased()), b, "case-insensitive")
        }
    }

    func testAudioBitrateIsLoweredToTheCeilingOfTheFilesRealLayout() {
        // "Same as source" leaves the layout to the file; libopus takes 256 kbps per channel.
        var s = ConversionSettings(container: .mkv, videoCodec: .none, audioCodec: .opus, crf: 20,
                                   audioBitrate: .kbps(512))
        func bitrate(_ args: [String]) -> String? { pairs(args).first { $0[0] == "-b:a" || $0[0] == "-b:a:0" }?[1] }
        func build(channels: Int?) -> [String] {
            let source = MediaInfo(durationSeconds: 10, audioCodecName: "aac", audioChannels: channels)
            return ArgumentBuilder.build(settings: s, input: "/in.m4a", output: "/out.mkv", source: source)[0]
        }
        XCTAssertEqual(bitrate(build(channels: 1)), "256k", "mono source")
        XCTAssertEqual(bitrate(build(channels: 2)), "512k", "stereo source: unchanged")
        XCTAssertEqual(bitrate(build(channels: 6)), "512k", "never raised")
        XCTAssertEqual(bitrate(build(channels: nil)), "512k", "unknown count assumes stereo")
        // An explicit layout wins over the source's count.
        s.channels = .mono
        XCTAssertEqual(bitrate(build(channels: 6)), "256k")
        // The same applies when every stream is kept (the audio options are stream-qualified).
        s.channels = .source
        s.preserveAllStreams = true
        s.container = .mkv
        s.videoCodec = .copy
        XCTAssertEqual(bitrate(build(channels: 1)), "256k")
        // Auto adds no `-b:a` at all.
        s.audioBitrate = .auto
        XCTAssertNil(bitrate(build(channels: 1)))
    }

    func testBitrateCeilingUsesTheAudioStreamThatIsActuallyEncoded() {
        // Several audio streams: with nothing mapped ffmpeg encodes the one it selects (default
        // flag, else most channels); with every stream kept, `-c:a:0` encodes the first.
        var s = ConversionSettings(container: .mkv, videoCodec: .none, audioCodec: .opus, crf: 20,
                                   audioBitrate: .kbps(512))
        func bitrate() -> String? {
            // A mono first track and a 5.1 selected one.
            let source = MediaInfo(durationSeconds: 10, audioCodecName: "aac", audioChannels: 6, firstAudioChannels: 1)
            let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mkv", source: source)[0]
            return pairs(args).first { $0[0] == "-b:a" || $0[0] == "-b:a:0" }?[1]
        }
        XCTAssertEqual(bitrate(), "512k", "ffmpeg encodes the 5.1 stream, which takes 512")
        s.preserveAllStreams = true
        XCTAssertEqual(bitrate(), "256k", "every stream kept: -c:a:0 encodes the mono first stream")
    }

    func testTwoPassMapsVideoInPassOneOnlyWhenKeepingAllStreams() {
        // Each encoder opens its stats file by output index, so pass 1 has to map the video
        // like pass 2 does or a source with several real video streams has no log for the rest.
        var s = ConversionSettings(container: .mkv, videoCodec: .h264, audioCodec: .aac, crf: 20)
        s.rateControl = .bitrate
        s.videoBitrateKbps = 2500
        let off = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mkv",
                                        source: multiTrack, passLog: "/tmp/log")
        XCTAssertFalse(off[0].contains("-map"), "default behaviour stays byte-identical")
        s.preserveAllStreams = true
        let on = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mkv",
                                       source: multiTrack, passLog: "/tmp/log")
        XCTAssertEqual(maps(on[0]), ["0:V?"])
        XCTAssertEqual(maps(on[0]).first, maps(on[1]).first, "both passes map the video the same way")
    }

    func testPreserveAllStreamsDropsSubsForAudioOnlyContainer() {
        var s = ConversionSettings(container: .m4a, videoCodec: .none, audioCodec: .alac, crf: 20)
        s.preserveAllStreams = true
        s.subtitleDefault = .language("eng")
        let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.m4a",
                                         source: multiTrack)
        XCTAssertEqual(maps(args[0]), ["0:a"], "subtitles are never mapped into an audio-only file")
        XCTAssertFalse(args[0].contains("-c:s"))
        XCTAssertFalse(args[0].contains("-disposition:s"))
    }

    func testSurround71EmitsAc8() {
        var s = ConversionSettings(container: .mkv, videoCodec: .copy, audioCodec: .flac, crf: 20)
        s.channels = .surround71
        let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mkv",
                                         source: multiTrack)
        XCTAssertEqual(args[0].suffix(3), ["-ac", "8", "/out.mkv"])
    }

    func testH264SoftwareToMP4() {
        let s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 23)
        let args = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4", source: src)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y", "-i", "/in.mov",
            "-c:v", "libx264", "-preset", "slow", "-crf", "23", "-pix_fmt", "yuv420p", "-profile:v", "high",
            "-c:a", "aac",
            "-movflags", "+faststart", "/out.mp4"
        ]])
    }

    func testAV1SoftwarePresetMapsToNumber() {
        let s = ConversionSettings(container: .mp4, videoCodec: .av1, audioCodec: .aac, crf: 30, preset: .slow)
        let args = ArgumentBuilder.build(settings: s, input: "/in.mp4", output: "/out.mp4", source: src)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y", "-i", "/in.mp4",
            "-c:v", "libsvtav1", "-preset", "4", "-crf", "30",
            "-c:a", "aac",
            "-movflags", "+faststart", "/out.mp4"
        ]])
    }

    func testH265SoftwareUsesNamedPreset() {
        let s = ConversionSettings(container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 28, preset: .veryslow)
        let args = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4", source: src)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y", "-i", "/in.mov",
            "-c:v", "libx265", "-preset", "veryslow", "-crf", "28", "-pix_fmt", "yuv420p", "-tag:v", "hvc1",
            "-c:a", "aac",
            "-movflags", "+faststart", "/out.mp4"
        ]])
    }

    func testHEVCHardwareWithBitrateAndChannels() {
        let s = ConversionSettings(container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 28,
                                   channels: .stereo, audioBitrate: .kbps(192), useHardware: true)
        let args = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4", source: src)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y", "-i", "/in.mov",
            "-c:v", "hevc_videotoolbox", "-q:v", "44", "-pix_fmt", "yuv420p", "-tag:v", "hvc1",
            "-c:a", "aac", "-b:a", "192k", "-ac", "2",
            "-movflags", "+faststart", "/out.mp4"
        ]])
    }

    func testCopyHEVCKeepsHvc1Tag_ALACNoBitrate() {
        let s = ConversionSettings(container: .mov, videoCodec: .copy, audioCodec: .alac, crf: 23)
        let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mov", source: src)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y", "-i", "/in.mkv",
            "-c:v", "copy", "-tag:v", "hvc1",
            "-c:a", "alac",
            "-movflags", "+faststart", "/out.mov"
        ]])
    }

    func testAudioOnlyM4A_DropVideo() {
        let s = ConversionSettings(container: .m4a, videoCodec: .none, audioCodec: .aac, crf: 23)
        let args = ArgumentBuilder.build(settings: s, input: "/in.mp4", output: "/out.m4a", source: src)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y", "-i", "/in.mp4",
            "-vn",
            "-c:a", "aac",
            "-movflags", "+faststart", "/out.m4a"
        ]])
    }

    func testVP9WebM_NoFaststartNoPixFmt() {
        let s = ConversionSettings(container: .webm, videoCodec: .vp9, audioCodec: .opus, crf: 31)
        let args = ArgumentBuilder.build(settings: s, input: "/in.mp4", output: "/out.webm", source: src)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y", "-i", "/in.mp4",
            "-c:v", "libvpx-vp9", "-crf", "31", "-b:v", "0",
            "-c:a", "libopus", "/out.webm"
        ]])
    }

    func testGIF_MinimalArgs_NoCodecNoAudio() {
        // GIF: ffmpeg's gif muxer auto-selects the encoder; audio must be stripped.
        let s = ConversionSettings(container: .gif, videoCodec: .h264, audioCodec: .aac, crf: 23)
        let args = ArgumentBuilder.build(settings: s, input: "/in.mp4", output: "/out.gif", source: src)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y", "-i", "/in.mp4", "-an", "/out.gif"
        ]])
    }

    func testProResToMOV_ProfileNotCRF() {
        let s = ConversionSettings(container: .mov, videoCodec: .prores, audioCodec: .aac, crf: 20, proResProfile: .standard)
        let args = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mov", source: src)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y", "-i", "/in.mov",
            "-c:v", "prores_ks", "-profile:v", "2",
            "-c:a", "aac",
            "-movflags", "+faststart", "/out.mov"
        ]])
    }

    func testProResHardwareToMKV() {
        let s = ConversionSettings(container: .mkv, videoCodec: .prores, audioCodec: .none, crf: 20, useHardware: true, proResProfile: .hq)
        let args = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mkv", source: src)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y", "-i", "/in.mov",
            "-c:v", "prores_videotoolbox", "-profile:v", "3",
            "-an", "/out.mkv"
        ]])
    }

    func testFLACAudioOnly_NoBitrate() {
        let s = ConversionSettings(container: .flac, videoCodec: .none, audioCodec: .flac, crf: 20)
        let args = ArgumentBuilder.build(settings: s, input: "/in.wav", output: "/out.flac", source: src)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y", "-i", "/in.wav",
            "-vn",
            "-c:a", "flac",
            "/out.flac"
        ]])
    }

    func testWAVPCMAudioOnly() {
        let s = ConversionSettings(container: .wav, videoCodec: .none, audioCodec: .pcm, crf: 20)
        let args = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.wav", source: src)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y", "-i", "/in.mov",
            "-vn",
            "-c:a", "pcm_s16le",
            "/out.wav"
        ]])
    }

    func testAC3WithBitrateAndChannels() {
        let s = ConversionSettings(container: .mkv, videoCodec: .copy, audioCodec: .ac3, crf: 20,
                                   channels: .surround51, audioBitrate: .kbps(448))
        let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mkv", source: src)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y", "-i", "/in.mkv",
            "-c:v", "copy",
            "-c:a", "ac3", "-b:a", "448k", "-ac", "6",
            "/out.mkv"
        ]])
    }

    func testBitrateSoftwareTwoPass() {
        var s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20)
        s.rateControl = .bitrate
        s.videoBitrateKbps = 2500
        let cmds = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4",
                                         source: src, passLog: "/tmp/p")
        XCTAssertEqual(cmds, [
            ["-hide_banner", "-y", "-i", "/in.mov",
             "-c:v", "libx264", "-preset", "slow", "-b:v", "2500k", "-pix_fmt", "yuv420p", "-profile:v", "high",
             "-pass", "1", "-passlogfile", "/tmp/p", "-an", "-f", "null", "/dev/null"],
            ["-hide_banner", "-y", "-i", "/in.mov",
             "-c:v", "libx264", "-preset", "slow", "-b:v", "2500k", "-pix_fmt", "yuv420p", "-profile:v", "high",
             "-pass", "2", "-passlogfile", "/tmp/p",
             "-c:a", "aac",
             "-movflags", "+faststart", "/out.mp4"],
        ])
    }

    func testBitrateSoftwareSinglePass() {
        var s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20)
        s.rateControl = .bitrate
        s.videoBitrateKbps = 2500
        s.twoPass = false
        let cmds = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4", source: src)
        XCTAssertEqual(cmds, [[
            "-hide_banner", "-y", "-i", "/in.mov",
            "-c:v", "libx264", "-preset", "slow", "-b:v", "2500k", "-pix_fmt", "yuv420p", "-profile:v", "high",
            "-c:a", "aac",
            "-movflags", "+faststart", "/out.mp4"
        ]])
    }

    func testBitrateHardwareIsSinglePassWithBitrate() {
        var s = ConversionSettings(container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 25,
                                   useHardware: true)
        s.rateControl = .bitrate
        s.videoBitrateKbps = 3000
        let cmds = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4", source: src)
        XCTAssertEqual(cmds, [[
            "-hide_banner", "-y", "-i", "/in.mov",
            "-c:v", "hevc_videotoolbox", "-b:v", "3000k", "-pix_fmt", "yuv420p", "-tag:v", "hvc1",
            "-c:a", "aac",
            "-movflags", "+faststart", "/out.mp4"
        ]])
    }

    // MARK: - HDR tone mapping

    let hdrSrc = MediaInfo(durationSeconds: 10, videoCodecName: "hevc", audioCodecName: "aac",
                           colorTransfer: "smpte2084")

    func testToneMapOffIsByteIdentical() {
        // Regression guard: with the toggle off nothing about the command changes,
        // even for an HDR source — tone mapping is opt-in per settings, not per file.
        let s = ConversionSettings(container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 25,
                                   useHardware: true)
        let args = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4", source: hdrSrc)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y", "-i", "/in.mov",
            "-c:v", "hevc_videotoolbox", "-q:v", "50", "-pix_fmt", "yuv420p", "-tag:v", "hvc1",
            "-c:a", "aac",
            "-movflags", "+faststart", "/out.mp4"
        ]])
    }

    func testToneMapUsesHardwareDecodeOnlyWhereASoftwareFallbackExists() {
        var s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20)
        s.toneMapHDR = true
        func args(for codec: String) -> [String] {
            let source = MediaInfo(durationSeconds: 10, videoCodecName: codec, audioCodecName: "aac",
                                   colorTransfer: "smpte2084")
            return ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4", source: source)[0]
        }
        // Cuts wall time and CPU by a quarter to a half with a software encoder.
        for codec in ["hevc", "h264"] {
            XCTAssertTrue(pairs(args(for: codec)).contains(["-hwaccel", "videotoolbox"]), codec)
        }
        // `-hwaccel` makes ffmpeg pick its hardware-only AV1 decoder, which fails outright
        // on Macs without AV1 decode hardware instead of falling back to libdav1d.
        for codec in ["av1", "vp9", "prores", "mpeg2video"] {
            XCTAssertFalse(args(for: codec).contains("-hwaccel"), codec)
            XCTAssertTrue(args(for: codec).contains("-init_hw_device"), "\(codec) still needs the device for scale_vt")
        }
    }

    func testToneMapKeepsHvc1TagAndFaststartForHEVCInMP4() {
        // Without `hvc1` HEVC in MP4 is tagged `hev1`, which QuickTime and iOS will not play.
        for hardware in [false, true] {
            var s = ConversionSettings(container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 25,
                                       useHardware: hardware)
            s.toneMapHDR = true
            let args = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4", source: hdrSrc)[0]
            XCTAssertTrue(pairs(args).contains(["-tag:v", "hvc1"]), "hardware=\(hardware)")
            XCTAssertTrue(pairs(args).contains(["-movflags", "+faststart"]), "hardware=\(hardware)")
        }
    }

    func testToneMapSoftwareEncodeKeepsPixFmtAndProfile() {
        var s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20)
        s.toneMapHDR = true
        let args = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4", source: hdrSrc)[0]
        XCTAssertTrue(args.contains("-init_hw_device"))
        XCTAssertTrue(args.contains("-vf"))
        // The existing 8-bit + High-profile handling must survive the filter insertion.
        XCTAssertTrue(args.contains("yuv420p"))
        XCTAssertTrue(args.contains("high"))
        XCTAssertTrue(args.contains("-color_trc"))
    }

    func testToneMapTwoPassAppliesFilterToBothPasses() {
        var s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20)
        s.toneMapHDR = true
        s.rateControl = .bitrate
        s.videoBitrateKbps = 2500
        let cmds = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4",
                                         source: hdrSrc, passLog: "/tmp/log")
        XCTAssertEqual(cmds.count, 2)
        for pass in cmds {
            XCTAssertTrue(pass.contains("-init_hw_device"))
            XCTAssertTrue(pass.contains("-vf"))
        }
    }

    func testToneMapSkippedForSDRSource() {
        // The toggle covers the whole batch: an SDR file must get exactly the command
        // it gets with the toggle off, not the HDR graph.
        let sdr = MediaInfo(durationSeconds: 10, videoCodecName: "h264", audioCodecName: "aac",
                            colorTransfer: "bt709")
        let off = ConversionSettings(container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 25,
                                     useHardware: true)
        var on = off
        on.toneMapHDR = true
        for source in [sdr, MediaInfo(durationSeconds: 10, videoCodecName: "h264", audioCodecName: "aac")] {
            XCTAssertEqual(
                ArgumentBuilder.build(settings: on, input: "/in.mov", output: "/out.mp4", source: source),
                ArgumentBuilder.build(settings: off, input: "/in.mov", output: "/out.mp4", source: source))
        }
    }

    func testToneMapIgnoredForCopyAndNone() {
        for codec in [VideoCodec.copy, .none] {
            var s = ConversionSettings(container: .mkv, videoCodec: codec, audioCodec: .aac, crf: 20)
            s.toneMapHDR = true
            let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mkv", source: hdrSrc)[0]
            XCTAssertFalse(args.contains("-init_hw_device"), "\(codec) has no encoder to tone map into")
            XCTAssertFalse(args.contains("-vf"))
            XCTAssertFalse(args.contains("-color_trc"))
        }
    }

    func testToneMapIgnoredForGIF() {
        var s = ConversionSettings(container: .gif, videoCodec: .h264, audioCodec: .none, crf: 20)
        s.toneMapHDR = true
        let args = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.gif", source: hdrSrc)
        XCTAssertEqual(args, [["-hide_banner", "-y", "-i", "/in.mov", "-an", "/out.gif"]])
    }
}
