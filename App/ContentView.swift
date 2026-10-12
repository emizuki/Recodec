import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MediaConverterCore

/// The one window: file list, settings, and the Convert footer.
///
/// The window is sized by its content (`.windowResizability(.contentSize)` in the App), so
/// nothing here measures or resizes it. Every height below is either intrinsic or computed
/// from the file count, which is what lets the window follow the content without help.
struct ContentView: View {
    @ObservedObject var viewModel: ConversionViewModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !viewModel.toolsAvailable { ffmpegBanner }
            FileListView(viewModel: viewModel, isDropTargeted: isDropTargeted, onAdd: openPanel)
            SettingsPanel(viewModel: viewModel)
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            loadDroppedFiles(providers)
            return true
        }
    }

    private var ffmpegBanner: some View {
        Label("ffmpeg not found. Install it with: brew install ffmpeg", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.callout)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            verdictSummary
            Spacer()
            if viewModel.isConverting {
                Button("Cancel") { viewModel.cancel() }
            }
            Button("Convert") {
                Task { await viewModel.convertAll() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(viewModel.items.isEmpty || viewModel.isConverting || !viewModel.toolsAvailable)
        }
    }

    /// With files loaded, how many of them come out iPhone-ready (each row says why not).
    /// With none loaded, whether the current settings alone would be.
    @ViewBuilder private var verdictSummary: some View {
        if viewModel.items.isEmpty {
            if let verdict = viewModel.verdictWithoutFiles {
                VerdictLabel(isReady: verdict.isCompatible,
                             text: verdict.isCompatible ? "iPhone-ready" : (verdict.reason ?? "Not iPhone-compatible"),
                             font: .callout)
            }
        } else {
            let tally = viewModel.compatibilityTally
            if tally.total > 0 {
                let allReady = tally.ready == tally.total
                VerdictLabel(isReady: allReady, text: summary(of: tally), font: .callout)
            }
        }
    }

    private func summary(of tally: CompatibilityTally) -> String {
        if tally.ready == tally.total { return tally.total == 1 ? "iPhone-ready" : "All \(tally.total) iPhone-ready" }
        if tally.ready == 0 { return tally.total == 1 ? "Not iPhone-ready" : "None iPhone-ready" }
        return "\(tally.ready) of \(tally.total) iPhone-ready"
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = allowedInputTypes
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await viewModel.loadFiles(urls) }
        }
    }

    /// Media types the Add Files… panel allows, so non-media files (png, json, …)
    /// are filtered out. Video uses the broad supertypes; audio is listed by
    /// extension rather than the `.audio`/`.audiovisualContent` supertypes because
    /// MIDI conforms to those but ffmpeg can't decode it (no synthesizer).
    private var allowedInputTypes: [UTType] {
        var types: [UTType] = [.movie, .video]
        let extensions = [
            // video containers
            "mp4", "mov", "m4v", "mkv", "webm", "avi", "flv", "wmv",
            "mpg", "mpeg", "ts", "m2ts", "ogv", "3gp", "3g2",
            // audio (MIDI deliberately omitted)
            "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "oga",
            "opus", "wma", "ac3", "eac3", "m4b", "caf", "ape", "wv", "amr",
            "mka", "dts", "alac",
        ]
        for ext in extensions {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                let resolved: URL? = await withCheckedContinuation { cont in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let data = item as? Data,
                           let url = URL(dataRepresentation: data, relativeTo: nil) {
                            cont.resume(returning: url)
                        } else if let url = item as? URL {
                            cont.resume(returning: url)
                        } else {
                            cont.resume(returning: nil)
                        }
                    }
                }
                if let url = resolved {
                    urls.append(url)
                }
            }
            await viewModel.loadFiles(urls)
        }
    }
}

/// The iPhone-ready line: a green seal when ready, a quiet "not" otherwise. Not-ready is
/// information (the target may be Plex, not an iPhone), so it is never drawn as an error.
struct VerdictLabel: View {
    let isReady: Bool
    let text: String
    var font: Font = .caption

    var body: some View {
        Label(text, systemImage: isReady ? "checkmark.seal.fill" : "iphone.slash")
            .font(font)
            .foregroundStyle(isReady ? Color.green : Color.secondary)
            .lineLimit(2)
            .help(text)
    }
}
