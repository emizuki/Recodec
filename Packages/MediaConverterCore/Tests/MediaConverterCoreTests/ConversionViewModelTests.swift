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
}
