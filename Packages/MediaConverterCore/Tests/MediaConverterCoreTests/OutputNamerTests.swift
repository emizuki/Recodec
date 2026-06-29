import XCTest
@testable import MediaConverterCore

final class OutputNamerTests: XCTestCase {
    func testNoCollision() {
        let out = OutputNamer.outputURL(forInput: URL(fileURLWithPath: "/d/clip.mkv"),
                                        container: .mp4, fileExists: { _ in false })
        XCTAssertEqual(out.path, "/d/clip.mp4")
    }
    func testCollidesWithInput() {
        let input = URL(fileURLWithPath: "/d/clip.mp4")
        let out = OutputNamer.outputURL(forInput: input, container: .mp4,
                                        fileExists: { $0.path == "/d/clip.mp4" })
        XCTAssertEqual(out.path, "/d/clip (converted).mp4")
    }
    func testSecondCollision() {
        let taken: Set<String> = ["/d/clip.mp4", "/d/clip (converted).mp4"]
        let out = OutputNamer.outputURL(forInput: URL(fileURLWithPath: "/d/clip.mp4"),
                                        container: .mp4, fileExists: { taken.contains($0.path) })
        XCTAssertEqual(out.path, "/d/clip (converted 2).mp4")
    }
}
