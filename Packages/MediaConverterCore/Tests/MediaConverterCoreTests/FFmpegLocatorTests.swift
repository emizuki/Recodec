import XCTest
@testable import MediaConverterCore

final class FFmpegLocatorTests: XCTestCase {
    func testPicksFirstDirWithBothBinaries() {
        let present: Set<String> = ["/b/ffmpeg", "/b/ffprobe"]
        let tools = FFmpegLocator.locate(searchPaths: ["/a", "/b"], fileExists: { present.contains($0) })
        XCTAssertEqual(tools?.ffmpeg, "/b/ffmpeg")
        XCTAssertEqual(tools?.ffprobe, "/b/ffprobe")
    }
    func testNilWhenMissing() {
        XCTAssertNil(FFmpegLocator.locate(searchPaths: ["/a"], fileExists: { _ in false }))
    }
    func testNilWhenOnlyFfmpegPresent() {
        XCTAssertNil(FFmpegLocator.locate(searchPaths: ["/a"], fileExists: { $0 == "/a/ffmpeg" }))
    }
}
