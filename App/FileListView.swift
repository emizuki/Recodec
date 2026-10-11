import SwiftUI
import AppKit
import MediaConverterCore

/// The Files header plus either the drop zone or the list. The list height is computed from
/// the file count (rows have a fixed height), so the window can follow it with no measuring.
struct FileListView: View {
    @ObservedObject var viewModel: ConversionViewModel
    let isDropTargeted: Bool
    let onAdd: () -> Void

    private static let rowHeight: CGFloat = 52
    /// Half a row stays visible past the cap, so a long list visibly scrolls.
    private static let maxVisibleRows: CGFloat = 5.5
    private static let emptyHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if viewModel.items.isEmpty { dropZone } else { list }
        }
    }

    private var header: some View {
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
            Button("Add Files…", action: onAdd)
        }
    }

    private var dropZone: some View {
        Text("Drag media here, or click Add Files…")
            .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity, minHeight: Self.emptyHeight, maxHeight: Self.emptyHeight)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isDropTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                              style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [5])))
    }

    private var list: some View {
        let visibleRows = min(CGFloat(viewModel.items.count), Self.maxVisibleRows)
        let toneMapped = viewModel.settings.effectiveToneMapHDR
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                    FileRow(item: item,
                            verdict: viewModel.compatibility(for: item),
                            toneMapped: toneMapped,
                            isConverting: viewModel.isConverting,
                            estimate: rowEstimate(for: item)) {
                        viewModel.removeItem(id: item.id)
                    }
                    .frame(height: Self.rowHeight)
                    .overlay(alignment: .bottom) {
                        if index < viewModel.items.count - 1 { Divider().padding(.leading, 48) }
                    }
                }
            }
        }
        .frame(height: visibleRows * Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isDropTargeted ? Color.accentColor : Color.primary.opacity(0.10),
                          lineWidth: isDropTargeted ? 2 : 1))
    }

    /// Per-file output-size estimate shown in the row, only in bitrate mode.
    /// Returns nil when there's nothing meaningful to show (quality mode,
    /// non-bitrate codec, or unknown duration) so the row stays clean.
    private func rowEstimate(for item: ConversionViewModel.InputItem) -> String? {
        guard viewModel.settings.usesBitrate,
              let duration = item.info?.durationSeconds, duration > 0 else { return nil }
        let bytes = viewModel.settings.estimatedOutputBytes(durationSeconds: duration)
        return "≈ " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// One file: a type glyph, the (middle-truncated) name, codec chips, and on the right what
/// matters now: whether it ends up iPhone-ready, its progress, or where the result is.
/// A progress fill runs behind the row while it converts.
private struct FileRow: View {
    let item: ConversionViewModel.InputItem
    let verdict: IPhoneCompatibility?
    let toneMapped: Bool
    let isConverting: Bool
    let estimate: String?
    let onRemove: () -> Void
    @State private var hovering = false

    private var canRemove: Bool { hovering && !isConverting }

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
                    if item.info?.isHDR == true {
                        Badge(text: toneMapped ? "HDR → SDR" : "HDR", color: .accentColor)
                    }
                    if let estimate {
                        Text(estimate).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            trailing

            // A fixed slot, so showing the button on hover never shifts the row.
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove")
                .accessibilityLabel("Remove \(item.url.lastPathComponent)")
                .frame(width: 20)
                .opacity(canRemove ? 1 : 0)
                .accessibilityHidden(!canRemove)
        }
        .padding(.horizontal, 10)
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

    @ViewBuilder private var trailing: some View {
        switch item.status {
        case .pending, .probing:
            Text("Reading…").font(.caption).foregroundStyle(.secondary)
        case .ready:
            if let verdict {
                VerdictLabel(isReady: verdict.isCompatible,
                             text: verdict.isCompatible ? "iPhone-ready" : (verdict.reason ?? "Not iPhone-compatible"))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 240, alignment: .trailing)
            }
        case .converting:
            Text("Converting \(Int(item.progress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.accentColor)
        case .done(let output):
            HStack(spacing: 8) {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 240, alignment: .trailing)
                .help(message)
        }
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
}

/// A small capsule label used for codec names in a file row.
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
