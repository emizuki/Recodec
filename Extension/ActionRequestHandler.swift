import Foundation
import AppKit
import UniformTypeIdentifiers
import MediaConverterCore
import os

final class ActionRequestHandler: NSObject, NSExtensionRequestHandling {
    private let log = Logger(subsystem: "com.emizuki.MediaConverter.ConvertQuickAction", category: "handoff")

    func beginRequest(with context: NSExtensionContext) {
        let providers = context.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            // Finder supplies each item typed as the file's content UTI (e.g. public.mpeg-4),
            // NOT public.file-url — so load the original file in place using a type the
            // provider actually registers. loadInPlaceFileRepresentation yields the original
            // file URL (inPlace), which is what we want so the app converts the real file.
            guard let typeID = provider.registeredTypeIdentifiers.first else { continue }
            group.enter()
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeID) { url, _, error in
                defer { group.leave() }
                if let error {
                    self.log.error("loadInPlace failed: \(error.localizedDescription, privacy: .public)")
                }
                if let url, url.isFileURL {
                    lock.lock(); urls.append(url); lock.unlock()
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
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config, completionHandler: { _, error in
                if let error {
                    self.log.error("open failed: \(error.localizedDescription, privacy: .public)")
                }
            })
        }
    }
}
