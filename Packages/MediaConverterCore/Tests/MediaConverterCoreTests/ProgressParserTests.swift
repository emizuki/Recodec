import XCTest
@testable import MediaConverterCore

final class ProgressParserTests: XCTestCase {
    func testFractionFromOutTime() {
        var p = ProgressParser(durationSeconds: 2.0)
        p.consume("frame=10\nout_time_us=1000000\nprogress=continue\n")
        XCTAssertEqual(p.fraction, 0.5, accuracy: 0.001)
        XCTAssertFalse(p.isFinished)
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
