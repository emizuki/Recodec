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
        XCTAssertEqual(s.preset, .medium)
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

    func testAudioBitratePresetsUpTo640() {
        let kbps = AudioBitrate.presets.compactMap { if case .kbps(let k) = $0 { return k } else { return nil } }
        XCTAssertEqual(kbps, [96, 128, 160, 192, 256, 320, 384, 448, 512, 640])
        XCTAssertEqual(AudioBitrate.presets.first, .auto)
    }
}
