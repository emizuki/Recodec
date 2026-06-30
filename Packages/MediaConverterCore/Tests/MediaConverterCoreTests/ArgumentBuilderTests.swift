import XCTest
@testable import MediaConverterCore

final class ArgumentBuilderTests: XCTestCase {
    let src = MediaInfo(durationSeconds: 10, videoCodecName: "hevc", audioCodecName: "aac")

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
}
