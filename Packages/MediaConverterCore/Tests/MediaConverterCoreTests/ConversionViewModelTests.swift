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
