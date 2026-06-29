import SwiftUI
import MediaConverterCore

@main
struct MediaConverterApp: App {
    @StateObject private var viewModel = MediaConverterApp.makeViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 420, minHeight: 460)
        }
        .windowResizability(.contentSize)
    }

    @MainActor
    static func makeViewModel() -> ConversionViewModel {
        if let tools = FFmpegLocator.locate() {
            let engine = FFmpegConversionEngine(ffmpeg: tools.ffmpeg)
            let probe = MediaProbe(ffprobe: tools.ffprobe)
            return ConversionViewModel(engine: engine,
                                       probe: { try await probe.probe($0) },
                                       toolsAvailable: true)
        } else {
            // No tools: a no-op engine; UI shows the "ffmpeg not found" banner.
            return ConversionViewModel(engine: NoopEngine(),
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
