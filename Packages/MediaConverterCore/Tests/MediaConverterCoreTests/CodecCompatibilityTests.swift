import XCTest
@testable import MediaConverterCore

final class CodecCompatibilityTests: XCTestCase {

    // MARK: - isValidCombo: valid combos

    func testHevcAACInMP4IsValid() {
        let s = ConversionSettings(container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 28)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s))
    }

    func testVP9OpusInWebMIsValid() {
        let s = ConversionSettings(container: .webm, videoCodec: .vp9, audioCodec: .opus, crf: 31)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s))
    }

    func testAV1OpusInMKVIsValid() {
        let s = ConversionSettings(container: .mkv, videoCodec: .av1, audioCodec: .opus, crf: 30)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s))
    }

    func testCopyNoneInMP4IsValid() {
        let s = ConversionSettings(container: .mp4, videoCodec: .copy, audioCodec: .none, crf: 23)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s))
    }

    func testM4AValidWithAACAndVideoNone() {
        let s = ConversionSettings(container: .m4a, videoCodec: .none, audioCodec: .aac, crf: 23)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s))
    }

    func testMP3ValidWithMP3AndVideoNone() {
        let s = ConversionSettings(container: .mp3, videoCodec: .none, audioCodec: .mp3, crf: 23)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s))
    }

    // MARK: - isValidCombo: invalid combos

    func testH264InWebMIsInvalid() {
        let s = ConversionSettings(container: .webm, videoCodec: .h264, audioCodec: .opus, crf: 23)
        XCTAssertFalse(CodecCompatibility.isValidCombo(s))
    }

    func testVP9InMP4IsInvalid() {
        let s = ConversionSettings(container: .mp4, videoCodec: .vp9, audioCodec: .aac, crf: 31)
        XCTAssertFalse(CodecCompatibility.isValidCombo(s))
    }

    func testOpusInMP4IsInvalid() {
        let s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .opus, crf: 23)
        XCTAssertFalse(CodecCompatibility.isValidCombo(s))
    }

    func testM4AWithVideoH264IsInvalid() {
        let s = ConversionSettings(container: .m4a, videoCodec: .h264, audioCodec: .aac, crf: 23)
        XCTAssertFalse(CodecCompatibility.isValidCombo(s))
    }

    func testOpusInMOVIsInvalid() {
        let s = ConversionSettings(container: .mov, videoCodec: .h264, audioCodec: .opus, crf: 23)
        XCTAssertFalse(CodecCompatibility.isValidCombo(s))
    }

    // MARK: - GIF is always valid

    func testGIFIsAlwaysValidRegardlessOfCodecs() {
        let s1 = ConversionSettings(container: .gif, videoCodec: .h264, audioCodec: .aac, crf: 23)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s1), "gif should be valid even with incompatible codecs")

        let s2 = ConversionSettings(container: .gif, videoCodec: .none, audioCodec: .none, crf: 23)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s2))
    }

    // MARK: - videoCodecs / audioCodecs lists

    func testVideoCodecsForWebMExcludesH264() {
        let codecs = CodecCompatibility.videoCodecs(for: .webm)
        XCTAssertTrue(codecs.contains(.vp9))
        XCTAssertTrue(codecs.contains(.av1))
        XCTAssertFalse(codecs.contains(.h264))
        XCTAssertFalse(codecs.contains(.hevc))
    }

    func testAudioCodecsForWebMExcludesAAC() {
        let codecs = CodecCompatibility.audioCodecs(for: .webm)
        XCTAssertTrue(codecs.contains(.opus))
        XCTAssertFalse(codecs.contains(.aac))
        XCTAssertFalse(codecs.contains(.alac))
    }

    func testVideoCodecsForGIFIsNoneOnly() {
        XCTAssertEqual(CodecCompatibility.videoCodecs(for: .gif), [.none])
    }

    func testAudioCodecsForGIFIsNoneOnly() {
        XCTAssertEqual(CodecCompatibility.audioCodecs(for: .gif), [.none])
    }

    func testMKVIncludesOpusAudio() {
        XCTAssertTrue(CodecCompatibility.audioCodecs(for: .mkv).contains(.opus))
    }

    func testMP4IncludesAV1Video() {
        XCTAssertTrue(CodecCompatibility.videoCodecs(for: .mp4).contains(.av1))
    }
}
