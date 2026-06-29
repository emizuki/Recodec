import XCTest
@testable import MediaConverterCore

final class MediaProbeTests: XCTestCase {
    func testProbesGeneratedClip() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Generate a 1s H.264/AAC clip with ffmpeg.
        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: tools.ffmpeg)
        gen.arguments = ["-hide_banner", "-loglevel", "error",
                         "-f", "lavfi", "-i", "testsrc=size=160x120:rate=15:duration=1",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                         "-shortest", "-c:v", "libx264", "-c:a", "aac", "-y", tmp.path]
        try gen.run(); gen.waitUntilExit()
        XCTAssertEqual(gen.terminationStatus, 0)

        let info = try await MediaProbe(ffprobe: tools.ffprobe).probe(tmp)
        XCTAssertEqual(info.videoCodecName, "h264")
        XCTAssertEqual(info.audioCodecName, "aac")
        XCTAssertEqual(try XCTUnwrap(info.durationSeconds), 1.0, accuracy: 0.3)
    }
}
