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

    func testPreserveAllStreamsMapsEverythingAndCopiesSubs() {
        var s = ConversionSettings(container: .mkv, videoCodec: .copy, audioCodec: .eac3,
                                   crf: 20, channels: .surround51, audioBitrate: .kbps(1536))
        s.preserveAllStreams = true
        let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mkv",
                                         source: multiTrack)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y", "-i", "/in.mkv",
            "-c:v", "copy",
            "-c:a", "copy", "-c:a:0", "eac3", "-b:a:0", "1536k", "-ac:a:0", "6",
            "-map", "0", "-c:s", "copy",
            "/out.mkv"
        ]])
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
        XCTAssertEqual(args[0].suffix(7),
                       ["-map", "0", "-c:s", "copy",
                        "-disposition:s", "0", "-disposition:s:1", "default", "/out.mkv"].suffix(7))
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
        XCTAssertEqual(args[0].suffix(3), ["-disposition:s", "0", "/out.mkv"])
    }

    func testPreserveAllStreamsDropsSubsForAudioOnlyContainer() {
        var s = ConversionSettings(container: .m4a, videoCodec: .none, audioCodec: .alac, crf: 20)
        s.preserveAllStreams = true
        s.subtitleDefault = .language("eng")
        let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.m4a",
                                         source: multiTrack)
        XCTAssertTrue(args[0].contains("-sn"))
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

    func testToneMapHardwareEncode() {
        var s = ConversionSettings(container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 25,
                                   useHardware: true)
        s.toneMapHDR = true
        let args = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4", source: hdrSrc)
        XCTAssertEqual(args, [[
            "-hide_banner", "-y",
            "-init_hw_device", "videotoolbox=vt", "-filter_hw_device", "vt",
            "-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld",
            "-i", "/in.mov",
            "-c:v", "hevc_videotoolbox", "-q:v", "50", "-pix_fmt", "yuv420p",
            "-vf", "hwupload,scale_vt=color_matrix=bt709:color_primaries=bt709:color_transfer=bt709,"
                + "hwdownload,format=p010le,"
                + "sidedata=mode=delete:type=MASTERING_DISPLAY_METADATA,"
                + "sidedata=mode=delete:type=CONTENT_LIGHT_LEVEL",
            "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
            "-tag:v", "hvc1",
            "-c:a", "aac",
            "-movflags", "+faststart", "/out.mp4"
        ]])
    }

    func testToneMapSoftwareEncodeKeepsPixFmtAndProfile() {
        var s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20)
        s.toneMapHDR = true
        let args = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4", source: hdrSrc)[0]
        XCTAssertTrue(args.contains("-hwaccel"), "software encoders still decode via VideoToolbox")
        XCTAssertEqual(args.firstIndex(of: "-vf").map { args[$0 + 1].hasPrefix("hwupload,scale_vt=") }, true)
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
            XCTAssertTrue(pass.contains("-hwaccel"))
            XCTAssertTrue(pass.contains("-vf"))
        }
    }

    func testToneMapIgnoredForCopyAndNone() {
        for codec in [VideoCodec.copy, .none] {
            var s = ConversionSettings(container: .mkv, videoCodec: codec, audioCodec: .aac, crf: 20)
            s.toneMapHDR = true
            let args = ArgumentBuilder.build(settings: s, input: "/in.mkv", output: "/out.mkv", source: hdrSrc)[0]
            XCTAssertFalse(args.contains("-hwaccel"), "\(codec) has no encoder to tone map into")
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
