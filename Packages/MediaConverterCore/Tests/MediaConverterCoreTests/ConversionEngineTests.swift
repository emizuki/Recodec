import XCTest
@testable import MediaConverterCore

final class ConversionEngineTests: XCTestCase {
    func testConvertsToHEVCAndReportsProgress() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
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

    func testTwoPassBitrateProducesOutput() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let input = dir.appendingPathComponent("eng2p-in-\(UUID().uuidString).mp4")
        let output = dir.appendingPathComponent("eng2p-out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }

        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: tools.ffmpeg)
        gen.arguments = ["-hide_banner", "-loglevel", "error",
                         "-f", "lavfi", "-i", "testsrc=size=160x120:rate=15:duration=1",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                         "-shortest", "-c:v", "libx264", "-c:a", "aac", "-y", input.path]
        try gen.run(); gen.waitUntilExit()

        let source = try await MediaProbe(ffprobe: tools.ffprobe).probe(input)
        var settings = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 23)
        settings.rateControl = .bitrate
        settings.videoBitrateKbps = 800
        XCTAssertTrue(settings.effectiveTwoPass)

        let progressBox = ProgressBox()
        let engine = FFmpegConversionEngine(ffmpeg: tools.ffmpeg)
        try await engine.convert(input: input, output: output, settings: settings, source: source) { f in
            progressBox.record(f)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let result = try await MediaProbe(ffprobe: tools.ffprobe).probe(output)
        XCTAssertEqual(result.videoCodecName, "h264")
        XCTAssertGreaterThan(progressBox.max, 0.0)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()))?
            .filter { $0.hasPrefix("recodec-pass-") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "passlog temp files must be removed")
    }

    /// Regression: when ffmpeg exits with a non-zero status the stderrTail must be
    /// non-empty — bytes that sat in the kernel pipe buffer after the handler was nil'd
    /// must be captured by the final synchronous readDataToEndOfFile() call.
    func testFfmpegFailureHasNonEmptyStderrTail() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let nonexistent = dir.appendingPathComponent("nonexistent-\(UUID().uuidString).mp4")
        let output = dir.appendingPathComponent("out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        let source = MediaInfo()
        let settings = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 23)
        let engine = FFmpegConversionEngine(ffmpeg: tools.ffmpeg)

        do {
            try await engine.convert(input: nonexistent, output: output,
                                     settings: settings, source: source) { _ in }
            XCTFail("Expected ConversionError.ffmpegFailed to be thrown")
        } catch ConversionError.ffmpegFailed(_, let stderrTail) {
            XCTAssertFalse(stderrTail.isEmpty,
                           "stderrTail must not be empty on ffmpeg failure — final pipe drain may be missing")
        }
    }

    // MARK: - HDR tone mapping (real ffmpeg + VideoToolbox)

    /// Skips unless the located ffmpeg ships the VideoToolbox filter the graph needs.
    private func requireToneMapSupport(_ tools: FFmpegTools) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tools.ffmpeg)
        p.arguments = ["-hide_banner", "-filters"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if !out.contains("scale_vt") { throw XCTSkip("ffmpeg has no scale_vt (VideoToolbox) filter") }
    }

    /// Writes a 1 s clip tagged with BT.2020 primaries and `transfer`. `tenBit` selects
    /// 10-bit HEVC (the iPhone / Screenshots-app shape); otherwise 8-bit H.264.
    private func makeClip(_ tools: FFmpegTools, transfer: String?, tenBit: Bool) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tm-in-\(UUID().uuidString).mp4")
        var args = ["-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15:duration=1"]
        let color = transfer.map { "colorprim=bt2020:transfer=\($0):colormatrix=bt2020nc" }
        if tenBit {
            args += ["-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1",
                     "-x265-params", (["log-level=error", color].compactMap { $0 }).joined(separator: ":")]
        } else {
            args += ["-c:v", "libx264", "-pix_fmt", "yuv420p"]
            if let color { args += ["-x264-params", color] }
        }
        args += ["-y", url.path]
        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: tools.ffmpeg)
        gen.arguments = args
        try gen.run(); gen.waitUntilExit()
        XCTAssertEqual(gen.terminationStatus, 0, "could not generate the test clip")
        return url
    }

    private func convertWithToneMap(_ tools: FFmpegTools, input: URL) async throws -> (source: MediaInfo, result: MediaInfo) {
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tm-out-\(UUID().uuidString).mp4")
        // The engine already deletes the output when ffmpeg fails. Removing it again
        // from here would hit ENOENT, and XCTest then reports that Cocoa error in
        // place of the ConversionError that actually failed the test.
        defer {
            if FileManager.default.fileExists(atPath: output.path) {
                try? FileManager.default.removeItem(at: output)
            }
        }
        let probe = MediaProbe(ffprobe: tools.ffprobe)
        let source = try await probe.probe(input)
        var settings = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .none, crf: 30)
        settings.toneMapHDR = true
        try await FFmpegConversionEngine(ffmpeg: tools.ffmpeg)
            .convert(input: input, output: output, settings: settings, source: source) { _ in }
        return (source, try await probe.probe(output))
    }

    func testToneMapsPQ10BitSourceToBT709() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        try requireToneMapSupport(tools)
        let input = try makeClip(tools, transfer: "smpte2084", tenBit: true)
        defer { try? FileManager.default.removeItem(at: input) }

        let (source, result) = try await convertWithToneMap(tools, input: input)
        XCTAssertTrue(source.isHDR, "test clip must be detected as HDR")
        XCTAssertEqual(result.colorTransfer, "bt709")
        XCTAssertFalse(result.isHDR)
    }

    /// Regression: an 8-bit HDR source (HLG H.264) decodes to NV12, which `hwdownload`
    /// cannot hand back as p010le unless the graph converts it first.
    func testToneMaps8BitHLGSource() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        try requireToneMapSupport(tools)
        let input = try makeClip(tools, transfer: "arib-std-b67", tenBit: false)
        defer { try? FileManager.default.removeItem(at: input) }

        let (source, result) = try await convertWithToneMap(tools, input: input)
        XCTAssertTrue(source.isHDR, "test clip must be detected as HDR")
        XCTAssertEqual(result.colorTransfer, "bt709")
    }

    /// The toggle is shared by a whole batch, so an SDR file converted with it on
    /// must come out as it would with it off — not fail, not be re-tagged.
    func testToneMapOnLeavesSDRSourceUntouched() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        try requireToneMapSupport(tools)
        let input = try makeClip(tools, transfer: nil, tenBit: false)
        defer { try? FileManager.default.removeItem(at: input) }

        let (source, result) = try await convertWithToneMap(tools, input: input)
        XCTAssertFalse(source.isHDR)
        XCTAssertEqual(result.videoCodecName, "h264")
        XCTAssertNil(result.colorTransfer, "SDR input must not be re-tagged as bt709")
    }
}

/// Thread-safe progress recorder (callback fires on a background queue).
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _max = 0.0
    var max: Double { lock.lock(); defer { lock.unlock() }; return _max }
    func record(_ f: Double) { lock.lock(); _max = Swift.max(_max, f); lock.unlock() }
}
