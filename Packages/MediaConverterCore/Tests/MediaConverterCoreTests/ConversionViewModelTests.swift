import XCTest
@testable import MediaConverterCore

@MainActor
final class ConversionViewModelTests: XCTestCase {
    final class FakeEngine: ConversionEngineProtocol {
        var convertCount = 0
        func convert(input: URL, output: URL, settings: ConversionSettings, source: MediaInfo,
                     onProgress: @escaping (Double) -> Void) async throws {
            convertCount += 1
            onProgress(1.0)
        }
        func cancel() {}
    }

    /// Engine that calls an optional hook on its first convert invocation,
    /// then completes normally. nonisolated(unsafe) properties are safe
    /// here because tests call convertAll() sequentially from @MainActor.
    final class CancellingFakeEngine: ConversionEngineProtocol {
        nonisolated(unsafe) var convertCount = 0
        /// Hook is set once from @MainActor before convertAll() runs.
        /// It is always invoked via MainActor.run to stay on the main actor.
        nonisolated(unsafe) var onFirstConvert: (@MainActor () -> Void)?

        func convert(input: URL, output: URL, settings: ConversionSettings, source: MediaInfo,
                     onProgress: @escaping (Double) -> Void) async throws {
            convertCount += 1
            if convertCount == 1, let hook = onFirstConvert {
                await MainActor.run { hook() }
            }
            onProgress(1.0)
        }
        func cancel() {}
    }

    func testLoadThenConvertAll() async {
        let engine = FakeEngine()
        let vm = ConversionViewModel(
            engine: engine,
            probe: { _ in MediaInfo(durationSeconds: 5, videoCodecName: "h264", audioCodecName: "aac") },
            toolsAvailable: true,
            fileExists: { _ in false })

        await vm.loadFiles([URL(fileURLWithPath: "/a.mov"), URL(fileURLWithPath: "/b.mov")])
        XCTAssertEqual(vm.items.count, 2)
        XCTAssertEqual(vm.items.first?.status, .ready)

        await vm.convertAll()
        XCTAssertEqual(engine.convertCount, 2)
        for item in vm.items {
            guard case .done = item.status else { return XCTFail("expected done, got \(item.status)") }
        }
    }

    func testClearAllDuringSuccessfulProbeKeepsFilesRemoved() async {
        var duringProbe: (() -> Void)?
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { _ in
                duringProbe?()
                return MediaInfo(durationSeconds: 5, videoCodecName: "h264", audioCodecName: "aac")
            },
            toolsAvailable: true)
        duringProbe = { [weak vm] in vm?.clearAll() }

        await vm.loadFiles([URL(fileURLWithPath: "/a.mov")])

