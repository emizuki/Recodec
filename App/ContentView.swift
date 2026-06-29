import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MediaConverterCore

struct ContentView: View {
    @ObservedObject var viewModel: ConversionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !viewModel.toolsAvailable {
                ffmpegBanner
            }
            fileList
            Divider()
            settingsForm
            compatibilityBadge
            Divider()
            footer
        }
        .padding(16)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedFiles(providers)
            return true
        }
    }

    private var ffmpegBanner: some View {
        Label("ffmpeg not found. Install it with: brew install ffmpeg", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.callout)
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            if viewModel.items.isEmpty {
                Text("Drag media here, or click Add Files…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, style: StrokeStyle(dash: [5])))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                            FileRow(item: item, isConverting: viewModel.isConverting) {
                                viewModel.removeItem(id: item.id)
                            }
                            if index < viewModel.items.count - 1 {
                                Divider().padding(.leading, 48)
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10)))
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
                Picker("", selection: $viewModel.settings.audioCodec) {
                    ForEach(validAudio, id: \.self) { Text(label($0)).tag($0) }
                }
                .labelsHidden()
                .disabled(viewModel.settings.container == .gif)
            }
            if viewModel.settings.videoCodec.supportsCRF {
                GridRow {
                    Text("Quality")
                    HStack {
                        Slider(value: crfBinding,
                               in: Double(viewModel.settings.videoCodec.crfRange.lowerBound)...Double(viewModel.settings.videoCodec.crfRange.upperBound),
                               step: 1)
                        Text("CRF \(viewModel.settings.crf)").monospacedDigit().frame(width: 64, alignment: .trailing)
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
                    ForEach(AudioChannels.allCases, id: \.self) { Text(label($0)).tag($0) }
                }.labelsHidden().disabled(!audioReencoding)
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
        }
    }
    private func label(_ b: AudioBitrate) -> String {
        switch b {
        case .auto:         return "Auto (encoder default)"
        case .kbps(let k):  return "\(k) kbps"
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await viewModel.loadFiles(urls) }
        }
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
                    if let v = item.info?.videoCodecName { Badge(text: v.uppercased()) }
                    if let a = item.info?.audioCodecName { Badge(text: a.uppercased()) }
                    statusBadge
                }
            }

            Spacer(minLength: 8)

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
