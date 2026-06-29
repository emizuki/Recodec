import SwiftUI
import MediaConverterCore

@main
@MainActor
struct MediaConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppModel.shared.viewModel

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 420, minHeight: 460)
                // macOS delivers opened files (from the Quick Action / "Open With") here.
                .onOpenURL { AppModel.shared.handleOpen([$0]) }
        }
        .windowResizability(.contentSize)
    }
}
