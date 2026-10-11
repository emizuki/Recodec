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

    private func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out
    }

    /// Removes files that exist. The engine already deletes its output when ffmpeg fails;
    /// removing it again would hit ENOENT, and XCTest then reports that Cocoa error in
    /// place of the ConversionError that actually failed the test.
    private func discard(_ urls: URL...) {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Skips unless the located ffmpeg ships the VideoToolbox filter the graph needs.
    private func requireToneMapSupport(_ tools: FFmpegTools) throws {
        let filters = try run(tools.ffmpeg, ["-hide_banner", "-filters"])
        if !filters.contains("scale_vt") { throw XCTSkip("ffmpeg has no scale_vt (VideoToolbox) filter") }
    }

    private func requireEncoder(_ tools: FFmpegTools, _ name: String) throws {
        let encoders = try run(tools.ffmpeg, ["-hide_banner", "-encoders"])
        if !encoders.contains(name) { throw XCTSkip("ffmpeg has no \(name) encoder to build the fixture") }
    }

    private enum Fixture {
        /// 10-bit HEVC, PQ, BT.2020, with HDR10 mastering display + MaxCLL (iPhone / Screenshots shape).
        case pq10
        /// `pq10` carrying a display-matrix rotation of 90°, as portrait iPhone clips do.
        case pq10Rotated
        /// 8-bit H.264, HLG, BT.2020.
        case hlg8
        /// 8-bit H.264 with no colour tags.
        case sdr8
        /// 10-bit AV1, PQ, BT.2020. Macs without AV1 decode hardware can only decode it in software.
        case pqAV1
        /// 1024×64 PQ luminance ramp, one code per column, stored full or limited range.
        case ramp(fullRange: Bool)
    }

    private func makeFixture(_ tools: FFmpegTools, _ fixture: Fixture) throws -> URL {
        func tmp(_ tag: String) -> URL {
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tm-\(tag)-\(UUID().uuidString).mp4")
        }
        let bt2020 = "colorprim=bt2020:colormatrix=bt2020nc"
        let hdr10 = "master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400"
        let testsrc = ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15:duration=1"]
        let url = tmp("in")
        var args = ["-hide_banner", "-loglevel", "error"]
        switch fixture {
        case .pq10, .pq10Rotated:
            args += testsrc + ["-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1",
                               "-x265-params", "log-level=error:\(bt2020):transfer=smpte2084:\(hdr10)"]
        case .hlg8:
            args += testsrc + ["-c:v", "libx264", "-pix_fmt", "yuv420p",
                               "-x264-params", "\(bt2020):transfer=arib-std-b67"]
        case .sdr8:
            args += testsrc + ["-c:v", "libx264", "-pix_fmt", "yuv420p"]
        case .pqAV1:
            args += testsrc + ["-c:v", "libsvtav1", "-pix_fmt", "yuv420p10le",
                               "-svtav1-params", "color-primaries=9:transfer-characteristics=16:matrix-coefficients=9"]
        case .ramp(let fullRange):
            let lum = fullRange ? "X" : "64+X/1023*876"
            args += ["-f", "lavfi", "-i",
                     "color=c=black:s=1024x64:r=10:d=1,format=yuv420p10le,geq=lum='\(lum)':cb=512:cr=512",
                     "-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1",
                     "-x265-params",
                     "log-level=error:\(bt2020):transfer=smpte2084:range=\(fullRange ? "full" : "limited")"]
        }
        args += ["-y", url.path]
        _ = try run(tools.ffmpeg, args)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "could not generate the test clip")

        if case .pq10Rotated = fixture {
            // `-display_rotation` is an input option: it re-tags the existing stream without re-encoding.
            let rotated = tmp("rot")
            _ = try run(tools.ffmpeg, ["-hide_banner", "-loglevel", "error", "-display_rotation:v:0", "90",
                                       "-i", url.path, "-c", "copy", "-y", rotated.path])
            discard(url)
            return rotated
        }
        return url
    }

    private struct Converted {
        let source: MediaInfo
        let output: URL
    }

    private func convert(_ tools: FFmpegTools, input: URL, toneMap: Bool = true,
                         codec: VideoCodec = .h264, hardware: Bool = false, crf: Int = 30) async throws -> Converted {
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tm-out-\(UUID().uuidString).mp4")
        let source = try await MediaProbe(ffprobe: tools.ffprobe).probe(input)
        var settings = ConversionSettings(container: .mp4, videoCodec: codec, audioCodec: .none,
                                          crf: crf, useHardware: hardware)
        settings.toneMapHDR = toneMap
        try await FFmpegConversionEngine(ffmpeg: tools.ffmpeg)
            .convert(input: input, output: output, settings: settings, source: source) { _ in }
        return Converted(source: source, output: output)
    }

    private func videoStream(_ tools: FFmpegTools, _ url: URL) throws -> [String: Any] {
        let json = try run(tools.ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_streams",
                                           "-of", "json", url.path])
        let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return try XCTUnwrap((root?["streams"] as? [[String: Any]])?.first, "no video stream in \(url.lastPathComponent)")
    }

    private func sideDataTypes(_ stream: [String: Any]) -> [String] {
        (stream["side_data_list"] as? [[String: Any]] ?? []).compactMap { $0["side_data_type"] as? String }
    }

    /// Stored 8-bit luma code of an 8×8 patch at column `x` of the first frame (no range conversion).
    private func lumaCode(_ tools: FFmpegTools, _ url: URL, x: Int) throws -> Double {
        let out = try run(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-i", url.path, "-frames:v", "1",
            "-vf", "crop=8:8:\(x):28,format=yuv420p,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-",
            "-f", "null", "-"])
        let line = try XCTUnwrap(out.split(separator: "\n").first { $0.contains("YAVG=") })
        return try XCTUnwrap(Double(line.split(separator: "=").last ?? ""))
    }

    func testToneMapsPQ10BitSourceToBT709() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        try requireToneMapSupport(tools)
        let input = try makeFixture(tools, .pq10)
        defer { discard(input) }

        // Software and VideoToolbox encoders take different paths through ffmpeg.
        for (codec, hardware) in [(VideoCodec.h264, false), (.hevc, true)] {
            let converted = try await convert(tools, input: input, codec: codec, hardware: hardware)
            defer { discard(converted.output) }
            let label = "\(codec) hardware=\(hardware)"
            XCTAssertTrue(converted.source.isHDR, "test clip must be detected as HDR")

            let stream = try videoStream(tools, converted.output)
            // All three tags: scale_vt only sets the transfer itself, the matrix and primaries
            // would stay BT.2020 on BT.709 pixels without the explicit encoder tags.
            XCTAssertEqual(stream["color_transfer"] as? String, "bt709", label)
            XCTAssertEqual(stream["color_space"] as? String, "bt709", label)
            XCTAssertEqual(stream["color_primaries"] as? String, "bt709", label)
            // Mastering display / MaxCLL would make players treat the file as HDR again.
            let hdrSideData = sideDataTypes(stream).filter { $0.contains("Mastering") || $0.contains("Content light") }
            XCTAssertTrue(hdrSideData.isEmpty, "\(label): HDR side data survived: \(hdrSideData)")
            // Without `hvc1` HEVC in MP4 is tagged `hev1`, which QuickTime and iOS will not play.
            if codec == .hevc { XCTAssertEqual(stream["codec_tag_string"] as? String, "hvc1", label) }
        }
    }

    /// Regression: an 8-bit HDR source (HLG H.264) decodes to NV12, which `hwdownload`
    /// cannot hand back as p010le unless the graph converts it first.
    func testToneMaps8BitHLGSource() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        try requireToneMapSupport(tools)
        let input = try makeFixture(tools, .hlg8)
        defer { discard(input) }

        let converted = try await convert(tools, input: input)
        defer { discard(converted.output) }
        XCTAssertTrue(converted.source.isHDR, "test clip must be detected as HDR")
        let stream = try videoStream(tools, converted.output)
        XCTAssertEqual(stream["color_transfer"] as? String, "bt709")
        XCTAssertEqual(stream["color_space"] as? String, "bt709")
    }

    /// The toggle is shared by a whole batch, so an SDR file converted with it on
    /// must come out as it would with it off — not fail, not be re-tagged.
    func testToneMapOnLeavesSDRSourceUntouched() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        try requireToneMapSupport(tools)
        let input = try makeFixture(tools, .sdr8)
        defer { discard(input) }

        let converted = try await convert(tools, input: input)
        defer { discard(converted.output) }
        XCTAssertFalse(converted.source.isHDR)
        let result = try await MediaProbe(ffprobe: tools.ffprobe).probe(converted.output)
        XCTAssertEqual(result.videoCodecName, "h264")
        XCTAssertNil(result.colorTransfer, "SDR input must not be re-tagged as bt709")
    }

    /// `-hwaccel videotoolbox` forces ffmpeg's hardware-only AV1 decoder: on a Mac without AV1
    /// decode hardware the whole conversion used to fail instead of decoding in software.
    func testToneMapsAV1SourceThroughSoftwareDecode() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        try requireToneMapSupport(tools)
        try requireEncoder(tools, "libsvtav1")
        let input = try makeFixture(tools, .pqAV1)
        defer { discard(input) }

        let converted = try await convert(tools, input: input)
        defer { discard(converted.output) }
        XCTAssertTrue(converted.source.isHDR, "test clip must be detected as HDR")
        XCTAssertEqual(try videoStream(tools, converted.output)["color_transfer"] as? String, "bt709")
    }

    /// Regression: with hardware frames ffmpeg could not apply the display-matrix rotation,
    /// so portrait iPhone clips came out landscape. Tone mapping must match the toggle-off result.
    func testToneMapKeepsDisplayRotation() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        try requireToneMapSupport(tools)
        let input = try makeFixture(tools, .pq10Rotated)
        defer { discard(input) }

        let off = try await convert(tools, input: input, toneMap: false)
        defer { discard(off.output) }
        let on = try await convert(tools, input: input, toneMap: true)
        defer { discard(on.output) }
        let offStream = try videoStream(tools, off.output)
        let onStream = try videoStream(tools, on.output)
        let offSize = [offStream["width"] as? Int, offStream["height"] as? Int]
        XCTAssertEqual(offSize, [240, 320], "fixture: a 320x240 clip rotated 90° is portrait")
        XCTAssertEqual([onStream["width"] as? Int, onStream["height"] as? Int], offSize)
    }

    /// `hwupload` makes video-range buffers. A full-range source must be converted first, or
    /// it comes out with lifted blacks and capped whites, tagged full range on limited pixels.
    func testToneMapFullRangeSourceMatchesItsLimitedRangeTwin() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        try requireToneMapSupport(tools)
        let limitedIn = try makeFixture(tools, .ramp(fullRange: false))
        let fullIn = try makeFixture(tools, .ramp(fullRange: true))
        defer { discard(limitedIn, fullIn) }

        let limited = try await convert(tools, input: limitedIn, crf: 18)
        defer { discard(limited.output) }
        let full = try await convert(tools, input: fullIn, crf: 18)
        defer { discard(full.output) }

        for output in [limited.output, full.output] {
            let stream = try videoStream(tools, output)
            XCTAssertEqual(stream["color_range"] as? String, "tv", "pixels are limited range, the tag must say so")
        }
        // Same logical luminance ramp, two encodings: the tone-mapped codes must agree.
        for x in [64, 192, 320, 576] {
            let a = try lumaCode(tools, limited.output, x: x)
            let b = try lumaCode(tools, full.output, x: x)
            XCTAssertEqual(a, b, accuracy: 3, "column \(x): limited-range twin \(a) vs full-range source \(b)")
        }
    }

    // MARK: - Keep all tracks (real ffmpeg)

    private enum Layout {
        /// h264 + aac with two chapters. MP4 stores them so they read back as an extra `bin_data` track.
        case chaptersMP4
        /// h264 + aac + an mjpeg cover picture (attached_pic).
        case coverMP4
        /// aac first, h264 second.
        case audioFirstMP4
        /// h264, aac + ac3, two srt subtitles, one attachment.
        case multiMKV
        /// A plain AAC file: no video stream at all.
        case audioOnlyM4A
        /// AAC plus an mjpeg cover picture and no real video.
        case audioWithCoverM4A
        /// hevc (`hvc1`) + aac + an mjpeg cover picture.
        case hevcCoverMP4
    }

    private func makeLayout(_ tools: FFmpegTools, _ layout: Layout) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        func tmp(_ name: String) -> URL { dir.appendingPathComponent("ka-\(UUID().uuidString)-\(name)") }
        var scratch: [URL] = []
        defer { scratch.forEach { discard($0) } }
        let base = ["-hide_banner", "-loglevel", "error"]
        let video = ["-f", "lavfi", "-i", "testsrc2=size=160x120:rate=15:duration=2"]
        let audio = ["-f", "lavfi", "-i", "sine=frequency=440:duration=2"]
        let x264 = ["-c:v", "libx264", "-preset", "ultrafast"]
        func makeCover() throws -> URL {
            let cover = tmp("cover.jpg"); scratch.append(cover)
            _ = try run(tools.ffmpeg, base + ["-f", "lavfi", "-i", "color=c=red:s=64x64:d=1",
                                              "-frames:v", "1", "-y", cover.path])
            return cover
        }
        let out: URL
        switch layout {
        case .chaptersMP4:
            let meta = tmp("chapters.ffmeta"); scratch.append(meta)
            try """
            ;FFMETADATA1
            [CHAPTER]
            TIMEBASE=1/1000
            START=0
            END=1000
            title=One
            [CHAPTER]
            TIMEBASE=1/1000
            START=1000
            END=2000
            title=Two
            """.write(to: meta, atomically: true, encoding: .utf8)
            out = tmp("chapters.mp4")
            _ = try run(tools.ffmpeg, base + video + audio + ["-i", meta.path, "-map", "0:v", "-map", "1:a",
                                                               "-map_metadata", "2"] + x264 + ["-c:a", "aac", "-y", out.path])
        case .coverMP4:
            let cover = tmp("cover.jpg"); scratch.append(cover)
            _ = try run(tools.ffmpeg, base + ["-f", "lavfi", "-i", "color=c=red:s=64x64:d=1",
                                              "-frames:v", "1", "-y", cover.path])
            out = tmp("cover.mp4")
            _ = try run(tools.ffmpeg, base + video + audio + ["-i", cover.path, "-map", "0:v", "-map", "1:a", "-map", "2:v",
                                                               "-c:v:0", "libx264", "-preset", "ultrafast", "-c:a", "aac",
                                                               "-c:v:1", "mjpeg", "-disposition:v:1", "attached_pic",
                                                               "-y", out.path])
        case .audioOnlyM4A:
            out = tmp("audio.m4a")
            _ = try run(tools.ffmpeg, base + audio + ["-c:a", "aac", "-y", out.path])
        case .audioWithCoverM4A:
            let cover = try makeCover()
            out = tmp("audiocover.m4a")
            _ = try run(tools.ffmpeg, base + audio + ["-i", cover.path, "-map", "0:a", "-map", "1:v", "-c:a", "aac",
                                                       "-c:v", "mjpeg", "-disposition:v", "attached_pic", "-y", out.path])
        case .hevcCoverMP4:
            let cover = try makeCover()
            out = tmp("hevccover.mp4")
            _ = try run(tools.ffmpeg, base + video + audio + ["-i", cover.path, "-map", "0:v", "-map", "1:a", "-map", "2:v",
                                                               "-c:v:0", "libx265", "-preset", "ultrafast",
                                                               "-x265-params", "log-level=error", "-tag:v:0", "hvc1",
                                                               "-c:a", "aac", "-c:v:1", "mjpeg",
                                                               "-disposition:v:1", "attached_pic", "-y", out.path])
        case .audioFirstMP4:
            out = tmp("audiofirst.mp4")
            _ = try run(tools.ffmpeg, base + audio + video + ["-map", "0:a", "-map", "1:v", "-c:a", "aac"] + x264
                                                              + ["-y", out.path])
        case .multiMKV:
            let ger = tmp("ger.srt"), eng = tmp("eng.srt"), font = tmp("font.ttf"); scratch += [ger, eng, font]
            try "1\n00:00:00,000 --> 00:00:01,000\nHallo\n".write(to: ger, atomically: true, encoding: .utf8)
            try "1\n00:00:00,000 --> 00:00:01,000\nHello\n".write(to: eng, atomically: true, encoding: .utf8)
            try "not really a font".write(to: font, atomically: true, encoding: .utf8)
            out = tmp("multi.mkv")
            _ = try run(tools.ffmpeg, base + video + audio + ["-f", "lavfi", "-i", "sine=frequency=880:duration=2",
                                                               "-i", ger.path, "-i", eng.path,
                                                               "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3", "-map", "4"]
                                      + x264 + ["-c:a:0", "aac", "-c:a:1", "ac3", "-c:s", "srt",
                                                "-metadata:s:s:0", "language=ger", "-metadata:s:s:1", "language=eng",
                                                "-attach", font.path,
                                                "-metadata:s:t", "mimetype=application/x-truetype-font",
                                                "-metadata:s:t", "filename=font.ttf", "-y", out.path])
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "could not generate the \(layout) fixture")
        return out
    }

    /// Stream kinds in output order, attached-picture count and chapter count, from ffprobe.
    private func layoutOf(_ tools: FFmpegTools, _ url: URL) throws -> (kinds: [String], pictures: Int, chapters: Int) {
        let json = try run(tools.ffprobe, ["-v", "error", "-show_streams", "-show_chapters", "-of", "json", url.path])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let streams = root["streams"] as? [[String: Any]] ?? []
        let pictures = streams.filter { (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1 }.count
        return (streams.compactMap { $0["codec_type"] as? String }, pictures, (root["chapters"] as? [Any])?.count ?? 0)
    }

    private func keepAll(_ tools: FFmpegTools, input: URL, to container: Container, video: VideoCodec,
                         audio: AudioCodec, bitrate: Bool = false) async throws -> URL {
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ka-out-\(UUID().uuidString).\(container.fileExtension)")
        let source = try await MediaProbe(ffprobe: tools.ffprobe).probe(input)
        var settings = ConversionSettings(container: container, videoCodec: video, audioCodec: audio, crf: 32)
        settings.preset = .ultrafast
        settings.preserveAllStreams = true
        if bitrate { settings.rateControl = .bitrate; settings.videoBitrateKbps = 300 }
        try await FFmpegConversionEngine(ffmpeg: tools.ffmpeg)
            .convert(input: input, output: output, settings: settings, source: source) { _ in }
        return output
    }

    /// The track MP4 writes for chapters is a data stream Matroska and QuickTime refuse
    /// (as are iPhone `mebx` metadata tracks); a blanket `-map 0` aborted the whole run.
    func testKeepAllTracksDropsDataStreamsButKeepsChapters() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        let input = try makeLayout(tools, .chaptersMP4)
        defer { discard(input) }

        for container in [Container.mkv, .mov, .mp4] {
            let output = try await keepAll(tools, input: input, to: container, video: .h264, audio: .aac)
            defer { discard(output) }
            let result = try layoutOf(tools, output)
            XCTAssertEqual(Array(result.kinds.prefix(2)), ["video", "audio"], "\(container)")
            XCTAssertEqual(result.chapters, 2, "\(container): chapters belong to the container, not the dropped track")
        }
    }

    /// Re-encoding with `-map 0` encoded the cover picture as a second video track (MKV/WebM) or
    /// aborted the muxer (MP4/MOV/M4V).
    func testKeepAllTracksReencodeDoesNotTurnCoverArtIntoAVideoTrack() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        let input = try makeLayout(tools, .coverMP4)
        defer { discard(input) }

        for container in [Container.mp4, .mkv] {
            let output = try await keepAll(tools, input: input, to: container, video: .h264, audio: .aac)
            defer { discard(output) }
            let result = try layoutOf(tools, output)
            XCTAssertEqual(result.kinds, ["video", "audio"], "\(container)")
            XCTAssertEqual(result.pictures, 0, "\(container)")
        }
    }

    func testKeepAllTracksVideoCopyCarriesCoverArtThrough() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        let input = try makeLayout(tools, .coverMP4)
        defer { discard(input) }

        let output = try await keepAll(tools, input: input, to: .mp4, video: .copy, audio: .aac)
        defer { discard(output) }
        let result = try layoutOf(tools, output)
        XCTAssertEqual(result.kinds.filter { $0 == "video" }.count, 2)
        XCTAssertEqual(result.pictures, 1, "nothing is re-encoded, so the picture can stay")
    }

    /// MP3, FLAC and WAV muxers accept exactly one audio stream; M4A takes every track.
    func testKeepAllTracksIntoAudioOnlyTargets() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        let input = try makeLayout(tools, .multiMKV)
        defer { discard(input) }

        for (container, audio) in [(Container.mp3, AudioCodec.mp3), (.flac, .flac)] {
            let output = try await keepAll(tools, input: input, to: container, video: .none, audio: audio)
            defer { discard(output) }
            XCTAssertEqual(try layoutOf(tools, output).kinds, ["audio"], "\(container)")
        }
        let m4a = try await keepAll(tools, input: input, to: .m4a, video: .none, audio: .aac)
        defer { discard(m4a) }
        XCTAssertEqual(try layoutOf(tools, m4a).kinds, ["audio", "audio"])
    }

    /// Pass 1 writes its stats for output stream 0; with the audio first, pass 2 opened the
    /// log of the video's real index and could not find it.
    func testKeepAllTracksTwoPassWithAudioFirstSource() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        let input = try makeLayout(tools, .audioFirstMP4)
        defer { discard(input) }

        let output = try await keepAll(tools, input: input, to: .mp4, video: .h264, audio: .aac, bitrate: true)
        defer { discard(output) }
        XCTAssertEqual(try layoutOf(tools, output).kinds, ["video", "audio"])
    }

    func testKeepAllTracksKeepsEverythingMatroskaCanHold() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        let input = try makeLayout(tools, .multiMKV)
        defer { discard(input) }

        let output = try await keepAll(tools, input: input, to: .mkv, video: .h264, audio: .aac)
        defer { discard(output) }
        XCTAssertEqual(try layoutOf(tools, output).kinds,
                       ["video", "audio", "audio", "subtitle", "subtitle", "attachment"])
    }

    /// Audio files have no video stream. A required video map aborted the run for them as soon
    /// as the target was a video container (the setting covers the whole batch).
    func testKeepAllTracksConvertsAudioOnlySourcesIntoVideoContainers() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        let plain = try makeLayout(tools, .audioOnlyM4A)
        let withCover = try makeLayout(tools, .audioWithCoverM4A)
        defer { discard(plain, withCover) }

        for input in [plain, withCover] {
            for container in [Container.mp4, .mkv] {
                let output = try await keepAll(tools, input: input, to: container, video: .h264, audio: .aac)
                defer { discard(output) }
                XCTAssertEqual(try layoutOf(tools, output).kinds, ["audio"], "\(input.lastPathComponent) → \(container)")
            }
        }
    }

    /// `-tag:v hvc1` hit the cover picture too, and the MP4 muxer rejects that: an HEVC remux of a
    /// file with cover art aborted. With video Copy the picture must come through untouched.
    func testKeepAllTracksHEVCCopyWithCoverArtIntoMP4() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        let input = try makeLayout(tools, .hevcCoverMP4)
        defer { discard(input) }

        let output = try await keepAll(tools, input: input, to: .mp4, video: .copy, audio: .aac)
        defer { discard(output) }
        let result = try layoutOf(tools, output)
        XCTAssertEqual(result.pictures, 1)
        XCTAssertEqual(try videoStream(tools, output)["codec_tag_string"] as? String, "hvc1")
    }
}

/// Thread-safe progress recorder (callback fires on a background queue).
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _max = 0.0
    var max: Double { lock.lock(); defer { lock.unlock() }; return _max }
    func record(_ f: Double) { lock.lock(); _max = Swift.max(_max, f); lock.unlock() }
}
