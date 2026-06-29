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
    }
}
