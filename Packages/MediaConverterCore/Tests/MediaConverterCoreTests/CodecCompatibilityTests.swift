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
            let problem = CodecCompatibility.sourceProblem(
                keepAll(container, video: container == .webm ? .vp9 : .copy), source: source)
            XCTAssertNotNil(problem, "\(container)")
            XCTAssertTrue(problem?.contains("track 2") == true && problem?.contains("PGS") == true, "\(container): \(problem ?? "nil")")
        }
        XCTAssertNil(CodecCompatibility.sourceProblem(keepAll(.mkv), source: source))
    }

    func testTextSubtitlesAreNeverAProblemBecauseTheyAreConverted() {
        let source = MediaInfo(videoCodecName: "h264", audioCodecName: "aac",
                               subtitleLanguages: ["eng", "ger", "fre"], subtitleCodecs: ["subrip", "ass", "mov_text"])
        for container in [Container.mp4, .mov, .m4v, .webm, .mkv] {
            XCTAssertNil(CodecCompatibility.sourceProblem(
                keepAll(container, video: container == .webm ? .vp9 : .copy), source: source), "\(container)")
        }
    }

    func testSubtitlesAreNotMappedWithoutKeepAllSoTheyCannotBlock() {
        var s = keepAll(.mp4)
        s.preserveAllStreams = false
        let source = MediaInfo(videoCodecName: "h264", audioCodecName: "aac",
                               subtitleLanguages: ["eng"], subtitleCodecs: ["hdmv_pgs_subtitle"])
        XCTAssertNil(CodecCompatibility.sourceProblem(s, source: source))
    }

    /// Measured on ffmpeg 9.0.2 (one codec at a time, remuxed): SAMI and DVB teletext are kept by no
    /// muxer; VobSub goes into MP4 and Matroska, DVB subtitles only into Matroska, and the EIA-608
    /// caption track only into MOV. Every cell is checked so a stray change shows up here.
    func testNonTextSubtitleHandlingMatchesTheMeasuredTable() {
        let supported: [String: Set<Container>] = [
            "sami": [],
            "dvd_subtitle": [.mp4, .mkv],
            "dvb_subtitle": [.mkv],
            "eia_608": [.mov],
            "dvb_teletext": [],
        ]
        for (codec, containers) in supported {
            for container in Container.allCases {
                XCTAssertEqual(CodecCompatibility.subtitleHandling(for: codec, in: container),
                               containers.contains(container) ? .copy : .unsupported,
                               "\(codec) into \(container)")
            }
        }
    }

    /// One refused cell per measured codec: the reason names a target that actually works, or says
    /// none does. The old "Use MKV" advice was wrong for EIA-608 (Matroska refuses it).
    func testUnsupportedNonTextSubtitleNamesAWorkingTargetOrNone() {
        func reason(_ codec: String, in container: Container) -> String? {
            let source = MediaInfo(videoCodecName: "h264", audioCodecName: "aac",
                                   subtitleLanguages: ["eng"], subtitleCodecs: [codec])
            return CodecCompatibility.sourceProblem(keepAll(container, video: .h264, audio: .aac),
                                                    source: source)
        }
        func expect(_ codec: String, in container: Container, contains fragments: [String]) -> String {
            let problem = reason(codec, in: container)
            XCTAssertNotNil(problem, "\(codec) into \(container)")
            for fragment in fragments {
                XCTAssertTrue(problem?.contains(fragment) == true, "\(codec) into \(container): \(problem ?? "nil")")
            }
            XCTAssertLessThanOrEqual(problem?.count ?? 0, 85, problem ?? "")
            return problem ?? ""
        }
        XCTAssertTrue(expect("sami", in: .mp4, contains: ["SAMI", "anywhere"]).hasPrefix("Subtitle track 1 (SAMI)"))
        expect("dvd_subtitle", in: .mov, contains: ["VobSub", "MP4 or MKV"])
        XCTAssertNil(reason("dvd_subtitle", in: .mp4))
        expect("dvb_subtitle", in: .mp4, contains: ["DVB_SUBTITLE", "Use MKV"])
        let eia = expect("eia_608", in: .mkv, contains: ["EIA_608", "Use MOV"])
        XCTAssertFalse(eia.contains("Use MKV"), eia)
        expect("dvb_teletext", in: .mkv, contains: ["DVB_TELETEXT", "anywhere"])
        // Every bad cell that has a working target names exactly that target.
        expect("eia_608", in: .mp4, contains: ["Use MOV"])
        expect("dvb_subtitle", in: .mov, contains: ["Use MKV"])
    }

    func testUnknownSubtitleCodecIsStillLeftToFfmpeg() {
        for container in Container.allCases {
            XCTAssertEqual(CodecCompatibility.subtitleHandling(for: "vobsub", in: container), .copy,
                           "\(container)")
        }
        let source = MediaInfo(videoCodecName: "h264", audioCodecName: "aac",
                               subtitleLanguages: ["eng"], subtitleCodecs: ["vobsub"])
        XCTAssertNil(CodecCompatibility.sourceProblem(keepAll(.mp4, video: .h264, audio: .aac), source: source))
    }

    func testUnsupportedNonTextSubtitlesDoNotBlockWithoutKeepAll() {
        for codec in ["sami", "dvd_subtitle", "dvb_subtitle", "eia_608", "dvb_teletext"] {
            let source = MediaInfo(videoCodecName: "h264", audioCodecName: "aac",
                                   subtitleLanguages: ["eng"], subtitleCodecs: [codec])
            var s = keepAll(.mkv, video: .h264, audio: .aac)
            s.preserveAllStreams = false
            XCTAssertNil(CodecCompatibility.sourceProblem(s, source: source), codec)
        }
    }

    /// The GIF command maps no video and drops audio, so an audio-only source leaves ffmpeg with
    /// nothing to write. The preflight catches it for both Keep all values.
    func testGIFSourceWithoutVideoIsBlockedBeforeTheRun() {
        let audioOnly = MediaInfo(audioCodecName: "aac", audioCodecs: ["aac"])
        for preserveAll in [false, true] {
            var s = ConversionSettings(container: .gif, videoCodec: .none, audioCodec: .none, crf: 20)
            s.preserveAllStreams = preserveAll
            XCTAssertTrue(CodecCompatibility.isValidCombo(s), "the combo itself stays valid")
            let problem = CodecCompatibility.sourceProblem(s, source: audioOnly)
            XCTAssertTrue(problem?.contains("GIF") == true && problem?.contains("video") == true,
                          "\(preserveAll): \(problem ?? "nil")")
            XCTAssertLessThanOrEqual(problem?.count ?? 0, 85, problem ?? "")
        }
    }

    func testGIFSourceWithVideoIsNotBlocked() {
        let source = MediaInfo(videoCodecName: "h264", audioCodecName: "aac")
        for preserveAll in [false, true] {
            var s = ConversionSettings(container: .gif, videoCodec: .none, audioCodec: .none, crf: 20)
            s.preserveAllStreams = preserveAll
            XCTAssertNil(CodecCompatibility.sourceProblem(s, source: source), "\(preserveAll)")
        }
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

    func testSettingsThatLeaveNoOutputStreamAreBlockedEvenWithoutKeepAll() {
        let source = MediaInfo(videoCodecName: "h264", audioCodecName: "aac")
        let muted = ConversionSettings(container: .mp4, videoCodec: .none, audioCodec: .none, crf: 23)
        let bothOff = CodecCompatibility.sourceProblem(muted, source: source)
        XCTAssertTrue(bothOff?.contains("turned off") == true, bothOff ?? "nil")
        XCTAssertLessThanOrEqual(bothOff?.count ?? 0, 85)

        // Keep all does not rescue a run with no stream to write.
        var keepAllMuted = muted
        keepAllMuted.preserveAllStreams = true
        XCTAssertNotNil(CodecCompatibility.sourceProblem(keepAllMuted, source: source))

        // Audio off in an audio-only file.
        let audioOnly = MediaInfo(audioCodecName: "aac", audioCodecs: ["aac"])
        let audioOff = ConversionSettings(container: .m4a, videoCodec: .copy, audioCodec: .none, crf: 23)
        let noAudio = CodecCompatibility.sourceProblem(audioOff, source: audioOnly)
        XCTAssertTrue(noAudio?.contains("audio") == true && noAudio?.contains("turned off") == true,
                      noAudio ?? "nil")

        // Video off in a video-only file.
        let videoOnly = MediaInfo(videoCodecName: "h264")
        let videoOff = ConversionSettings(container: .mp4, videoCodec: .none, audioCodec: .copy, crf: 23)
        let noVideo = CodecCompatibility.sourceProblem(videoOff, source: videoOnly)
        XCTAssertTrue(noVideo?.contains("video") == true && noVideo?.contains("turned off") == true,
                      noVideo ?? "nil")
    }

    /// Measured: one remaining stream is enough. ffmpeg writes the audio of an audio-only file
    /// and the video of a video-only file even when the other settings codec has no source.
    func testOneRemainingStreamIsEnoughForAnAbsentOne() {
        let audioOnly = MediaInfo(audioCodecName: "aac", audioCodecs: ["aac"])
        var audioSettings = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 23)
        XCTAssertNil(CodecCompatibility.sourceProblem(audioSettings, source: audioOnly))
        audioSettings.preserveAllStreams = true
        XCTAssertNil(CodecCompatibility.sourceProblem(audioSettings, source: audioOnly))

        let videoOnly = MediaInfo(videoCodecName: "h264")
        var videoSettings = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 23)
        XCTAssertNil(CodecCompatibility.sourceProblem(videoSettings, source: videoOnly))
        videoSettings.preserveAllStreams = true
        XCTAssertNil(CodecCompatibility.sourceProblem(videoSettings, source: videoOnly))
    }

    func testAudioOnlyContainersWithOneTrackOnlyLookAtTheFirstTrack() {
        // MP3, FLAC and WAV hold one audio stream: the builder maps `0:a:0`, so a second track is never copied.
        let source = MediaInfo(audioCodecName: "mp3", audioCodecs: ["mp3", "ac3"])
        XCTAssertNil(CodecCompatibility.sourceProblem(keepAll(.mp3, video: .none, audio: .copy), source: source))
        // M4A takes every track, and refuses E-AC-3.
        let eac3 = MediaInfo(audioCodecName: "aac", audioCodecs: ["aac", "eac3"])
        XCTAssertNotNil(CodecCompatibility.sourceProblem(keepAll(.m4a, video: .none, audio: .aac), source: eac3))
    }

    // MARK: - Copied streams that the container cannot hold

    func testVideoCopyTableFollowsTheMuxers() {
        // Measured on ffmpeg 9.0.2 by remuxing each codec into each container.
        XCTAssertTrue(CodecCompatibility.canCopyVideo("h264", into: .mp4))
        XCTAssertTrue(CodecCompatibility.canCopyVideo("vp9", into: .mp4))
        XCTAssertTrue(CodecCompatibility.canCopyVideo("av1", into: .mp4))
        XCTAssertFalse(CodecCompatibility.canCopyVideo("prores", into: .mp4))
        XCTAssertTrue(CodecCompatibility.canCopyVideo("prores", into: .mov))
        XCTAssertFalse(CodecCompatibility.canCopyVideo("vp9", into: .mov))
        XCTAssertFalse(CodecCompatibility.canCopyVideo("av1", into: .mov))
        XCTAssertTrue(CodecCompatibility.canCopyVideo("h264", into: .m4v))
        XCTAssertFalse(CodecCompatibility.canCopyVideo("hevc", into: .m4v))
        for container in [Container.mkv] {
            for codec in ["h264", "hevc", "av1", "vp8", "vp9", "prores"] {
                XCTAssertTrue(CodecCompatibility.canCopyVideo(codec, into: container), "\(codec) into \(container)")
            }
        }
        for codec in ["vp8", "vp9", "av1"] {
            XCTAssertTrue(CodecCompatibility.canCopyVideo(codec, into: .webm), codec)
        }
        XCTAssertFalse(CodecCompatibility.canCopyVideo("h264", into: .webm))
        // Audio-only targets and GIF carry no video whatever the source.
        for container in [Container.m4a, .mp3, .flac, .wav, .gif] {
            XCTAssertFalse(CodecCompatibility.canCopyVideo("h264", into: container), "\(container)")
        }
    }

    func testACopiedVideoTheContainerCannotHoldBlocksTheFileEvenWithoutKeepAll() {
        let source = MediaInfo(videoCodecName: "vp9", audioCodecName: "opus")
        let keepAllMovement = CodecCompatibility.sourceProblem(keepAll(.mov, video: .copy, audio: .copy), source: source)
        XCTAssertTrue(keepAllMovement?.contains("VP9") == true && keepAllMovement?.contains("MOV") == true,
                      keepAllMovement ?? "nil")
        // ffmpeg maps the source video by default too, so Keep all off does not help.
        let defaultMapping = ConversionSettings(container: .mov, videoCodec: .copy, audioCodec: .none, crf: 20)
        XCTAssertFalse(defaultMapping.preserveAllStreams)
        XCTAssertEqual(CodecCompatibility.sourceProblem(defaultMapping, source: source), keepAllMovement)
        // H.264 copies into MOV, and a source without video has nothing to copy. Keep an audio
        // stream so the setting still produces output (both-off is L7's job).
        XCTAssertNil(CodecCompatibility.sourceProblem(defaultMapping, source: MediaInfo(videoCodecName: "h264")))
        let audioKept = ConversionSettings(container: .mov, videoCodec: .copy, audioCodec: .copy, crf: 20)
        XCTAssertNil(CodecCompatibility.sourceProblem(audioKept, source: MediaInfo(audioCodecName: "aac")))
    }

    func testACopiedAudioTrackTheContainerCannotHoldBlocksTheFileWithoutKeepAll() {
        func problem(_ container: Container, _ codec: String) -> String? {
            let source = MediaInfo(videoCodecName: "h264", audioCodecName: codec, audioCodecs: [codec],
                                   selectedAudioCodec: codec)
            return CodecCompatibility.sourceProblem(
                ConversionSettings(container: container, videoCodec: .none, audioCodec: .copy, crf: 20),
                source: source)
        }
        let webm = problem(.webm, "aac")
        XCTAssertTrue(webm?.contains("AAC") == true && webm?.contains("WEBM") == true, webm ?? "nil")
        let mp3 = problem(.mp3, "aac")
        XCTAssertNotNil(mp3)
        let mov = problem(.mov, "opus")
        XCTAssertTrue(mov?.contains("Opus") == true && mov?.contains("MOV") == true, mov ?? "nil")
        XCTAssertNil(problem(.webm, "opus"))
        XCTAssertNil(problem(.mp4, "aac"))
        for reason in [webm, mp3, mov].compactMap({ $0 }) {
            XCTAssertLessThanOrEqual(reason.count, 85, reason)
        }
    }

    func testTheSelectedAudioTrackIsTheOneCheckedWithoutKeepAll() {
        // The default-flagged AAC is not the first track; ffmpeg copies the selected one.
        let source = MediaInfo(videoCodecName: "h264", audioCodecName: "opus",
                               audioCodecs: ["opus", "aac"], selectedAudioCodec: "aac")
        let webm = ConversionSettings(container: .webm, videoCodec: .vp9, audioCodec: .copy, crf: 20)
        let picked = CodecCompatibility.sourceProblem(webm, source: source)
        XCTAssertTrue(picked?.contains("AAC") == true, picked ?? "nil")
        XCTAssertFalse(picked?.contains("Opus") == true, picked ?? "nil")
        var opusSelected = source
        opusSelected.selectedAudioCodec = "opus"
        XCTAssertNil(CodecCompatibility.sourceProblem(webm, source: opusSelected), "Opus is what WebM wants")
        // Without a parsed selection the first track is the fallback (and is wrong for MOV).
        let mov = ConversionSettings(container: .mov, videoCodec: .h264, audioCodec: .copy, crf: 20)
        var noSelection = source
        noSelection.selectedAudioCodec = nil
        XCTAssertNotNil(CodecCompatibility.sourceProblem(mov, source: noSelection))
        XCTAssertNil(CodecCompatibility.sourceProblem(mov, source: source), "the selected AAC fits MOV")
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
            // ffmpeg's native Vorbis encoder is experimental and stereo only; the table claims WebM takes it.
            ("vorbis", ["-c:a", "vorbis", "-strict", "-2", "-ac", "2"]),
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

    /// The same record for video: every codec the app can copy into every container that takes
    /// video, remuxed from a one-second test pattern.
    func testVideoCopyTableMatchesFfmpeg() throws {
        guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
        let encoders: [(codec: String, args: [String])] = [
            ("h264", ["-c:v", "libx264", "-pix_fmt", "yuv420p"]),
            ("hevc", ["-c:v", "libx265", "-pix_fmt", "yuv420p", "-x265-params", "log-level=none"]),
            ("av1", ["-c:v", "libsvtav1", "-pix_fmt", "yuv420p"]),
            ("vp8", ["-c:v", "libvpx", "-pix_fmt", "yuv420p"]),
            ("vp9", ["-c:v", "libvpx-vp9", "-pix_fmt", "yuv420p"]),
            ("prores", ["-c:v", "prores_ks", "-pix_fmt", "yuv422p10le"]),
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
        var sources: [(codec: String, url: URL)] = []
        defer { sources.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        for encoder in encoders {
            let source = dir.appendingPathComponent("vcopy-\(token)-\(encoder.codec).mkv")
            sources.append((encoder.codec, source))
            _ = try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=128x128:rate=10:duration=1"]
                           + encoder.args + ["-an", source.path])
        }
        // Audio-only targets and GIF deliberately take no video; only the video containers are measured.
        let containers: [Container] = [.mp4, .mov, .m4v, .mkv, .webm]
        let jobs = sources.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .flatMap { source in containers.map { (source, $0) } }
        if jobs.isEmpty { throw XCTSkip("this ffmpeg builds none of the video encoders") }
        var accepted = [Bool](repeating: false, count: jobs.count)
        accepted.withUnsafeMutableBufferPointer { results in
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                let (source, container) = jobs[i]
                let output = dir.appendingPathComponent("vcopy-\(token)-\(i).\(container.fileExtension)")
                defer { try? FileManager.default.removeItem(at: output) }
                results[i] = (try? ffmpeg(["-i", source.url.path, "-map", "0:v:0", "-c:v", "copy", output.path])) ?? false
            }
        }
        for (i, (source, container)) in jobs.enumerated() {
            XCTAssertEqual(CodecCompatibility.canCopyVideo(source.codec, into: container), accepted[i],
                           "\(source.codec) into \(container): ffmpeg \(accepted[i] ? "accepts" : "refuses") it")
        }
    }
}
