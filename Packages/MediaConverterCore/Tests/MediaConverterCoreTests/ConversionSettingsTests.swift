import XCTest
@testable import MediaConverterCore

final class ConversionSettingsTests: XCTestCase {
    func testEncoderNames() {
        XCTAssertEqual(VideoCodec.h264.softwareEncoder, "libx264")
        XCTAssertEqual(VideoCodec.hevc.hardwareEncoder, "hevc_videotoolbox")
        XCTAssertNil(VideoCodec.copy.softwareEncoder)            // copy maps to "copy"? No — see Step 4
        XCTAssertEqual(AudioCodec.mp3.encoder, "libmp3lame")
        XCTAssertNil(AudioCodec.none.encoder)
    }

    func testCanonicalAndFlags() {
        XCTAssertEqual(VideoCodec.hevc.canonicalName, "hevc")
        XCTAssertTrue(VideoCodec.h264.isIPhoneReady)
        XCTAssertFalse(VideoCodec.av1.isIPhoneReady)
        XCTAssertTrue(AudioCodec.alac.isIPhoneReady)
        XCTAssertFalse(AudioCodec.alac.supportsBitrate)
        XCTAssertTrue(AudioCodec.aac.supportsBitrate)
        XCTAssertEqual(AudioChannels.surround51.count, 6)
        XCTAssertNil(AudioChannels.source.count)
        XCTAssertEqual(AudioBitrate.kbps(192).ffmpegArgument, "192k")
        XCTAssertNil(AudioBitrate.auto.ffmpegArgument)
    }

    func testIPhoneDefault() {
        let s = ConversionSettings.iPhoneDefault
        XCTAssertEqual(s.container, .mp4)
        XCTAssertEqual(s.videoCodec, .hevc)
        XCTAssertEqual(s.audioCodec, .aac)
        XCTAssertEqual(s.preset, .slow)
        XCTAssertEqual(s.crf, 25)
    }

    func testQualityMatchedDefaultCRF() {
        XCTAssertEqual(VideoCodec.h264.defaultCRF, 20)
        XCTAssertEqual(VideoCodec.hevc.defaultCRF, 25)
        XCTAssertEqual(VideoCodec.av1.defaultCRF, 28)
        XCTAssertEqual(VideoCodec.vp9.defaultCRF, 28)
    }

    func testDefaultsAreSlowAndCRF25() {
        let s = ConversionSettings.iPhoneDefault
        XCTAssertEqual(s.crf, 25)
        XCTAssertEqual(s.preset, .slow)
        // unspecified preset also defaults to slow
        XCTAssertEqual(ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20).preset, .slow)
    }

    func testEncoderPresetSVTAV1Mapping() {
        XCTAssertEqual(EncoderPreset.ultrafast.svtAV1Value, 13)
        XCTAssertEqual(EncoderPreset.superfast.svtAV1Value, 12)
        XCTAssertEqual(EncoderPreset.veryfast.svtAV1Value, 10)
        XCTAssertEqual(EncoderPreset.faster.svtAV1Value, 9)
        XCTAssertEqual(EncoderPreset.fast.svtAV1Value, 8)
        XCTAssertEqual(EncoderPreset.medium.svtAV1Value, 6)
        XCTAssertEqual(EncoderPreset.slow.svtAV1Value, 4)
        XCTAssertEqual(EncoderPreset.slower.svtAV1Value, 3)
        XCTAssertEqual(EncoderPreset.veryslow.svtAV1Value, 2)
    }

    func testVideoCodecSupportsPreset() {
        XCTAssertTrue(VideoCodec.h264.supportsPreset)
        XCTAssertTrue(VideoCodec.hevc.supportsPreset)
        XCTAssertTrue(VideoCodec.av1.supportsPreset)
        XCTAssertFalse(VideoCodec.vp9.supportsPreset)
        XCTAssertFalse(VideoCodec.copy.supportsPreset)
        XCTAssertFalse(VideoCodec.none.supportsPreset)
    }

    func testAudioBitratePresetsUpTo1536() {
        let kbps = AudioBitrate.presets.compactMap { if case .kbps(let k) = $0 { return k } else { return nil } }
        XCTAssertEqual(kbps, [96, 128, 160, 192, 256, 320, 384, 448, 512, 640, 768, 1024, 1536])
        XCTAssertEqual(AudioBitrate.presets.first, .auto)
    }

    func testStreamPreservationDefaultsOff() {
        let s = ConversionSettings(container: .mkv, videoCodec: .copy, audioCodec: .eac3, crf: 20)
        XCTAssertFalse(s.preserveAllStreams)
        XCTAssertEqual(s.subtitleDefault, .unchanged)
    }

    func testSurround71ChannelCount() {
        XCTAssertEqual(AudioChannels.surround71.count, 8)
        XCTAssertEqual(AudioChannels.surround51.count, 6)
        XCTAssertNil(AudioChannels.source.count)
    }

    func testContainerSubtitleSupport() {
        XCTAssertTrue(Container.mkv.supportsSubtitles)
        XCTAssertTrue(Container.mp4.supportsSubtitles)
        XCTAssertFalse(Container.m4a.supportsSubtitles)
        XCTAssertFalse(Container.gif.supportsSubtitles)
    }

    func testDefaultRateControlIsQuality() {
        let s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20)
        XCTAssertEqual(s.rateControl, .quality)
        XCTAssertEqual(s.videoBitrateKbps, 2000)
        XCTAssertTrue(s.twoPass)
        XCTAssertFalse(s.usesBitrate)
        XCTAssertFalse(s.effectiveTwoPass)
    }

    func testUsesBitrateOnlyForSoftwareEncodableCodecs() {
        var s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20)
        s.rateControl = .bitrate
        XCTAssertTrue(s.usesBitrate)
        s.videoCodec = .copy
        XCTAssertFalse(s.usesBitrate, "bitrate mode does not apply to copy")
        s.videoCodec = .prores
        XCTAssertFalse(s.usesBitrate, "bitrate mode does not apply to ProRes")
    }

    func testEffectiveTwoPassRequiresSoftwareAndToggle() {
        var s = ConversionSettings(container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 25)
        s.rateControl = .bitrate
        XCTAssertTrue(s.effectiveTwoPass, "bitrate + software + twoPass on")
        s.useHardware = true
        XCTAssertFalse(s.effectiveTwoPass, "VideoToolbox cannot 2-pass")
        s.useHardware = false
        s.twoPass = false
        XCTAssertFalse(s.effectiveTwoPass, "2-pass toggled off")
        s.twoPass = true
        s.rateControl = .quality
        XCTAssertFalse(s.effectiveTwoPass, "quality mode is never 2-pass")
    }

    func testEstimatedOutputBytes() {
        var s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20,
                                   audioBitrate: .kbps(128))
        s.rateControl = .bitrate
        s.videoBitrateKbps = 2000
        // (2000 + 128) kbps * 1000 / 8 * 60s = 15,960,000 bytes
        XCTAssertEqual(s.estimatedOutputBytes(durationSeconds: 60), 15_960_000)
        XCTAssertEqual(s.estimatedAudioKbps, 128)
    }

    func testEstimatedAudioKbpsDefaults() {
        var s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .none, crf: 20)
        XCTAssertEqual(s.estimatedAudioKbps, 0)
        s.audioCodec = .copy
        XCTAssertEqual(s.estimatedAudioKbps, 128)
        s.audioCodec = .aac            // lossy, auto bitrate
        XCTAssertEqual(s.estimatedAudioKbps, 128)
        s.audioCodec = .flac           // lossless, not modeled
        XCTAssertEqual(s.estimatedAudioKbps, 0)
    }
}
