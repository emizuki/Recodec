import AppKit
import MediaConverterCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register as the provider for the "Convert Media" Finder Service (NSServices).
        NSApp.servicesProvider = self
    }

    // Finder right-click → "Convert Media" Service. NSMessage `convertMedia` maps here.
    // Reads the selected file URLs from the service pasteboard and loads them.
    // Service methods are invoked on the main thread, so @MainActor is correct.
    @MainActor
    @objc func convertMedia(_ pboard: NSPasteboard,
                            userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let urls = pboard.readObjects(forClasses: [NSURL.self],
                                      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        AppModel.shared.handleOpen(urls)
    }

    // "Open With" / drag-drop opens arrive via SwiftUI `.onOpenURL`; this remains a
    // correct fallback on any OS version that routes file opens through the delegate.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.handleOpen(urls)
    }
}
