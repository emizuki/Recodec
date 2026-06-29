import Foundation
import MediaConverterCore

@MainActor
final class AppModel {
    static let shared = AppModel()
    let viewModel: ConversionViewModel

    private init() {
        if let tools = FFmpegLocator.locate() {
            let probe = MediaProbe(ffprobe: tools.ffprobe)
            viewModel = ConversionViewModel(
                engine: FFmpegConversionEngine(ffmpeg: tools.ffmpeg),
                probe: { try await probe.probe($0) },
                toolsAvailable: true)
        } else {
            viewModel = ConversionViewModel(
                engine: NoopEngine(),
                probe: { _ in MediaInfo() },
                toolsAvailable: false)
        }
    }
}

private final class NoopEngine: ConversionEngineProtocol {
    func convert(input: URL, output: URL, settings: ConversionSettings, source: MediaInfo,
                 onProgress: @escaping (Double) -> Void) async throws {}
    func cancel() {}
}