        XCTAssertEqual(vm.items, [])
    }

    func testClearAllDuringFailedProbeKeepsFilesRemoved() async {
        var duringProbe: (() -> Void)?
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { _ in
                duringProbe?()
                throw NSError(domain: "probe", code: 1)
            },
            toolsAvailable: true)
        duringProbe = { [weak vm] in vm?.clearAll() }

        await vm.loadFiles([URL(fileURLWithPath: "/a.mov")])

        XCTAssertEqual(vm.items, [])
    }

    func testRemovingEarlierFileDuringProbeUpdatesRemainingFile() async {
        var duringProbe: (() -> Void)?
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { url in
                duringProbe?()
                return MediaInfo(durationSeconds: url.path == "/a.mov" ? 5 : 10)
            },
            toolsAvailable: true)
        await vm.loadFiles([URL(fileURLWithPath: "/a.mov")])
        let removedID = vm.items[0].id
        duringProbe = { [weak vm] in vm?.removeItem(id: removedID) }

        await vm.loadFiles([URL(fileURLWithPath: "/b.mov")])

        XCTAssertEqual(vm.items.map(\.url.path), ["/b.mov"])
        XCTAssertEqual(vm.items.first?.info?.durationSeconds, 10)
        XCTAssertEqual(vm.items.first?.status, .ready)
    }

    func testRemovedProbeDoesNotOverwriteReplacementFile() async {
        var duringProbe: ((URL) async -> Void)?
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { url in
                await duringProbe?(url)
                return MediaInfo(durationSeconds: url.path == "/a.mov" ? 5 : 10)
            },
            toolsAvailable: true)
        duringProbe = { [weak vm] url in
            guard url.path == "/a.mov", let vm = vm else { return }
            vm.removeItem(id: vm.items[0].id)
            await vm.loadFiles([URL(fileURLWithPath: "/b.mov")])
        }

        await vm.loadFiles([URL(fileURLWithPath: "/a.mov")])

        XCTAssertEqual(vm.items.map(\.url.path), ["/b.mov"])
        XCTAssertEqual(vm.items.first?.info?.durationSeconds, 10)
        XCTAssertEqual(vm.items.first?.status, .ready)
    }

    func testCompatibilityUsesFirstItem() async {
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { _ in MediaInfo(videoCodecName: "h264", audioCodecName: "aac") },
            toolsAvailable: true,
            fileExists: { _ in false })
        vm.settings = ConversionSettings(container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 28)
        await vm.loadFiles([URL(fileURLWithPath: "/a.mov")])
        XCTAssertTrue(vm.compatibility.isCompatible)
    }

    // MARK: - Codec compatibility pre-flight

    /// An invalid codec/container combo must set status to .failed and NOT invoke the engine.
    func testInvalidComboSkipsEngineAndFails() async {
        let engine = FakeEngine()
        let vm = ConversionViewModel(
            engine: engine,
            probe: { _ in MediaInfo(durationSeconds: 5, videoCodecName: "h264", audioCodecName: "aac") },
            toolsAvailable: true,
            fileExists: { _ in false })

        await vm.loadFiles([URL(fileURLWithPath: "/a.mp4")])
        // h264 is not valid for webm (only VP9/AV1) — still invalid after un-hiding MP4 combos
        vm.settings = ConversionSettings(container: .webm, videoCodec: .h264, audioCodec: .opus, crf: 23)

        await vm.convertAll()

        XCTAssertEqual(engine.convertCount, 0, "engine must not be called for invalid combo")
        guard case .failed(let msg) = vm.items[0].status else {
            return XCTFail("expected .failed, got \(vm.items[0].status)")
        }
        XCTAssertTrue(msg.contains("supported"), "failure message should mention 'supported'; got: \(msg)")
    }

    // MARK: - containerChanged / videoCodecChanged

    /// Switching to webm must reset h264→vp9 (first valid video), aac→opus (first valid audio),
    /// and CRF to the new codec's default (vp9.defaultCRF) because the codec changed.
    func testContainerChangedToWebMResetsCodecs() {
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { _ in MediaInfo() },
            toolsAvailable: true,
            fileExists: { _ in false })
        // Start with mp4 settings (h264 / aac)
        vm.settings = ConversionSettings(container: .webm, videoCodec: .h264, audioCodec: .aac, crf: 23)
        vm.containerChanged()
        XCTAssertEqual(vm.settings.videoCodec, .vp9, "h264 is invalid for webm; should reset to vp9")
        XCTAssertEqual(vm.settings.audioCodec, .opus, "aac is invalid for webm; should reset to opus")
        XCTAssertEqual(vm.settings.crf, VideoCodec.vp9.defaultCRF,
                       "CRF must reset to new codec's default when video codec changes")
    }

    /// Regression: switching to a container where the current video codec remains valid
    /// must NOT reset the user's custom CRF. mp4→mkv with h264 is such a case.
    func testContainerChangedPreservesCRFWhenCodecStaysValid() {
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { _ in MediaInfo() },
            toolsAvailable: true,
            fileExists: { _ in false })
        // Custom CRF of 18 (not the h264 default of 23) set under mp4/h264.
        vm.settings = ConversionSettings(container: .mkv, videoCodec: .h264, audioCodec: .aac, crf: 18)
        vm.containerChanged()
        XCTAssertEqual(vm.settings.videoCodec, .h264,
                       "h264 is valid for mkv; codec must not change")
        XCTAssertEqual(vm.settings.crf, 18,
                       "CRF must not reset when the video codec stays valid after a container switch")
    }

    func testVideoCodecChangeClearsHardwareWhenUnsupported() {
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { _ in MediaInfo() },
            toolsAvailable: true,
            fileExists: { _ in false })
        vm.settings.videoCodec = .hevc
        vm.settings.useHardware = true
        vm.settings.videoCodec = .av1
        vm.videoCodecChanged()
        XCTAssertFalse(vm.settings.useHardware, "AV1 has no hardware encoder")

        vm.settings.videoCodec = .hevc
        vm.settings.useHardware = true
        vm.videoCodecChanged()
        XCTAssertTrue(vm.settings.useHardware, "HEVC has a hardware encoder; flag preserved")
    }

    /// videoCodecChanged() must set crf to the codec's defaultCRF.
    func testVideoCodecChangedResetsCRF() {
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { _ in MediaInfo() },
            toolsAvailable: true,
            fileExists: { _ in false })
        vm.settings = ConversionSettings(container: .mp4, videoCodec: .av1, audioCodec: .aac, crf: 5)
        vm.videoCodecChanged()
        XCTAssertEqual(vm.settings.crf, VideoCodec.av1.defaultCRF)
    }

    /// videoCodecChanged() on a codec with a narrower crfRange must clamp an out-of-range value.
    func testVideoCodecChangedClampsCRFToRange() {
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { _ in MediaInfo() },
            toolsAvailable: true,
            fileExists: { _ in false })
        // Simulate: was av1 (CRF up to 63), switch to h264 (CRF up to 51).
        // After videoCodecChanged(), crf must equal h264.defaultCRF (23).
        vm.settings = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 60)
        vm.videoCodecChanged()
        let range = VideoCodec.h264.crfRange
        XCTAssertTrue(range.contains(vm.settings.crf), "CRF \(vm.settings.crf) out of range \(range)")
        XCTAssertEqual(vm.settings.crf, VideoCodec.h264.defaultCRF)
    }

    /// Regression: cancel() during the first item must stop the whole batch.
    /// The engine's hook fires on the first convert call and triggers vm.cancel();
    /// subsequent items must never reach the engine (convertCount stays at 1)
    /// and must remain in .ready state since the loop broke before starting them.
    func testCancelStopsBatch() async {
        let engine = CancellingFakeEngine()
        let vm = ConversionViewModel(
            engine: engine,
            probe: { _ in MediaInfo(durationSeconds: 5, videoCodecName: "h264", audioCodecName: "aac") },
            toolsAvailable: true,
            fileExists: { _ in false })

        engine.onFirstConvert = { vm.cancel() }

        await vm.loadFiles([
            URL(fileURLWithPath: "/a.mov"),
            URL(fileURLWithPath: "/b.mov"),
            URL(fileURLWithPath: "/c.mov")
        ])
        XCTAssertEqual(vm.items.count, 3)

        await vm.convertAll()

        XCTAssertEqual(engine.convertCount, 1, "engine should be invoked only for the first item")
        XCTAssertEqual(vm.items[1].status, .ready, "second item should remain .ready — loop must have broken")
        XCTAssertEqual(vm.items[2].status, .ready, "third item should remain .ready — loop must have broken")
    }

    /// Regression (found in manual QA): after a successful conversion an item is .done.
    /// Pressing Convert again — e.g. after changing the codec — must re-run the conversion,
    /// not silently no-op. convertAll() previously only processed .ready items.
    func testConvertAllRerunsAfterDone() async {
        let engine = FakeEngine()
        let vm = ConversionViewModel(
            engine: engine,
            probe: { _ in MediaInfo(durationSeconds: 5, videoCodecName: "h264", audioCodecName: "aac") },
            toolsAvailable: true,
            fileExists: { _ in false })

        await vm.loadFiles([URL(fileURLWithPath: "/a.mov")])
        await vm.convertAll()
        XCTAssertEqual(engine.convertCount, 1)
        guard case .done = vm.items[0].status else { return XCTFail("expected .done after first convert") }

        // User changes the codec and presses Convert again — must re-run, not no-op.
        vm.settings.videoCodec = .hevc
        await vm.convertAll()
        XCTAssertEqual(engine.convertCount, 2, "second Convert must re-run, not no-op on .done items")
        guard case .done = vm.items[0].status else { return XCTFail("expected .done after second convert") }
    }

    // MARK: - Source-aware default audio codec

    func testRecommendedAudioCodec() {
        XCTAssertEqual(ConversionSettings.recommendedAudioCodec(forSource: MediaInfo(audioCodecName: "aac")), .copy)
        XCTAssertEqual(ConversionSettings.recommendedAudioCodec(forSource: MediaInfo(audioCodecName: "mp3")), .aac)
        XCTAssertEqual(ConversionSettings.recommendedAudioCodec(forSource: MediaInfo(audioCodecName: nil)), .aac)
    }

    func testFreshLoadSetsAudioDefaultFromSource() async {
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { _ in MediaInfo(durationSeconds: 5, videoCodecName: "h264", audioCodecName: "aac") },
            toolsAvailable: true, fileExists: { _ in false })
        XCTAssertEqual(vm.settings.audioCodec, .aac)            // static default before load
        await vm.loadFiles([URL(fileURLWithPath: "/a.mov")])
        XCTAssertEqual(vm.settings.audioCodec, .copy)           // source is aac → Copy on fresh load
    }

    func testSecondLoadDoesNotOverrideAudio() async {
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { _ in MediaInfo(durationSeconds: 5, videoCodecName: "h264", audioCodecName: "aac") },
            toolsAvailable: true, fileExists: { _ in false })
        await vm.loadFiles([URL(fileURLWithPath: "/a.mov")])    // → .copy
        vm.settings.audioCodec = .mp3                            // user override
        await vm.loadFiles([URL(fileURLWithPath: "/b.mov")])    // not a fresh load
        XCTAssertEqual(vm.settings.audioCodec, .mp3, "subsequent loads must not override the user's audio choice")
    }

    func testFreshLoadUsesFirstProbedSourceWhenFirstFileFails() async {
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { url in
                if url.lastPathComponent == "bad.mov" { throw NSError(domain: "test", code: 1) }
                return MediaInfo(durationSeconds: 5, videoCodecName: "h264", audioCodecName: "aac")
            },
            toolsAvailable: true, fileExists: { _ in false })
        await vm.loadFiles([URL(fileURLWithPath: "/bad.mov"), URL(fileURLWithPath: "/good.mov")])
        XCTAssertEqual(vm.settings.audioCodec, .copy)
    }

    // MARK: - Removing files

    func testRemoveItemAndClearAll() async {
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { _ in MediaInfo(durationSeconds: 5, videoCodecName: "h264", audioCodecName: "aac") },
            toolsAvailable: true, fileExists: { _ in false })
        await vm.loadFiles([URL(fileURLWithPath: "/a.mov"),
                            URL(fileURLWithPath: "/b.mov"),
                            URL(fileURLWithPath: "/c.mov")])
        XCTAssertEqual(vm.items.count, 3)

        let middle = vm.items[1].id
        vm.removeItem(id: middle)
        XCTAssertEqual(vm.items.count, 2)
        XCTAssertFalse(vm.items.contains { $0.id == middle })

        vm.clearAll()
        XCTAssertTrue(vm.items.isEmpty)
    }
    func testAudioCodecChangeClampsChannelsDownFrom71() {
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { _ in MediaInfo(durationSeconds: 5, videoCodecName: "hevc", audioCodecName: "truehd") },
            toolsAvailable: true,
            fileExists: { _ in false })
        vm.settings.container = .mkv
        vm.settings.audioCodec = .flac
        vm.settings.channels = .surround71
        vm.settings.audioCodec = .eac3
        vm.audioCodecChanged()
        XCTAssertEqual(vm.settings.channels, .surround51,
                       "7.1 must clamp to 5.1 when switching to an encoder that caps there")
    }

    func testAudioCodecChangeLeavesValidChannelsAlone() {
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { _ in MediaInfo(durationSeconds: 5, videoCodecName: "hevc", audioCodecName: "truehd") },
            toolsAvailable: true,
            fileExists: { _ in false })
        vm.settings.container = .mkv
        vm.settings.audioCodec = .eac3
        vm.settings.channels = .stereo
        vm.audioCodecChanged()
        XCTAssertEqual(vm.settings.channels, .stereo)
    }

    // MARK: - HDR auto-detection

    func testLoadingHDRSourceEnablesToneMap() async {
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { _ in MediaInfo(durationSeconds: 5, videoCodecName: "hevc", audioCodecName: "aac",
                                    colorTransfer: "smpte2084") },
            toolsAvailable: true,
            fileExists: { _ in false })
        XCTAssertFalse(vm.settings.toneMapHDR)
        XCTAssertFalse(vm.hasHDRSource)
        await vm.loadFiles([URL(fileURLWithPath: "/hdr.mov")])
        XCTAssertTrue(vm.settings.toneMapHDR)
        XCTAssertTrue(vm.hasHDRSource)
    }

    func testLoadingSDRSourceLeavesToneMapAlone() async {
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { _ in MediaInfo(durationSeconds: 5, videoCodecName: "h264", audioCodecName: "aac",
                                    colorTransfer: "bt709") },
            toolsAvailable: true,
            fileExists: { _ in false })
        await vm.loadFiles([URL(fileURLWithPath: "/sdr.mov")])
        XCTAssertFalse(vm.settings.toneMapHDR)
        XCTAssertFalse(vm.hasHDRSource)

        // A deliberate manual choice must survive adding more SDR files.
        vm.settings.toneMapHDR = true
        await vm.loadFiles([URL(fileURLWithPath: "/sdr2.mov")])
        XCTAssertTrue(vm.settings.toneMapHDR)
    }

    func testAddingHDRToExistingSDRBatchEnablesToneMap() async {
        let hdrPaths: Set<String> = ["/hdr.mov"]
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { url in
                MediaInfo(durationSeconds: 5, videoCodecName: "hevc", audioCodecName: "aac",
                          colorTransfer: hdrPaths.contains(url.path) ? "arib-std-b67" : "bt709")
            },
            toolsAvailable: true,
            fileExists: { _ in false })
        await vm.loadFiles([URL(fileURLWithPath: "/sdr.mov")])
        XCTAssertFalse(vm.settings.toneMapHDR)
        await vm.loadFiles([URL(fileURLWithPath: "/hdr.mov")])
        XCTAssertTrue(vm.settings.toneMapHDR, "not only on first load — HDR can arrive later in the batch")
    }

    func testManualOffSurvivesAddingMoreFiles() async {
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { url in
                MediaInfo(durationSeconds: 5, videoCodecName: "hevc", audioCodecName: "aac",
                          colorTransfer: url.lastPathComponent.hasPrefix("hdr") ? "smpte2084" : "bt709")
            },
            toolsAvailable: true,
            fileExists: { _ in false })
        await vm.loadFiles([URL(fileURLWithPath: "/hdr1.mov")])
        XCTAssertTrue(vm.settings.toneMapHDR)

        vm.settings.toneMapHDR = false
        await vm.loadFiles([URL(fileURLWithPath: "/sdr.mov")])
        XCTAssertFalse(vm.settings.toneMapHDR, "adding an SDR file must not undo a manual off")
        await vm.loadFiles([URL(fileURLWithPath: "/hdr2.mov")])
        XCTAssertFalse(vm.settings.toneMapHDR, "nor must adding a second HDR file")

        // A fresh list is a fresh decision: the first HDR source switches it on again.
        vm.clearAll()
        await vm.loadFiles([URL(fileURLWithPath: "/hdr3.mov")])
        XCTAssertTrue(vm.settings.toneMapHDR)
    }

    /// A load that started before the HDR file arrived must not undo the user's manual
    /// off when it finally finishes: the decision is taken as each result lands.
    func testManualOffSurvivesAnOverlappingSlowLoad() async {
        let gate = ProbeGate()
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { url in
                if url.lastPathComponent == "slow.mov" { await gate.wait() }
                return MediaInfo(durationSeconds: 5, videoCodecName: "hevc", audioCodecName: "aac",
                                 colorTransfer: url.lastPathComponent.hasPrefix("hdr") ? "smpte2084" : "bt709")
            },
            toolsAvailable: true,
            fileExists: { _ in false })
        let slow = Task { await vm.loadFiles([URL(fileURLWithPath: "/slow.mov")]) }
        while vm.items.isEmpty { await Task.yield() }

        await vm.loadFiles([URL(fileURLWithPath: "/hdr.mov")])
        XCTAssertTrue(vm.settings.toneMapHDR)
        vm.settings.toneMapHDR = false

        await gate.open()
        await slow.value
        XCTAssertFalse(vm.settings.toneMapHDR, "the slow SDR load finishing must not re-enable it")
    }

    func testRemovedHDRFileDoesNotEnableToneMap() async {
        let gate = ProbeGate()
        let vm = ConversionViewModel(
            engine: FakeEngine(),
            probe: { _ in
                await gate.wait()
                return MediaInfo(durationSeconds: 5, videoCodecName: "hevc", audioCodecName: "aac",
                                 colorTransfer: "smpte2084")
            },
            toolsAvailable: true,
            fileExists: { _ in false })
        let load = Task { await vm.loadFiles([URL(fileURLWithPath: "/hdr.mov")]) }
        while vm.items.isEmpty { await Task.yield() }
        vm.clearAll()
        await gate.open()
        await load.value
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertFalse(vm.settings.toneMapHDR, "a file the user already removed is not a source")
    }

    /// Regression: with an AAC source the first load switches Audio to Copy, whose only
    /// valid channel layout is "same as source". A Stereo pick made earlier must be
    /// reset, or the combo check rejects every file in the batch.
    func testStereoPickedBeforeLoadDoesNotFailAACSourceOnCopy() async {
        let engine = FakeEngine()
        let vm = ConversionViewModel(
            engine: engine,
            probe: { _ in MediaInfo(durationSeconds: 5, videoCodecName: "h264", audioCodecName: "aac") },
            toolsAvailable: true,
            fileExists: { _ in false })
        vm.settings.channels = .stereo
        await vm.loadFiles([URL(fileURLWithPath: "/clip.mov")])
        XCTAssertEqual(vm.settings.audioCodec, .copy)

        await vm.convertAll()
        XCTAssertEqual(engine.convertCount, 1)
        if case .done = vm.items[0].status {} else {
            XCTFail("expected the file to convert, got \(vm.items[0].status)")
        }
    }

    func testAudioCodecChangeClampsABitrateTheNewCodecRejects() {
        let vm = ConversionViewModel(engine: FakeEngine(), probe: { _ in MediaInfo() },
                                     toolsAvailable: true, fileExists: { _ in false })
        // A high E-AC-3 pick must not carry over: Opus rejects it, MP3 and AC-3 clamp it silently.
        for (codec, expected) in [(AudioCodec.opus, 512), (.mp3, 320), (.ac3, 640), (.aac, 640)] {
            vm.settings.audioCodec = .eac3
            vm.settings.audioBitrate = .kbps(1536)
            vm.settings.audioCodec = codec
            vm.audioCodecChanged()
            XCTAssertEqual(vm.settings.audioBitrate, .kbps(expected), "\(codec)")
            XCTAssertTrue(CodecCompatibility.audioBitrateOptions(for: codec).contains(vm.settings.audioBitrate))
        }
        // Auto and a pick the new codec accepts are left alone.
        vm.settings.audioBitrate = .auto
        vm.settings.audioCodec = .opus
        vm.audioCodecChanged()
        XCTAssertEqual(vm.settings.audioBitrate, .auto)
        vm.settings.audioBitrate = .kbps(192)
        vm.audioCodecChanged()
        XCTAssertEqual(vm.settings.audioBitrate, .kbps(192))
    }

    /// Same class of bug as the stale-channels case: a leftover high bitrate must not make the
    /// combo check reject files once the load switches Audio to Copy, which takes no bitrate.
    func testStaleHighBitrateDoesNotFailAACSourceOnCopy() async {
        let engine = FakeEngine()
        let vm = ConversionViewModel(
            engine: engine,
            probe: { _ in MediaInfo(durationSeconds: 5, videoCodecName: "h264", audioCodecName: "aac") },
            toolsAvailable: true,
            fileExists: { _ in false })
        vm.settings.audioCodec = .eac3
        vm.settings.audioBitrate = .kbps(1536)
        await vm.loadFiles([URL(fileURLWithPath: "/clip.mov")])
        XCTAssertEqual(vm.settings.audioCodec, .copy)

        await vm.convertAll()
        XCTAssertEqual(engine.convertCount, 1)
    }
}

/// Holds probes until the test releases them, to interleave loads deterministically.
private actor ProbeGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
