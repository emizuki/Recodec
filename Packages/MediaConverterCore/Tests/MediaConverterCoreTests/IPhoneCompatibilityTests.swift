import XCTest
@testable import MediaConverterCore

final class IPhoneCompatibilityTests: XCTestCase {
    let anySource = MediaInfo(durationSeconds: 10, videoCodecName: "h264", audioCodecName: "aac")

    func make(_ c: Container, _ v: VideoCodec, _ a: AudioCodec) -> ConversionSettings {
        ConversionSettings(container: c, videoCodec: v, audioCodec: a, crf: 23)
    }

    func testCompatibleHEVCAAC() {
        XCTAssertTrue(IPhoneCompatibilityChecker.evaluate(make(.mp4, .hevc, .aac), source: anySource).isCompatible)
    }
    func testAV1NotCompatible() {
        let r = IPhoneCompatibilityChecker.evaluate(make(.mp4, .av1, .aac), source: anySource)
        XCTAssertFalse(r.isCompatible)
        XCTAssertEqual(r.reason, "AV1 video only plays on iPhone 15 Pro and newer")
    }
    func testOpusNotCompatible() {
        let r = IPhoneCompatibilityChecker.evaluate(make(.mp4, .hevc, .opus), source: anySource)
        XCTAssertFalse(r.isCompatible)
        XCTAssertEqual(r.reason, "Opus audio doesn't play on iPhone")
    }
    func testWebMContainerNotCompatible() {
        let r = IPhoneCompatibilityChecker.evaluate(make(.webm, .vp9, .opus), source: anySource)
        XCTAssertFalse(r.isCompatible)
        XCTAssertEqual(r.reason, "WEBM files don't play on iPhone")
    }
    func testCopyVideoResolvesAgainstSource() {
        let h264Source = MediaInfo(videoCodecName: "h264", audioCodecName: "aac")
        XCTAssertTrue(IPhoneCompatibilityChecker.evaluate(make(.mov, .copy, .copy), source: h264Source).isCompatible)
        let vp9Source = MediaInfo(videoCodecName: "vp9", audioCodecName: "aac")
        let r = IPhoneCompatibilityChecker.evaluate(make(.mov, .copy, .aac), source: vp9Source)
        XCTAssertFalse(r.isCompatible)
        XCTAssertEqual(r.reason, "The source video (vp9) isn't H.264 or HEVC")
    }

    /// Copy of a stream the source doesn't have copies nothing, so a silent screen recording
    /// or an audio-only file is not "not iPhone-ready" for lacking something to copy.
    func testCopyOfAMissingStreamIsNotAProblem() {
        let silent = MediaInfo(videoCodecName: "h264")
        XCTAssertTrue(IPhoneCompatibilityChecker.evaluate(make(.mp4, .copy, .copy), source: silent).isCompatible)
        let audioOnly = MediaInfo(audioCodecName: "aac")
        XCTAssertTrue(IPhoneCompatibilityChecker.evaluate(make(.mp4, .copy, .copy), source: audioOnly).isCompatible)
    }

    /// The flip side: a stream that is there and can't play still fails when copied.
    func testCopyOfAPresentIncompatibleAudioStreamStillFails() {
        let opusSource = MediaInfo(videoCodecName: "h264", audioCodecName: "opus")
        let r = IPhoneCompatibilityChecker.evaluate(make(.mp4, .copy, .copy), source: opusSource)
        XCTAssertFalse(r.isCompatible)
        XCTAssertEqual(r.reason, "The source audio (opus) isn't AAC, MP3, or ALAC")
    }
}
