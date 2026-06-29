import Foundation
import AppKit
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

    /// Load opened files into the shared view model and bring the window forward.
    /// Called from BOTH SwiftUI's `.onOpenURL` (where macOS actually delivers the URLs)
    /// and `NSApplicationDelegate.application(_:open:)` (a fallback that receives an empty
    /// array on current macOS). `loadFiles` de-duplicates by URL, so overlapping delivery
    /// from both paths never double-loads a file.
    func handleOpen(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            await viewModel.loadFiles(urls)
            bringToFront()
        }
    }

    private func bringToFront() {
        // An already-running app activates fine. But a COLD launch via a Service starts the
        // app in the background, where macOS 14+ cooperative activation ignores a self
        // `activate()` (Finder, the foreground app, won't yield). "Opening" our own bundle is
        // a foreground launch request the system honors in that case, unlike a bare activate.
        NSApp.activate(ignoringOtherApps: true)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config, completionHandler: nil)
        NSApp.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
    }
}

private final class NoopEngine: ConversionEngineProtocol {
    func convert(input: URL, output: URL, settings: ConversionSettings, source: MediaInfo,
                 onProgress: @escaping (Double) -> Void) async throws {}
    func cancel() {}
}
