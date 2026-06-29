import Foundation

public enum ContainerAppLocator {
    /// Given an embedded extension's bundle URL (…/MyApp.app/Contents/PlugIns/Ext.appex),
    /// return the containing `.app` URL, or nil if the path isn't of that shape.
    public static func appURL(fromExtensionBundleURL bundleURL: URL) -> URL? {
        let appURL = bundleURL
            .deletingLastPathComponent()   // …/Contents/PlugIns
            .deletingLastPathComponent()   // …/Contents
            .deletingLastPathComponent()   // …/MyApp.app
        return appURL.pathExtension == "app" ? appURL : nil
    }
}
