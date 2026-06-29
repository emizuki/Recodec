import Foundation
import AppKit
import UniformTypeIdentifiers
import MediaConverterCore

final class ActionRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let providers = context.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let resolved: URL?
                switch item {
                case let u as URL: resolved = u
                case let data as Data: resolved = URL(dataRepresentation: data, relativeTo: nil)
                default: resolved = nil
                }
                if let resolved, resolved.isFileURL {
                    lock.lock(); urls.append(resolved); lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            defer { context.completeRequest(returningItems: context.inputItems, completionHandler: nil) }
            guard !urls.isEmpty,
                  let appURL = ContainerAppLocator.appURL(fromExtensionBundleURL: Bundle.main.bundleURL)
            else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config, completionHandler: nil)
        }
    }
}
