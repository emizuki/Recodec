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

    // MARK: - Override diagnostics

    func testOverrideProblemIsNilForUsableDirectory() {
        let present: Set<String> = ["/opt/ff", "/opt/ff/ffmpeg", "/opt/ff/ffprobe"]
        XCTAssertNil(FFmpegLocator.overrideProblem(
            directory: "/opt/ff",
            fileExists: { present.contains($0) },
            isExecutable: { present.contains($0) }
        ))
    }

    func testOverrideProblemReportsMissingDirectory() {
        let reason = FFmpegLocator.overrideProblem(
            directory: "/opt/ff",
            fileExists: { _ in false },
            isExecutable: { _ in false }
        )
        XCTAssertEqual(reason, "ffmpeg directory override does not exist")
    }

    func testOverrideProblemReportsMissingFfmpeg() {
        let present: Set<String> = ["/opt/ff", "/opt/ff/ffprobe"]
        let reason = FFmpegLocator.overrideProblem(
            directory: "/opt/ff",
            fileExists: { present.contains($0) },
            isExecutable: { present.contains($0) }
        )
        XCTAssertEqual(reason, "ffmpeg directory override has no ffmpeg")
    }

    func testOverrideProblemReportsMissingFfprobe() {
        let present: Set<String> = ["/opt/ff", "/opt/ff/ffmpeg"]
        let reason = FFmpegLocator.overrideProblem(
            directory: "/opt/ff",
            fileExists: { present.contains($0) },
            isExecutable: { present.contains($0) }
        )
        XCTAssertEqual(reason, "ffmpeg directory override has no ffprobe")
    }

    func testOverrideProblemReportsNonExecutableBinaries() {
        let present: Set<String> = ["/opt/ff", "/opt/ff/ffmpeg", "/opt/ff/ffprobe"]
        let reason = FFmpegLocator.overrideProblem(
            directory: "/opt/ff",
            fileExists: { present.contains($0) },
            isExecutable: { _ in false }
        )
        XCTAssertEqual(reason, "ffmpeg directory override is not executable")
    }

    func testLocateFallsBackToDefaultPathsWhenOverrideIsRejected() throws {
        let fm = FileManager.default
        let key = FFmpegLocator.overrideDefaultsKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        UserDefaults.standard.set(directory.path, forKey: key)

        let expected = FFmpegLocator.locate(searchPaths: FFmpegLocator.defaultSearchPaths) {
            fm.isExecutableFile(atPath: $0)
        }
        XCTAssertEqual(FFmpegLocator.locate(), expected)
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
