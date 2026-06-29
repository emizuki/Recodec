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
    }
}
