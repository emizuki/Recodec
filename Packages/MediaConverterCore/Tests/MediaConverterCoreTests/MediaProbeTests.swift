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

    /// The frame read only refines the transfer function. Output of it that cannot be parsed (here a
    /// script stands in for ffprobe and cuts the JSON short, exit 0) must leave the file readable with
    /// its stream-level metadata, as a failing or empty frame call does, not turn it into "Couldn't read".
    func testUnparsableFrameOutputDoesNotMakeAReadableFileUnreadable() async throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let clip = dir.appendingPathComponent("probe-cut-\(UUID().uuidString).mp4")
        let script = dir.appendingPathComponent("fake-ffprobe-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: clip); try? FileManager.default.removeItem(at: script) }
        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: tools.ffmpeg)
        gen.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=15:duration=1",
                         "-c:v", "libx264", "-y", clip.path]
        try gen.run(); gen.waitUntilExit()
        XCTAssertEqual(gen.terminationStatus, 0)

        // The real ffprobe for the stream listing; broken JSON, exit 0, for the frame call.
        try """
        #!/bin/sh
        for a in "$@"; do
          if [ "$a" = "-show_frames" ]; then echo '{"frames": ['; exit 0; fi
        done
        exec "\(tools.ffprobe)" "$@"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let info = try await MediaProbe(ffprobe: script.path).probe(clip)
        XCTAssertEqual(info.videoCodecName, "h264")
    }

    /// Cover art in an mp4/m4a is a video stream flagged `attached_pic`; if it comes before the real
    /// video, `v:0` would name the cover and its frame would not match the real stream's index.
    /// The frame read asks for `V:0` (video excluding attached pictures) instead.
    func testFrameProbeIgnoresCoverArtThatComesFirst() async throws {
        let streams = """
        {"streams":[{"index":0,"codec_type":"video","codec_name":"png","disposition":{"attached_pic":1}},
                    {"index":1,"codec_type":"video","codec_name":"hevc"},
                    {"index":2,"codec_type":"audio","codec_name":"aac"}],
         "format":{"duration":"5.0"}}
        """
        let frames = #"{"frames":[{"stream_index":1,"media_type":"video","color_transfer":"smpte2084"}]}"#
        let fake = try fakeProbe(streams: streams, frames: frames)
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let info = try await MediaProbe(ffprobe: fake.probe.path).probe(URL(fileURLWithPath: "/cover-first.mp4"))

        XCTAssertEqual(info.videoCodecName, "hevc")
        XCTAssertEqual(info.colorTransfer, "smpte2084", "the real video's frame, not the cover's")
        let log = try String(contentsOf: fake.directory.appendingPathComponent("args.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("-select_streams V:0"), "frame read args: \(log)")
    }

    /// An audio-only file with cover art has no video to read a frame from, so the second ffprobe
    /// call must not run at all.
    func testCoverOnlyFileSkipsTheFrameProbe() async throws {
        let streams = """
        {"streams":[{"index":0,"codec_type":"audio","codec_name":"aac"},
                    {"index":1,"codec_type":"video","codec_name":"png","disposition":{"attached_pic":1}}],
         "format":{"duration":"3.0"}}
        """
        let fake = try fakeProbe(streams: streams, frames: #"{"frames":[]}"#)
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let info = try await MediaProbe(ffprobe: fake.probe.path).probe(URL(fileURLWithPath: "/cover.m4a"))

        XCTAssertNil(info.videoCodecName)
        let log = try String(contentsOf: fake.directory.appendingPathComponent("args.log"), encoding: .utf8)
        XCTAssertFalse(log.contains("-show_frames"), "frame read ran: \(log)")
        XCTAssertEqual(log.split(separator: "\n").count, 1, "one ffprobe call only")
    }

    /// A stand-in ffprobe for the frame read. It answers the stream listing with `streams`, and on the
    /// frame call returns `frames` only when ffprobe was asked for `V:0`; any other selection is
    /// answered as if the cover were chosen. Each call's arguments go to `args.log`, so a skipped
    /// call is observable.
    private func fakeProbe(streams: String, frames: String) throws -> (probe: URL, directory: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fake-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let streamsFile = dir.appendingPathComponent("streams.json")
        let framesFile = dir.appendingPathComponent("frames.json")
        let script = dir.appendingPathComponent("ffprobe.sh")
        try streams.write(to: streamsFile, atomically: true, encoding: .utf8)
        try frames.write(to: framesFile, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "\(dir.path)/args.log"
        for a in "$@"; do
          if [ "$a" = "-show_frames" ]; then
            case " $* " in
              *" -select_streams V:0 "*) cat "\(framesFile.path)" ;;
              *) echo '{"frames":[{"stream_index":0,"media_type":"video","color_transfer":"bt709"}]}' ;;
            esac
            exit 0
          fi
        done
        cat "\(streamsFile.path)"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, dir)
    }
}
