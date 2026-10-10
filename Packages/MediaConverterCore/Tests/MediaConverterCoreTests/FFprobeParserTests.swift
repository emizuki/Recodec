import XCTest
@testable import MediaConverterCore

final class FFprobeParserTests: XCTestCase {
    func testParsesDurationAndCodecs() throws {
        let json = """
        {"streams":[{"codec_type":"video","codec_name":"h264"},
                    {"codec_type":"audio","codec_name":"aac"}],
         "format":{"duration":"12.500000"}}
        """.data(using: .utf8)!
        let info = try FFprobeParser.parse(json)
        XCTAssertEqual(info.durationSeconds, 12.5)
        XCTAssertEqual(info.videoCodecName, "h264")
        XCTAssertEqual(info.audioCodecName, "aac")
    }

    func testAudioOnly() throws {
        let json = """
        {"streams":[{"codec_type":"audio","codec_name":"mp3"}],"format":{"duration":"3.0"}}
        """.data(using: .utf8)!
        let info = try FFprobeParser.parse(json)
        XCTAssertNil(info.videoCodecName)
        XCTAssertEqual(info.audioCodecName, "mp3")
        XCTAssertNil(info.colorTransfer)
        XCTAssertFalse(info.isHDR)
    }

    func testParsesColorTransferAndFlagsHDR() throws {
        // Shape of a macOS Screenshots-app HDR recording / iPhone Dolby Vision clip.
        let pq = """
        {"streams":[{"codec_type":"video","codec_name":"hevc","pix_fmt":"yuv420p10le",
                     "color_transfer":"smpte2084","color_primaries":"bt2020","color_space":"bt2020nc"},
                    {"codec_type":"audio","codec_name":"aac"}],
         "format":{"duration":"15.6"}}
        """.data(using: .utf8)!
        let info = try FFprobeParser.parse(pq)
        XCTAssertEqual(info.colorTransfer, "smpte2084")
        XCTAssertTrue(info.isHDR)

        let hlg = """
        {"streams":[{"codec_type":"video","codec_name":"hevc","color_transfer":"arib-std-b67"}]}
        """.data(using: .utf8)!
        XCTAssertTrue(try FFprobeParser.parse(hlg).isHDR)

        let sdr = """
        {"streams":[{"codec_type":"video","codec_name":"h264","color_transfer":"bt709"}]}
        """.data(using: .utf8)!
        let sdrInfo = try FFprobeParser.parse(sdr)
        XCTAssertEqual(sdrInfo.colorTransfer, "bt709")
        XCTAssertFalse(sdrInfo.isHDR)
    }

    func testUntaggedVideoIsNotHDR() throws {
        let json = """
        {"streams":[{"codec_type":"video","codec_name":"h264"}]}
        """.data(using: .utf8)!
        let info = try FFprobeParser.parse(json)
        XCTAssertNil(info.colorTransfer)
        XCTAssertFalse(info.isHDR)
    }
}
