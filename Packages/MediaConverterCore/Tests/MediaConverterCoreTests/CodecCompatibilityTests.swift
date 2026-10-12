import XCTest
@testable import MediaConverterCore

final class CodecCompatibilityTests: XCTestCase {

    // MARK: - isValidCombo: valid combos

    func testHevcAACInMP4IsValid() {
        let s = ConversionSettings(container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 28)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s))
    }

    func testVP9OpusInWebMIsValid() {
        let s = ConversionSettings(container: .webm, videoCodec: .vp9, audioCodec: .opus, crf: 31)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s))
    }

    func testAV1OpusInMKVIsValid() {
        let s = ConversionSettings(container: .mkv, videoCodec: .av1, audioCodec: .opus, crf: 30)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s))
    }

    func testCopyNoneInMP4IsValid() {
        let s = ConversionSettings(container: .mp4, videoCodec: .copy, audioCodec: .none, crf: 23)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s))
    }

    func testM4AValidWithAACAndVideoNone() {
        let s = ConversionSettings(container: .m4a, videoCodec: .none, audioCodec: .aac, crf: 23)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s))
    }

    func testMP3ValidWithMP3AndVideoNone() {
        let s = ConversionSettings(container: .mp3, videoCodec: .none, audioCodec: .mp3, crf: 23)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s))
    }

    // MARK: - isValidCombo: invalid combos

    func testH264InWebMIsInvalid() {
        let s = ConversionSettings(container: .webm, videoCodec: .h264, audioCodec: .opus, crf: 23)
        XCTAssertFalse(CodecCompatibility.isValidCombo(s))
    }

    func testVP9InMP4IsValid() {
        // ffmpeg muxes VP9 into MP4; we expose every muxable combo.
        let s = ConversionSettings(container: .mp4, videoCodec: .vp9, audioCodec: .aac, crf: 31)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s))
    }

    func testOpusInMP4IsValid() {
        // ffmpeg muxes Opus into MP4 (unusual but valid) — exposed.
        let s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .opus, crf: 23)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s))
    }

    func testM4AWithVideoH264IsInvalid() {
        let s = ConversionSettings(container: .m4a, videoCodec: .h264, audioCodec: .aac, crf: 23)
        XCTAssertFalse(CodecCompatibility.isValidCombo(s))
    }

    func testOpusInMOVIsInvalid() {
        let s = ConversionSettings(container: .mov, videoCodec: .h264, audioCodec: .opus, crf: 23)
        XCTAssertFalse(CodecCompatibility.isValidCombo(s))
    }

    // MARK: - GIF is always valid

    func testGIFIsAlwaysValidRegardlessOfCodecs() {
        let s1 = ConversionSettings(container: .gif, videoCodec: .h264, audioCodec: .aac, crf: 23)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s1), "gif should be valid even with incompatible codecs")

        let s2 = ConversionSettings(container: .gif, videoCodec: .none, audioCodec: .none, crf: 23)
        XCTAssertTrue(CodecCompatibility.isValidCombo(s2))
    }

    // MARK: - videoCodecs / audioCodecs lists

    func testVideoCodecsForWebMExcludesH264() {
        let codecs = CodecCompatibility.videoCodecs(for: .webm)
        XCTAssertTrue(codecs.contains(.vp9))
        XCTAssertTrue(codecs.contains(.av1))
        XCTAssertFalse(codecs.contains(.h264))
        XCTAssertFalse(codecs.contains(.hevc))
    }

    func testAudioCodecsForWebMExcludesAAC() {
        let codecs = CodecCompatibility.audioCodecs(for: .webm)
        XCTAssertTrue(codecs.contains(.opus))
        XCTAssertFalse(codecs.contains(.aac))
        XCTAssertFalse(codecs.contains(.alac))
    }

    func testVideoCodecsForGIFIsNoneOnly() {
        XCTAssertEqual(CodecCompatibility.videoCodecs(for: .gif), [.none])
    }

    func testAudioCodecsForGIFIsNoneOnly() {
        XCTAssertEqual(CodecCompatibility.audioCodecs(for: .gif), [.none])
    }

    func testMKVIncludesOpusAudio() {
        XCTAssertTrue(CodecCompatibility.audioCodecs(for: .mkv).contains(.opus))
    }

    func testMP4IncludesAV1Video() {
        XCTAssertTrue(CodecCompatibility.videoCodecs(for: .mp4).contains(.av1))
    }

    // MARK: - New formats (ProRes / FLAC / WAV / AC-3)

    func testProResValidInMOVandMKVNotMP4() {
        XCTAssertTrue(CodecCompatibility.videoCodecs(for: .mov).contains(.prores))
        XCTAssertTrue(CodecCompatibility.videoCodecs(for: .mkv).contains(.prores))
        XCTAssertFalse(CodecCompatibility.videoCodecs(for: .mp4).contains(.prores))
    }

    func testFLACContainerAcceptsFLACAudioOnly() {
        XCTAssertEqual(CodecCompatibility.videoCodecs(for: .flac), [.none])
        XCTAssertTrue(CodecCompatibility.audioCodecs(for: .flac).contains(.flac))
        XCTAssertTrue(CodecCompatibility.isValidCombo(
            ConversionSettings(container: .flac, videoCodec: .none, audioCodec: .flac, crf: 20)))
    }

    func testWAVContainerAcceptsPCMAudioOnly() {
        XCTAssertEqual(CodecCompatibility.videoCodecs(for: .wav), [.none])
        XCTAssertTrue(CodecCompatibility.audioCodecs(for: .wav).contains(.pcm))
        XCTAssertTrue(CodecCompatibility.isValidCombo(
            ConversionSettings(container: .wav, videoCodec: .none, audioCodec: .pcm, crf: 20)))
    }

    func testAC3andEAC3ValidInMP4AndMKV() {
        XCTAssertTrue(CodecCompatibility.audioCodecs(for: .mp4).contains(.ac3))
        XCTAssertTrue(CodecCompatibility.audioCodecs(for: .mkv).contains(.eac3))
    }

    func testPCMValidInMP4MOVandMKV() {
        XCTAssertTrue(CodecCompatibility.audioCodecs(for: .mp4).contains(.pcm))
        XCTAssertTrue(CodecCompatibility.audioCodecs(for: .mov).contains(.pcm))
        XCTAssertTrue(CodecCompatibility.audioCodecs(for: .mkv).contains(.pcm))
    }

    func testMP4ExposesAllMuxableCodecs() {
        // After un-hiding: ffmpeg muxes these into MP4, so they're offered.
        XCTAssertTrue(CodecCompatibility.videoCodecs(for: .mp4).contains(.vp9))
        let a = CodecCompatibility.audioCodecs(for: .mp4)
        XCTAssertTrue(a.contains(.opus))
        XCTAssertTrue(a.contains(.flac))
        XCTAssertTrue(a.contains(.pcm))
    }

    func testM4VIsIPodMuxerRestricted() {
        // .m4v uses ffmpeg's ipod muxer: H.264 video only; AAC/ALAC/AC-3 audio.
        // Verified empirically — HEVC and MP3 are rejected by that container.
        let v = CodecCompatibility.videoCodecs(for: .m4v)
        XCTAssertTrue(v.contains(.h264))
        XCTAssertFalse(v.contains(.hevc), "ipod muxer rejects HEVC in .m4v")
        let a = CodecCompatibility.audioCodecs(for: .m4v)
        XCTAssertTrue(a.contains(.aac))
        XCTAssertTrue(a.contains(.alac))
        XCTAssertTrue(a.contains(.ac3))
        XCTAssertFalse(a.contains(.mp3), "ipod muxer rejects MP3 in .m4v")
    }

    func testChannelOptionsMatchEncoderLimits() {
        // Measured against ffmpeg 9.0.1; see CodecCompatibility.channelOptions.
        XCTAssertEqual(CodecCompatibility.channelOptions(for: .mp3), [.source, .mono, .stereo])
        XCTAssertFalse(CodecCompatibility.channelOptions(for: .eac3).contains(.surround71))
        XCTAssertFalse(CodecCompatibility.channelOptions(for: .ac3).contains(.surround71))
        XCTAssertFalse(CodecCompatibility.channelOptions(for: .alac).contains(.surround71))
        XCTAssertTrue(CodecCompatibility.channelOptions(for: .eac3).contains(.surround51))
        XCTAssertTrue(CodecCompatibility.channelOptions(for: .flac).contains(.surround71))
        XCTAssertTrue(CodecCompatibility.channelOptions(for: .aac).contains(.surround71))
        XCTAssertEqual(CodecCompatibility.channelOptions(for: .copy), [.source])
    }

    func testEAC3With71IsRejectedAsInvalidCombo() {
        // Regression: ffmpeg aborts with "Specified channel layout '7.1' is not
        // supported by the eac3 encoder", so the combo must not be valid.
        var s = ConversionSettings(container: .mkv, videoCodec: .copy, audioCodec: .eac3,
                                   crf: 20, audioBitrate: .kbps(1536))
        s.channels = .surround71
        XCTAssertFalse(CodecCompatibility.isValidCombo(s))
        s.channels = .surround51
        XCTAssertTrue(CodecCompatibility.isValidCombo(s))
    }

    func testFLAC71IsValid() {
        var s = ConversionSettings(container: .mkv, videoCodec: .copy, audioCodec: .flac, crf: 20)
        s.channels = .surround71
        XCTAssertTrue(CodecCompatibility.isValidCombo(s))
    }

    func testBitrateCeilingFollowsTheChannelLayout() {
        // Measured against ffmpeg 9.0.2 (the engine tests run the same limits through ffmpeg):
        // libopus takes 256 kbps per channel, mp3 and ac3 clamp at 320/640 whatever the layout.
        func valid(_ codec: AudioCodec, _ channels: AudioChannels, _ kbps: Int,
                   container: Container = .mkv) -> Bool {
            var s = ConversionSettings(container: container, videoCodec: container.isAudioOnly ? .none : .copy,
                                       audioCodec: codec, crf: 20, audioBitrate: .kbps(kbps))
            s.channels = channels
            return CodecCompatibility.isValidCombo(s)
        }
        XCTAssertTrue(valid(.opus, .mono, 256));        XCTAssertFalse(valid(.opus, .mono, 320))
        XCTAssertTrue(valid(.opus, .stereo, 512));      XCTAssertFalse(valid(.opus, .stereo, 640))
        XCTAssertTrue(valid(.opus, .surround51, 1536)); XCTAssertTrue(valid(.opus, .surround71, 1536))
        // "Same as source" is not known until a file is probed and a batch can mix layouts, so the
        // settings stay permissive (the widest ceiling); ArgumentBuilder lowers each file's request.
        XCTAssertTrue(valid(.opus, .source, 1536));     XCTAssertTrue(valid(.aac, .source, 1536))
        XCTAssertFalse(valid(.mp3, .source, 384, container: .mp3)); XCTAssertFalse(valid(.ac3, .source, 768))
        // AAC never fails; up to stereo it keeps the old 640, the 768+ presets are for surround.
        XCTAssertTrue(valid(.aac, .stereo, 640));       XCTAssertFalse(valid(.aac, .stereo, 768))
        XCTAssertTrue(valid(.aac, .surround51, 1024));  XCTAssertTrue(valid(.aac, .surround71, 1536))
        XCTAssertTrue(valid(.mp3, .stereo, 320, container: .mp3))
        XCTAssertFalse(valid(.mp3, .stereo, 384, container: .mp3))
        XCTAssertTrue(valid(.ac3, .surround51, 640));   XCTAssertFalse(valid(.ac3, .surround51, 768))
        for layout in [AudioChannels.mono, .stereo, .surround51] {
            XCTAssertTrue(valid(.eac3, layout, 1536), "eac3 honours 1536 on every layout it accepts")
        }
        // Codecs that take no bitrate ignore it, so a leftover pick must not invalidate them.
        XCTAssertTrue(valid(.copy, .source, 1536))
        XCTAssertTrue(valid(.flac, .stereo, 1536))
        // `Auto` is always valid.
        var auto = ConversionSettings(container: .mkv, videoCodec: .copy, audioCodec: .opus, crf: 20)
        auto.channels = .mono
        XCTAssertEqual(auto.audioBitrate, .auto)
        XCTAssertTrue(CodecCompatibility.isValidCombo(auto))
    }

    func testBitrateOptionsFollowTheLayout() {
        func kbps(_ codec: AudioCodec, _ channels: AudioChannels) -> [Int] {
            CodecCompatibility.audioBitrateOptions(for: codec, channels: channels)
                .compactMap { if case .kbps(let k) = $0 { return k } else { return nil } }
        }
        XCTAssertEqual(CodecCompatibility.audioBitrateOptions(for: .opus, channels: .mono).first, .auto)
        XCTAssertEqual(kbps(.opus, .mono).last, 256)
        XCTAssertEqual(kbps(.opus, .stereo).last, 512)
        XCTAssertEqual(kbps(.opus, .surround51).last, 1536)
        XCTAssertEqual(kbps(.aac, .stereo).last, 640)
        XCTAssertEqual(kbps(.aac, .surround71).last, 1536)
        XCTAssertEqual(kbps(.mp3, .stereo).last, 320)
        XCTAssertEqual(kbps(.ac3, .surround51).last, 640)
        XCTAssertEqual(kbps(.eac3, .mono).last, 1536, "E-AC-3 is the codec the 768-1536 presets exist for")
        // A codec without a bitrate keeps the whole list.
        XCTAssertEqual(CodecCompatibility.audioBitrateOptions(for: .flac, channels: .stereo), AudioBitrate.presets)
    }

    // MARK: - Per-file problems the codec lists cannot see

    private func keepAll(_ container: Container, video: VideoCodec = .copy, audio: AudioCodec = .copy) -> ConversionSettings {
        var s = ConversionSettings(container: container, videoCodec: video, audioCodec: audio, crf: 20)
        s.preserveAllStreams = true
        return s
    }

    /// Bitmap subtitles cannot become text, and only Matroska keeps PGS (measured on ffmpeg 9.0.2:
    /// MP4, MOV, M4V and WebM abort with "codec not currently supported in container").
    func testPGSSubtitlesBlockEveryContainerButMatroska() {
        let source = MediaInfo(videoCodecName: "h264", audioCodecName: "aac",
                               subtitleLanguages: ["eng", "ger"], subtitleCodecs: ["subrip", "hdmv_pgs_subtitle"])
        for container in [Container.mp4, .mov, .m4v, .webm] {
            let problem = CodecCompatibility.sourceProblem(keepAll(container), source: source)
            XCTAssertNotNil(problem, "\(container)")
            XCTAssertTrue(problem?.contains("track 2") == true && problem?.contains("PGS") == true, "\(container): \(problem ?? "nil")")
        }
        XCTAssertNil(CodecCompatibility.sourceProblem(keepAll(.mkv), source: source))
    }

    func testTextSubtitlesAreNeverAProblemBecauseTheyAreConverted() {
        let source = MediaInfo(videoCodecName: "h264", audioCodecName: "aac",
                               subtitleLanguages: ["eng", "ger", "fre"], subtitleCodecs: ["subrip", "ass", "mov_text"])
        for container in [Container.mp4, .mov, .m4v, .webm, .mkv] {
            XCTAssertNil(CodecCompatibility.sourceProblem(keepAll(container), source: source), "\(container)")
        }
    }

    func testSubtitlesAreNotMappedWithoutKeepAllSoTheyCannotBlock() {
        var s = keepAll(.mp4)
        s.preserveAllStreams = false
        let source = MediaInfo(videoCodecName: "h264", audioCodecName: "aac",
                               subtitleLanguages: ["eng"], subtitleCodecs: ["hdmv_pgs_subtitle"])
        XCTAssertNil(CodecCompatibility.sourceProblem(s, source: source))
    }

    /// The file row shows a reason in two lines of 240 pt of caption text and cuts the rest: the
    /// first version of these messages lost "...turn off Keep all tracks" at about 95 characters,
    /// which is the part that says what to do. Keep every one well under that.
    func testEveryPerFileReasonFitsTheTwoLineRow() {
        let source = MediaInfo(videoCodecName: "h264", audioCodecName: "truehd",
                               audioCodecs: ["truehd", "eac3", "flac", "opus", "ac3", "dts"],
                               subtitleLanguages: ["eng"], subtitleCodecs: ["hdmv_pgs_subtitle"])
        var withoutSubtitles = source
        withoutSubtitles.subtitleCodecs = []
        var messages: [String] = []
        for container in Container.allCases where container != .gif {
            for audio in [AudioCodec.copy, .aac] {
                let s = keepAll(container, video: .copy, audio: audio)
                // One run reaches the subtitle reason, the other the audio one.
                messages.append(CodecCompatibility.sourceProblem(s, source: source) ?? "")
                messages.append(CodecCompatibility.sourceProblem(s, source: withoutSubtitles) ?? "")
            }
        }
        let reasons = messages.filter { !$0.isEmpty }
        XCTAssertGreaterThan(reasons.count, 10, "the matrix must actually produce reasons")
        for reason in reasons {
            XCTAssertLessThanOrEqual(reason.count, 85, reason)
        }
    }

    func testAnExtraAudioTrackTheContainerCannotHoldBlocksTheFile() {
        // Only the first track is re-encoded; the others are copied as they are.
        let source = MediaInfo(videoCodecName: "h264", audioCodecName: "aac", audioCodecs: ["aac", "ac3"])
        let webm = CodecCompatibility.sourceProblem(keepAll(.webm, video: .vp9, audio: .opus), source: source)
        XCTAssertTrue(webm?.contains("track 2") == true && webm?.contains("AC-3") == true && webm?.contains("WEBM") == true,
                      webm ?? "nil")
        // MP4 and MKV hold AC-3; M4V (the `ipod` muxer) refuses E-AC-3.
        XCTAssertNil(CodecCompatibility.sourceProblem(keepAll(.mp4, video: .h264, audio: .aac), source: source))
        XCTAssertNil(CodecCompatibility.sourceProblem(keepAll(.mkv, video: .h264, audio: .aac), source: source))
        let eac3 = MediaInfo(videoCodecName: "h264", audioCodecName: "aac", audioCodecs: ["aac", "eac3"])
        XCTAssertNotNil(CodecCompatibility.sourceProblem(keepAll(.m4v, video: .h264, audio: .aac), source: eac3))
    }

    func testTheReEncodedFirstAudioTrackNeverBlocks() {
        // TrueHD cannot go into MP4, but track 1 is turned into AAC; track 2 (AAC) is fine.
        let source = MediaInfo(videoCodecName: "h264", audioCodecName: "truehd", audioCodecs: ["truehd", "aac"])
        XCTAssertNil(CodecCompatibility.sourceProblem(keepAll(.mp4, video: .h264, audio: .aac), source: source))
        // Copied instead, it is the problem, and turning Keep all off would not help: say so.
        let copied = CodecCompatibility.sourceProblem(keepAll(.mp4, video: .h264, audio: .copy), source: source)
        XCTAssertTrue(copied?.contains("track 1") == true && copied?.contains("TrueHD") == true, copied ?? "nil")
        XCTAssertFalse(copied?.contains("turn off") == true, copied ?? "nil")
    }

    func testNoAudioMeansNoAudioProblem() {
        let source = MediaInfo(videoCodecName: "h264", audioCodecName: "ac3", audioCodecs: ["ac3", "ac3"])
        XCTAssertNil(CodecCompatibility.sourceProblem(keepAll(.webm, video: .vp9, audio: .none), source: source))
    }

    func testAudioOnlyContainersWithOneTrackOnlyLookAtTheFirstTrack() {
        // MP3, FLAC and WAV hold one audio stream: the builder maps `0:a:0`, so a second track is never copied.
        let source = MediaInfo(audioCodecName: "mp3", audioCodecs: ["mp3", "ac3"])
        XCTAssertNil(CodecCompatibility.sourceProblem(keepAll(.mp3, video: .none, audio: .copy), source: source))
        // M4A takes every track, and refuses E-AC-3.
        let eac3 = MediaInfo(audioCodecName: "aac", audioCodecs: ["aac", "eac3"])
        XCTAssertNotNil(CodecCompatibility.sourceProblem(keepAll(.m4a, video: .none, audio: .aac), source: eac3))
    }

    /// The copy table is a record of what ffmpeg does, so it is checked against ffmpeg: every
    /// codec into every container, stream copy of a one-second sine. Any ffmpeg release that starts
    /// to accept (or refuse) a pair fails here instead of in front of a user.
    func testAudioCopyTableMatchesFfmpeg() throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        let encoders: [(codec: String, args: [String])] = [
            ("aac", ["-c:a", "aac"]), ("ac3", ["-c:a", "ac3"]), ("eac3", ["-c:a", "eac3"]),
            ("alac", ["-c:a", "alac"]), ("flac", ["-c:a", "flac"]), ("mp3", ["-c:a", "libmp3lame"]),
            ("opus", ["-c:a", "libopus"]), ("pcm_s16le", ["-c:a", "pcm_s16le"]), ("mp2", ["-c:a", "mp2"]),
            ("dts", ["-c:a", "dca", "-strict", "-2"]), ("truehd", ["-c:a", "truehd", "-strict", "-2", "-ar", "48000"]),
        ]
        func ffmpeg(_ args: [String]) throws -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tools.ffmpeg)
            p.arguments = ["-hide_banner", "-loglevel", "quiet", "-y"] + args
            try p.run(); p.waitUntilExit()
            return p.terminationStatus == 0
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let token = UUID().uuidString
        // One source per codec, then every (codec, container) copy attempt in parallel: each is a
        // separate ffmpeg process and there are about a hundred of them.
        var sources: [(codec: String, url: URL)] = []
        defer { sources.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        for encoder in encoders {
            let source = dir.appendingPathComponent("copy-\(token)-\(encoder.codec).mkv")
            sources.append((encoder.codec, source))
            // A codec this ffmpeg cannot encode produces no file and is skipped below.
            _ = try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=1"] + encoder.args + [source.path])
        }
        let jobs = sources.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .flatMap { source in Container.allCases.filter { $0 != .gif }.map { (source, $0) } }
        if jobs.isEmpty { throw XCTSkip("this ffmpeg builds none of the audio encoders") }
        var accepted = [Bool](repeating: false, count: jobs.count)
        accepted.withUnsafeMutableBufferPointer { results in
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                let (source, container) = jobs[i]
                let output = dir.appendingPathComponent("copy-\(token)-\(i).\(container.fileExtension)")
                defer { try? FileManager.default.removeItem(at: output) }
                results[i] = (try? ffmpeg(["-i", source.url.path, "-map", "0:a:0", "-c:a", "copy", output.path])) ?? false
            }
        }
        for (i, (source, container)) in jobs.enumerated() {
            XCTAssertEqual(CodecCompatibility.canCopyAudio(source.codec, into: container), accepted[i],
                           "\(source.codec) into \(container): ffmpeg \(accepted[i] ? "accepts" : "refuses") it")
        }
    }
}
