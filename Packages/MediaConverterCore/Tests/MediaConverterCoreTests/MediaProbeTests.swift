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

    /// An x265 clip whose HLG is written as an alternative-transfer SEI only, leaving the stream tag at
    /// BT.2020-10. With `audioFirst` the audio track comes first and the video starts half a second later,
    /// the order of an ordinary camera or broadcast file. nil when this ffmpeg has no libx265.
    private func makeSEIOnlyHLG(_ tools: FFmpegTools, audioFirst: Bool) throws -> URL? {
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-hlg-\(UUID().uuidString).mkv")
        let video = ["-f", "lavfi", "-i", "testsrc2=size=160x120:rate=15:duration=1"]
        let audio = ["-f", "lavfi", "-i", "sine=duration=2"]
        let encode = ["-c:v", "libx265", "-pix_fmt", "yuv420p10le",
                      "-x265-params", "colorprim=bt2020:transfer=bt2020-10:colormatrix=bt2020nc:atc-sei=18:log-level=error"]
        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: tools.ffmpeg)
        gen.arguments = ["-hide_banner", "-loglevel", "error"]
            + (audioFirst
               ? audio + ["-itsoffset", "0.5"] + video + ["-map", "0:a", "-map", "1:v", "-c:a", "aac"] + encode
               : video + encode)
            + ["-y", out.path]
        gen.standardError = Pipe()
        try gen.run(); gen.waitUntilExit()
        guard gen.terminationStatus == 0 else { return nil }
        return out
    }

    func testProbeFlagsHLGThatOnlyTheBitstreamSignals() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        guard let clip = try makeSEIOnlyHLG(tools, audioFirst: false) else { throw XCTSkip("ffmpeg has no libx265") }
        defer { try? FileManager.default.removeItem(at: clip) }

        let info = try await MediaProbe(ffprobe: tools.ffprobe).probe(clip)
        XCTAssertTrue(info.isHDR, "transfer read as \(info.colorTransfer ?? "nil")")
    }

    /// `-read_intervals %+#1` counts packets, not video frames: with the audio first, the one packet read
    /// was audio, no frame came back and the SEI-only HLG was missed. The video frame is asked for on its own.
    func testProbeFlagsSEIOnlyHLGWhenTheAudioComesFirst() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        guard let clip = try makeSEIOnlyHLG(tools, audioFirst: true) else { throw XCTSkip("ffmpeg has no libx265") }
        defer { try? FileManager.default.removeItem(at: clip) }

        let info = try await MediaProbe(ffprobe: tools.ffprobe).probe(clip)
        XCTAssertEqual(info.audioCodecs, ["aac"], "the audio stream is still read")
        XCTAssertTrue(info.isHDR, "transfer read as \(info.colorTransfer ?? "nil")")
    }
}
