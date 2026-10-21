import XCTest
@testable import MediaConverterCore

final class ProgressParserTests: XCTestCase {
    func testFractionFromOutTime() {
        var p = ProgressParser(durationSeconds: 2.0)
        p.consume("frame=10\nout_time_us=1000000\nprogress=continue\n")
        XCTAssertEqual(p.fraction, 0.5, accuracy: 0.001)
        XCTAssertFalse(p.isFinished)
    }
    /// Measured on ffmpeg 9.0.2 (x265 slow, audio copied): out_time_us jumped to the audio's end,
    /// held, then fell back to the video's position before finishing.
    func testFractionNeverMovesBackwards() {
        var p = ProgressParser(durationSeconds: 55.887574)
        var seen: [Double] = []
        for us in [53_894_921, 55_772_880, 55_772_880, 54_100_000, 54_366_667, 55_772_880] {
            p.consume("out_time_us=\(us)\nprogress=continue\n")
            seen.append(p.fraction)
        }
        XCTAssertEqual(seen, seen.sorted())
        XCTAssertEqual(seen[3], seen[2], "the dip to the video's position is ignored")
    }
    func testEndSetsFinished() {
        var p = ProgressParser(durationSeconds: 2.0)
        p.consume("out_time_us=2000000\nprogress=end\n")
        XCTAssertEqual(p.fraction, 1.0, accuracy: 0.001)
        XCTAssertTrue(p.isFinished)
    }
    func testUnknownDurationStaysZero() {
        var p = ProgressParser(durationSeconds: nil)
        p.consume("out_time_us=1000000\nprogress=continue\n")
        XCTAssertEqual(p.fraction, 0.0)
    }
    func testKeySplitAcrossChunksIsReassembled() {
        var p = ProgressParser(durationSeconds: 1.0)
        p.consume("out_time_u")
        XCTAssertEqual(p.fraction, 0.0, "an incomplete line must not be parsed")
        p.consume("s=1000000\n")
        XCTAssertEqual(p.fraction, 1.0, accuracy: 0.001)
    }
    func testValueSplitAcrossChunksIsNotTruncated() {
        var p = ProgressParser(durationSeconds: 1.0)
        p.consume("out_time_us=10")
        p.consume("00000\n")
        XCTAssertEqual(p.fraction, 1.0, accuracy: 0.001)
    }
    func testCarriageReturnLineEndingsAreAccepted() {
        var p = ProgressParser(durationSeconds: 1.0)
        p.consume("out_time_us=1000000\r\nprogress=end\r\n")
        XCTAssertEqual(p.fraction, 1.0, accuracy: 0.001)
        XCTAssertTrue(p.isFinished)
    }
    func testProgressEndSplitAcrossChunks() {
        var p = ProgressParser(durationSeconds: 1.0)
        p.consume("progress=en")
        XCTAssertFalse(p.isFinished)
        p.consume("d\n")
        XCTAssertTrue(p.isFinished)
        XCTAssertEqual(p.fraction, 1.0, accuracy: 0.001)
    }
    func testCarriageReturnSplitAcrossChunks() {
        var p = ProgressParser(durationSeconds: 1.0)
        p.consume("out_time_us=1000000\r")
        p.consume("\nprogress=end\r\n")
        XCTAssertEqual(p.fraction, 1.0, accuracy: 0.001)
        XCTAssertTrue(p.isFinished)
    }
}
