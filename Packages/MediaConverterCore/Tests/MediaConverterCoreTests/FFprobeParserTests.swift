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

    /// HLG can be signalled only by an alternative-transfer SEI inside the bitstream. ffprobe's
    /// stream entry then still shows the container-level value (`bt2020-10`, `bt709`), and only the
    /// decoded frames say `arib-std-b67`.
    func testHDRSignalledOnlyInTheFramesIsDetected() throws {
        func probe(streamTransfer: String, frames: String) throws -> MediaInfo {
            try FFprobeParser.parse(Data("""
            {"streams":[{"index":0,"codec_type":"audio","codec_name":"aac"},
                        {"index":1,"codec_type":"video","codec_name":"hevc","color_transfer":"\(streamTransfer)"}],
             "frames":[\(frames)]}
            """.utf8))
        }
        let hlgFrame = #"{"stream_index":1,"media_type":"video","color_transfer":"arib-std-b67"}"#
        for streamTransfer in ["bt2020-10", "bt709"] {
            let info = try probe(streamTransfer: streamTransfer, frames: hlgFrame)
            XCTAssertTrue(info.isHDR, "stream says \(streamTransfer), the frame says HLG")
            XCTAssertEqual(info.colorTransfer, "arib-std-b67")
        }
        // A frame of another stream says nothing about the video.
        let otherStream = #"{"stream_index":0,"media_type":"audio","color_transfer":"arib-std-b67"}"#
        XCTAssertFalse(try probe(streamTransfer: "bt709", frames: otherStream).isHDR)
        // No frame was decoded (or it carries no tag): the stream-level value stands.
        XCTAssertEqual(try probe(streamTransfer: "smpte2084", frames: "").colorTransfer, "smpte2084")
        XCTAssertTrue(try probe(streamTransfer: "smpte2084", frames: #"{"stream_index":1,"media_type":"video"}"#).isHDR)
        XCTAssertFalse(try probe(streamTransfer: "bt709", frames: "").isHDR)
    }

    func testChannelCountFollowsTheAudioStreamFfmpegSelects() throws {
        // Rule measured on ffmpeg 9.0.2 (`map_auto_audio`): a stream flagged default wins, then the
        // most channels, then the first of equals. `firstAudioChannels` is the first stream.
        func probe(_ streams: [(channels: Int, isDefault: Bool)]) throws -> MediaInfo {
            let audio = streams.map {
                #"{"codec_type":"audio","codec_name":"pcm_s16le","channels":\#($0.channels),"disposition":{"default":\#($0.isDefault ? 1 : 0)}}"#
            }.joined(separator: ",")
            return try FFprobeParser.parse(Data(#"{"streams":[{"codec_type":"video","codec_name":"h264"},\#(audio)]}"#.utf8))
        }
        var info = try probe([(1, false), (2, false)])
        XCTAssertEqual(info.audioChannels, 2, "most channels")
        XCTAssertEqual(info.firstAudioChannels, 1)
        info = try probe([(2, false), (1, true)])
        XCTAssertEqual(info.audioChannels, 1, "the default flag outranks the channel count")
        XCTAssertEqual(info.firstAudioChannels, 2)
        info = try probe([(6, false), (2, true)])
        XCTAssertEqual(info.audioChannels, 2, "the default flag outranks even a 5.1 stream, not merely a tie")
        XCTAssertEqual(info.firstAudioChannels, 6)
        info = try probe([(2, true), (6, true)])
        XCTAssertEqual(info.audioChannels, 6, "both default: most channels")
        info = try probe([(2, false), (2, false)])
        XCTAssertEqual(info.audioChannels, 2)
        info = try probe([(6, false)])
        XCTAssertEqual(info.audioChannels, 6)
        XCTAssertEqual(info.firstAudioChannels, 6)
        let none = try FFprobeParser.parse(Data(#"{"streams":[{"codec_type":"video","codec_name":"h264"}]}"#.utf8))
        XCTAssertNil(none.audioChannels)
        XCTAssertNil(none.firstAudioChannels)
        // A stream without a disposition or channel count still parses.
        let sparse = try FFprobeParser.parse(Data(#"{"streams":[{"codec_type":"audio","codec_name":"aac"}]}"#.utf8))
        XCTAssertNil(sparse.audioChannels)
    }
}
