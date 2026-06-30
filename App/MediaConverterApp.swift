import SwiftUI
import MediaConverterCore

@main
@MainActor
struct MediaConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppModel.shared.viewModel

    var body: some Scene {
        // Window (not WindowGroup): a single-instance scene. WindowGroup spawns a
        // new window per opened file, so dropping/Service-ing N files made N
        // identical windows (all share the one view model). One Window keeps a
        // single window; the per-URL opens just funnel into the shared model.
        Window("Recodec", id: "main") {
            ContentView(viewModel: viewModel)
                // Only a width floor here; ContentView's syncWindowHeight() owns the
                // height, pinning the window to exactly fit its content.
                .frame(minWidth: 420)
                // macOS delivers opened files (from the Service / "Open With") here.
                .onOpenURL { AppModel.shared.handleOpen([$0]) }
        }
        // .automatic so SwiftUI doesn't impose its own min/max height — the window
        // height is managed imperatively in ContentView to fit the file list.
        .windowResizability(.automatic)
    }
}
