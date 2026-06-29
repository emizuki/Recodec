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
        // vp9 is not valid for mp4
        vm.settings = ConversionSettings(container: .mp4, videoCodec: .vp9, audioCodec: .aac, crf: 31)

        await vm.convertAll()

        XCTAssertEqual(engine.convertCount, 0, "engine must not be called for invalid combo")
        guard case .failed(let msg) = vm.items[0].status else {
            return XCTFail("expected .failed, got \(vm.items[0].status)")
        }
        XCTAssertTrue(msg.contains("supported"), "failure message should mention 'supported'; got: \(msg)")
    }

    // MARK: - containerChanged / videoCodecChanged

    /// Switching to webm must reset h264→vp9 (first valid video) and aac→opus (first valid audio).
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
}
