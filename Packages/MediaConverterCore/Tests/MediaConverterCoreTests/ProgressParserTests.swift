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
}
