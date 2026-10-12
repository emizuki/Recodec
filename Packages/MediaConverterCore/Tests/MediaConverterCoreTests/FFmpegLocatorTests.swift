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

    // MARK: - Filter detection

    func testFilterListingMatchesWholeFilterNames() {
        let listing = """
        Filters:
          T.. = Timeline support
          ..C = Command support
         .. scale             V->V       Scale the input video size and/or convert the image format.
         .. scale_vt          V->V       Scale Videotoolbox frames
         T. scale_vulkan      V->V       Scale Vulkan frames
         .. split             V->N       Pass on the input to N video outputs.
        """
        XCTAssertTrue(FFmpegTools.filterListing(listing, contains: "scale_vt"))
        XCTAssertTrue(FFmpegTools.filterListing(listing, contains: "scale"))
        // A prefix of a listed name, a name only mentioned in a description, and a header word.
        XCTAssertFalse(FFmpegTools.filterListing(listing, contains: "scale_v"))
        XCTAssertFalse(FFmpegTools.filterListing(listing, contains: "Videotoolbox"))
        XCTAssertFalse(FFmpegTools.filterListing(listing, contains: "Timeline"))
        XCTAssertFalse(FFmpegTools.filterListing("", contains: "scale_vt"))
    }

    func testHasFilterAsksTheRealFfmpeg() throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        XCTAssertTrue(tools.hasFilter("scale"), "every ffmpeg has the scale filter")
        XCTAssertFalse(tools.hasFilter("no_such_filter_\(UUID().uuidString.prefix(8))"))
    }
}
