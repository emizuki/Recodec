import XCTest
@testable import MediaConverterCore

final class ConversionEngineTests: XCTestCase {
    func testConvertsToHEVCAndReportsProgress() async throws {
        let tools = try XCTUnwrap(FFmpegLocator.locate(), "ffmpeg not installed — skipping")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let input = dir.appendingPathComponent("eng-in-\(UUID().uuidString).mp4")
        let output = dir.appendingPathComponent("eng-out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }

        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: tools.ffmpeg)
        gen.arguments = ["-hide_banner", "-loglevel", "error",
                         "-f", "lavfi", "-i", "testsrc=size=160x120:rate=15:duration=1",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                         "-shortest", "-c:v", "libx264", "-c:a", "aac", "-y", input.path]
        try gen.run(); gen.waitUntilExit()

        let source = try await MediaProbe(ffprobe: tools.ffprobe).probe(input)
        let settings = ConversionSettings(container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 30)

        let progressBox = ProgressBox()
        let engine = FFmpegConversionEngine(ffmpeg: tools.ffmpeg)
        try await engine.convert(input: input, output: output, settings: settings, source: source) { f in
            progressBox.record(f)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let result = try await MediaProbe(ffprobe: tools.ffprobe).probe(output)
        XCTAssertEqual(result.videoCodecName, "hevc")
        XCTAssertGreaterThan(progressBox.max, 0.0)
    }
}

/// Thread-safe progress recorder (callback fires on a background queue).
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _max = 0.0
    var max: Double { lock.lock(); defer { lock.unlock() }; return _max }
    func record(_ f: Double) { lock.lock(); _max = Swift.max(_max, f); lock.unlock() }
}
