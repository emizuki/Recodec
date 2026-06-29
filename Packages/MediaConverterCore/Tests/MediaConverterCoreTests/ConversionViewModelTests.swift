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
}
