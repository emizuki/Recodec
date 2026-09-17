import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MediaConverterCore

struct ContentView: View {
    @ObservedObject var viewModel: ConversionViewModel
    @State private var window: NSWindow?
    @State private var contentHeight: CGFloat = 0
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !viewModel.toolsAvailable { ffmpegBanner }
            fileList
            Divider()
            settingsForm
            compatibilityBadge
            Divider()
            footer
        }
        .padding(16)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(ContentHeightKey.self) { newHeight in
            contentHeight = newHeight
            syncWindowHeight()
        }
        .onPreferenceChange(RowsHeightKey.self) { rowsHeight = $0 }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedFiles(providers)
            return true
        }
        .background(WindowAccessor { resolved in
            if window == nil {
                window = resolved
                syncWindowHeight()
            }
        })
    }

    private var ffmpegBanner: some View {
        Label("ffmpeg not found. Install it with: brew install ffmpeg", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.callout)
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            filesHeader
            if viewModel.items.isEmpty {
                Text("Drag media here, or click Add Files…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, style: StrokeStyle(dash: [5])))
            } else {
                // Explicit height = measured rows clamped to [44, 400]: hugs a
                // short list, caps a long one so it scrolls. (fixedSize would hug
                // but ignore the cap, overrunning the window.)
                ScrollView {
                    VStack(spacing: 0) { fileRows }
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: RowsHeightKey.self, value: geo.size.height)
                        })
                }
                .frame(height: min(max(rowsHeight, 44), 400))
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10)))
            }
        }
    }

    private var filesHeader: some View {
        HStack(spacing: 8) {
            Text("Files").font(.headline)
            if !viewModel.items.isEmpty {
                Text("\(viewModel.items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
            Spacer()
            if !viewModel.items.isEmpty {
                Button("Clear All") { viewModel.clearAll() }
                    .disabled(viewModel.isConverting)
            }
            Button("Add Files…") { openPanel() }
        }
    }

    /// The file rows plus inset dividers shown inside the scrollable list pane.
    @ViewBuilder private var fileRows: some View {
        ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
            FileRow(item: item, isConverting: viewModel.isConverting,
                    estimate: rowEstimate(for: item)) {
                viewModel.removeItem(id: item.id)
            }
            if index < viewModel.items.count - 1 {
                Divider().padding(.leading, 48)
            }
        }
    }

    private var settingsForm: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Format")
                Picker("", selection: $viewModel.settings.container) {
                    ForEach(Container.allCases, id: \.self) { Text($0.fileExtension.uppercased()).tag($0) }
                }
                .labelsHidden()
                .onChange(of: viewModel.settings.container) { _ in viewModel.containerChanged() }
            }
            GridRow {
                Text("Video")
                let validVideo = CodecCompatibility.videoCodecs(for: viewModel.settings.container)
                Picker("", selection: $viewModel.settings.videoCodec) {
                    ForEach(validVideo, id: \.self) { Text(label($0)).tag($0) }
                }
                .labelsHidden()
                .disabled(viewModel.settings.container == .gif)
                .onChange(of: viewModel.settings.videoCodec) { _ in viewModel.videoCodecChanged() }
            }
            GridRow {
                Text("Audio")
                let validAudio = CodecCompatibility.audioCodecs(for: viewModel.settings.container)
                Picker("", selection: Binding(
                    get: { viewModel.settings.audioCodec },
                    set: { viewModel.settings.audioCodec = $0; viewModel.audioCodecChanged() }
                )) {
                    ForEach(validAudio, id: \.self) { Text(label($0)).tag($0) }
                }
                .labelsHidden()
                .disabled(viewModel.settings.container == .gif)
            }
            if viewModel.settings.videoCodec.supportsCRF {
                GridRow {
                    Text("Quality")
                    Picker("", selection: $viewModel.settings.rateControl) {
                        Text("Quality").tag(RateControl.quality)
                        Text("Bitrate").tag(RateControl.bitrate)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220, alignment: .leading)
                }
                if viewModel.settings.rateControl == .quality {
                    GridRow {
                        Text("")
                        HStack {
                            Slider(value: crfBinding,
                                   in: Double(viewModel.settings.videoCodec.crfRange.lowerBound)...Double(viewModel.settings.videoCodec.crfRange.upperBound),
                                   step: 1)
                            Text("CRF \(viewModel.settings.crf)").monospacedDigit().frame(width: 64, alignment: .trailing)
                        }
                        .frame(height: 24)
                    }
                } else {
                    // Bitrate field + 2-pass on a single row so Bitrate mode is the
                    // same height as Quality mode — switching modes no longer changes
                    // the content height, so the window doesn't resize/flash.
                    GridRow {
                        Text("Bitrate")
                        HStack(spacing: 8) {
                            TextField("", value: bitrateKbpsBinding, format: .number)
                                .frame(width: 72)
                                .multilineTextAlignment(.trailing)
                            Text("kbps").foregroundStyle(.secondary)
                            Toggle("2-pass", isOn: $viewModel.settings.twoPass)
                                .disabled(viewModel.settings.useHardware)
                                .padding(.leading, 8)
                            Spacer()
                        }
                        .frame(height: 24)
                    }
                }
            }
            if viewModel.settings.videoCodec == .prores {
                GridRow {
                    Text("ProRes profile")
                    Picker("", selection: $viewModel.settings.proResProfile) {
                        ForEach(ProResProfile.allCases, id: \.self) { Text(label($0)).tag($0) }
                    }.labelsHidden()
                }
            }
            if viewModel.settings.videoCodec.supportsPreset {
                GridRow {
                    Text("Preset")
                    Picker("", selection: $viewModel.settings.preset) {
                        ForEach(EncoderPreset.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .labelsHidden()
                    .disabled(viewModel.settings.useHardware)
                }
            }
            GridRow {
                Text("Channels")
                Picker("", selection: $viewModel.settings.channels) {
                    ForEach(CodecCompatibility.channelOptions(for: viewModel.settings.audioCodec),
                            id: \.self) { Text(label($0)).tag($0) }
                }
                .labelsHidden()
                .disabled(!audioReencoding)
            }
            GridRow {
                Text("Audio bitrate")
                Picker("", selection: bitrateBinding) {
                    ForEach(AudioBitrate.presets, id: \.self) { Text(label($0)).tag($0) }
                }.labelsHidden().disabled(!viewModel.settings.audioCodec.supportsBitrate)
            }
            GridRow {
                Text("Hardware")
                Toggle("Use VideoToolbox", isOn: $viewModel.settings.useHardware)
                    .disabled(viewModel.settings.videoCodec.hardwareEncoder == nil)
            }
            GridRow {
                Text("Streams")
                Toggle("Keep all tracks", isOn: $viewModel.settings.preserveAllStreams)
                    .help("Map every stream from the source (all audio, subtitle and "
                          + "attachment tracks) instead of only the first of each kind. "
                          + "The target container must be able to hold them.")
            }
            GridRow {
                Text("Default subtitle")
                Picker("", selection: $viewModel.settings.subtitleDefault) {
                    ForEach(SubtitleDefault.presets, id: \.self) { Text(label($0)).tag($0) }
                }
                .labelsHidden()
                .disabled(!viewModel.settings.preserveAllStreams
                          || !viewModel.settings.container.supportsSubtitles)
            }
        }
    }

    private var compatibilityBadge: some View {
        let c = viewModel.compatibility
        return Label(c.isCompatible ? "iPhone-ready" : (c.reason ?? "Not iPhone-compatible"),
                     systemImage: c.isCompatible ? "checkmark.seal.fill" : "iphone.slash")
            .foregroundStyle(c.isCompatible ? .green : .secondary)
            .font(.callout)
    }

    private var footer: some View {
        HStack {
            if viewModel.isConverting {
                Button("Cancel") { viewModel.cancel() }
            }
            Spacer()
            Button("Convert") {
                Task { await viewModel.convertAll() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(viewModel.items.isEmpty || viewModel.isConverting || !viewModel.toolsAvailable)
        }
    }

    // MARK: - Bindings & helpers

    private var bitrateKbpsBinding: Binding<Int> {
        Binding(get: { viewModel.settings.videoBitrateKbps },
                set: { viewModel.settings.videoBitrateKbps = min(max($0, 1), 100_000) })
    }
    private var crfBinding: Binding<Double> {
        Binding(get: { Double(viewModel.settings.crf) },
                set: { viewModel.settings.crf = Int($0) })
    }
    private var bitrateBinding: Binding<AudioBitrate> {
        Binding(get: { viewModel.settings.audioBitrate },
                set: { viewModel.settings.audioBitrate = $0 })
    }
    private var audioReencoding: Bool {
        viewModel.settings.audioCodec != .copy && viewModel.settings.audioCodec != .none
    }
    /// Per-file output-size estimate shown in the list, only in bitrate mode.
    /// Returns nil when there's nothing meaningful to show (quality mode,
    /// non-bitrate codec, or unknown duration) so the row stays clean.
    private func rowEstimate(for item: ConversionViewModel.InputItem) -> String? {
        guard viewModel.settings.usesBitrate,
              let duration = item.info?.durationSeconds, duration > 0 else { return nil }
        let bytes = viewModel.settings.estimatedOutputBytes(durationSeconds: duration)
        return "≈ " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func label(_ v: VideoCodec) -> String {
        switch v {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .av1:  return "AV1"
        case .vp9:  return "VP9"
        case .prores: return "ProRes"
        case .copy: return "Copy (passthrough)"
        case .none: return "None"
        }
    }
    private func label(_ a: AudioCodec) -> String {
        switch a {
        case .aac:  return "AAC"
        case .mp3:  return "MP3"
        case .alac: return "ALAC"
        case .opus: return "Opus"
        case .flac: return "FLAC"
        case .pcm:  return "PCM (uncompressed)"
        case .ac3:  return "AC-3 (Dolby)"
        case .eac3: return "E-AC-3 (Dolby)"
        case .copy: return "Copy (passthrough)"
        case .none: return "None"
        }
    }
    private func label(_ p: ProResProfile) -> String {
        switch p {
        case .proxy:      return "Proxy"
        case .lt:         return "LT"
        case .standard:   return "422"
        case .hq:         return "422 HQ"
        case .prores4444: return "4444"
        }
    }
    private func label(_ c: AudioChannels) -> String {
        switch c {
        case .source:     return "Same as source"
        case .mono:       return "Mono"
        case .stereo:     return "Stereo"
        case .surround51: return "5.1"
        case .surround71: return "7.1"
        }
    }
    private func label(_ s: SubtitleDefault) -> String {
        switch s {
        case .unchanged:        return "Unchanged"
        case .none:             return "None"
        case .language(let c):  return Self.languageNames[c] ?? c.uppercased()
        }
    }
    private static let languageNames: [String: String] = [
        "eng": "English", "ger": "German", "fre": "French",
        "spa": "Spanish", "ita": "Italian",
    ]
    private func label(_ b: AudioBitrate) -> String {
        switch b {
        case .auto:         return "Auto (encoder default)"
        case .kbps(let k):  return "\(k) kbps"
        }
    }

    /// Resizes the window to fit the whole measured content (header + list +
    /// settings + footer), anchored at the top so it grows downward, then pins the
    /// height so the window always fits its content exactly and can't be shrunk
    /// into a clip. The list's own maxHeight caps a long list (it scrolls), so the
    /// window never needs to exceed the screen.
    ///
    /// Deferred to the next run-loop tick: this fires from a preference change that
    /// can run *during* a SwiftUI layout pass, and resizing the window synchronously
    /// from inside layout re-enters AppKit and crashes. `animate: false` avoids a
    /// nested animation run-loop for the same reason.
    private func syncWindowHeight() {
        DispatchQueue.main.async {
            guard let window, contentHeight > 1 else { return }
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            // Convert the SwiftUI content height to a window frame height so the
            // title bar is accounted for by AppKit, not guessed.
            let frameTarget = window.frameRect(forContentRect:
                NSRect(x: 0, y: 0, width: 200, height: contentHeight)).height
            let target = min(frameTarget, visible.height - 40)

            // Relax the height limits so the resize can move either direction,
            // apply it, then pin min and max height to the content.
            let freeWidth = CGFloat.greatestFiniteMagnitude
            window.minSize = NSSize(width: 420, height: 0)
            window.maxSize = NSSize(width: freeWidth, height: freeWidth)
            var frame = window.frame
            if abs(frame.height - target) > 1 {
                frame.origin.y += frame.height - target   // keep the top edge fixed
                frame.size.height = target
                if frame.minY < visible.minY { frame.origin.y = visible.minY }
                window.setFrame(frame, display: true, animate: false)
            }
            window.minSize = NSSize(width: 420, height: target)
            window.maxSize = NSSize(width: freeWidth, height: target)
        }
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

/// A single row in the Files list: a type glyph, the (middle-truncated) filename,
/// codec + status badges, a hover-revealed Remove button, and a progress fill
/// behind the row while it converts.
private struct FileRow: View {
    let item: ConversionViewModel.InputItem
    let isConverting: Bool
    let estimate: String?
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if let v = item.info?.videoCodecName { Badge(text: prettyCodec(v)) }
                    if let a = item.info?.audioCodecName { Badge(text: prettyCodec(a)) }
                    statusBadge
                }
            }

            Spacer(minLength: 8)

            if let estimate {
                Text(estimate)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if hovering && !isConverting {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(alignment: .leading) {
            if case .converting = item.status {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: geo.size.width * item.progress)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var iconName: String {
        if item.info?.videoCodecName != nil { return "film" }
        if item.info?.audioCodecName != nil { return "waveform" }
        return "doc"
    }

    /// Maps ffprobe's raw codec names to the friendly forms used in the pickers
    /// (e.g. "h264" → "H.264", "pcm_s16le" → "PCM"). Unknown codecs fall back to
    /// uppercase so anything ffmpeg reports still renders sensibly.
    private func prettyCodec(_ raw: String) -> String {
        let key = raw.lowercased()
        if key.hasPrefix("pcm") { return "PCM" }
        switch key {
        case "h264", "avc1": return "H.264"
        case "hevc", "h265": return "HEVC"
        case "av1":          return "AV1"
        case "vp9":          return "VP9"
        case "vp8":          return "VP8"
        case "mpeg4":        return "MPEG-4"
        case "mpeg2video":   return "MPEG-2"
        case "prores":       return "ProRes"
        case "aac":          return "AAC"
        case "mp3":          return "MP3"
        case "alac":         return "ALAC"
        case "opus":         return "Opus"
        case "vorbis":       return "Vorbis"
        case "flac":         return "FLAC"
        case "ac3":          return "AC-3"
        case "eac3":         return "E-AC-3"
        default:             return raw.uppercased()
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch item.status {
        case .pending, .probing:
            Badge(text: "Reading…")
        case .ready:
            EmptyView()
        case .converting:
            Badge(text: "Converting \(Int(item.progress * 100))%", color: .accentColor)
        case .done:
            Badge(text: "Done", color: .green)
        case .failed(let message):
            Badge(text: "Failed", color: .red).help(message)
        }
    }
}

/// Carries the measured natural height of the whole window content up to
/// ContentView, which resizes the window to match.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Natural height of the file rows, used to size the list pane (hug up to a cap).
private struct RowsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Resolves the NSWindow hosting this SwiftUI content so the window can be
/// resized to fit the file list.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let w = view.window { onResolve(w) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let w = nsView.window { onResolve(w) } }
    }
}

/// A small capsule label used for codec names and status in a file row.
private struct Badge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}
