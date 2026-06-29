import AppKit
import MediaConverterCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    // On current macOS, SwiftUI consumes opened URLs and delivers them via `.onOpenURL`,
    // so this typically receives an empty array — but it stays correct on any OS version
    // that routes file opens here. `handleOpen` ignores empty input, and `loadFiles`
    // de-duplicates by URL, so the two delivery paths never double-load.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.handleOpen(urls)
    }
}
