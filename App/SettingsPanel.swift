import SwiftUI
import MediaConverterCore

/// What to make and how: Format / Video / Audio on one row, then a Video column and an
/// Audio column. The two stream-mapping options sit behind "More options" because they are
/// not touched on most runs; everything else stays visible.
///
/// Heights here are deliberate: the columns share a reserved minimum height and the
/// Quality/Bitrate and Copy/re-encode states fill the same space, so changing a codec or
/// opening "More options" does not resize the window.
struct SettingsPanel: View {
    @ObservedObject var viewModel: ConversionViewModel
    @State private var showMore = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let rowHeight: CGFloat = 24
    private static let rowSpacing: CGFloat = 10
    /// Two control rows plus the gap between them: what a caption replaces when the codec
    /// is Copy, so the column keeps its height.
    private static let twoRows = rowHeight * 2 + rowSpacing
    /// The Video column at its tallest (rate rows, preset, VideoToolbox). Reserved so changing
    /// the codec does not change the window height. Opening "More options" can make the Audio
    /// column taller than this, and the window then grows by the difference.
    private static let columnsMinHeight: CGFloat = 146
    private static let columnGap: CGFloat = 24
    private static let pickerGap: CGFloat = 12
    /// Label column of a control row. A menu Picker keeps its intrinsic width whatever frame
    /// it is given, so controls are left-aligned at this edge rather than stretched.
    private static let labelWidth: CGFloat = 104

    private var settings: ConversionSettings { viewModel.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            outputPickers
            HStack(alignment: .top, spacing: Self.columnGap) {
                videoColumn
                audioColumn
            }
            .frame(minHeight: Self.columnsMinHeight, alignment: .top)
        }
    }

    // MARK: - Format / Video / Audio

    private var outputPickers: some View {
        HStack(alignment: .top, spacing: Self.pickerGap) {
            labeled("Format") {
                Picker("Format", selection: $viewModel.settings.container) {
                    ForEach(Container.allCases, id: \.self) { Text($0.fileExtension.uppercased()).tag($0) }
                }
                .onChange(of: viewModel.settings.container) { _ in viewModel.containerChanged() }
            }
            labeled("Video") {
                Picker("Video", selection: $viewModel.settings.videoCodec) {
                    ForEach(CodecCompatibility.videoCodecs(for: settings.container), id: \.self) {
                        Text(label($0)).tag($0)
                    }
                }
                .disabled(settings.container == .gif)
                .onChange(of: viewModel.settings.videoCodec) { _ in viewModel.videoCodecChanged() }
            }
            labeled("Audio") {
                Picker("Audio", selection: Binding(
                    get: { viewModel.settings.audioCodec },
                    set: { viewModel.settings.audioCodec = $0; viewModel.audioCodecChanged() }
                )) {
                    ForEach(CodecCompatibility.audioCodecs(for: settings.container), id: \.self) {
                        Text(label($0)).tag($0)
                    }
                }
                .disabled(settings.container == .gif)
            }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Video column

    private var videoColumn: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            Text("Video").font(.headline)
            if settings.container == .gif {
                // The GIF branch of ArgumentBuilder passes only `-an`: the picture is made with
                // ffmpeg's defaults and nothing below applies. (Its video codec is .none, which
                // would otherwise read as "no video".)
                note("The GIF is made with ffmpeg's defaults, so no video options apply.")
            } else if settings.videoCodec == .copy {
                note("Video is copied as it is, with no re-encode.")
            } else if settings.videoCodec == .none {
                note("No video in the output.")
            } else {
                if settings.videoCodec.supportsCRF { rateRows }
                if settings.videoCodec == .prores {
                    controlRow("ProRes profile") {
                        Picker("ProRes profile", selection: $viewModel.settings.proResProfile) {
                            ForEach(ProResProfile.allCases, id: \.self) { Text(label($0)).tag($0) }
                        }
                    }
                }
                if settings.videoCodec.supportsPreset {
                    controlRow("Preset") {
                        Picker("Preset", selection: $viewModel.settings.preset) {
                            ForEach(EncoderPreset.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        .disabled(settings.useHardware)
                    }
                }
                Toggle("Use VideoToolbox", isOn: $viewModel.settings.useHardware)
                    .disabled(settings.videoCodec.hardwareEncoder == nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Quality/Bitrate switch plus its one row. Both modes use the same row height, so
    /// switching between them does not change the content height.
    @ViewBuilder private var rateRows: some View {
        HStack {
            Picker("Rate control", selection: $viewModel.settings.rateControl) {
                Text("Quality").tag(RateControl.quality)
                Text("Bitrate").tag(RateControl.bitrate)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            Spacer()
            if settings.rateControl == .quality {
                Text("CRF \(settings.crf)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .frame(height: Self.rowHeight)

        if settings.rateControl == .quality {
            // The slider's left end is the lowest CRF, which is the best quality and the
            // biggest file; the labels say so instead of leaving the direction to guesswork.
            HStack(spacing: 8) {
                Text("Better").font(.caption).foregroundStyle(.secondary)
                Slider(value: crfBinding,
                       in: Double(settings.videoCodec.crfRange.lowerBound)...Double(settings.videoCodec.crfRange.upperBound))
                    .labelsHidden()
                    .accessibilityLabel("Quality (CRF)")
                    .accessibilityValue("CRF \(settings.crf)")
                Text("Smaller").font(.caption).foregroundStyle(.secondary)
            }
            .frame(height: Self.rowHeight)
        } else {
            HStack(spacing: 8) {
                TextField("Video bitrate", value: bitrateKbpsBinding, format: WholeNumberFormat())
                    .labelsHidden()
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                Text("kbps").foregroundStyle(.secondary)
                Toggle("2-pass", isOn: $viewModel.settings.twoPass)
                    .disabled(settings.useHardware)
                    .padding(.leading, 8)
                Spacer()
            }
            .frame(height: Self.rowHeight)
        }
    }

    // MARK: - Audio column

    private var audioColumn: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            Text("Audio").font(.headline)
            if audioReencoding {
                controlRow("Channels") {
                    Picker("Channels", selection: channelsBinding) {
                        ForEach(CodecCompatibility.channelOptions(for: settings.audioCodec), id: \.self) {
                            Text(label($0)).tag($0)
                        }
                    }
                }
                controlRow("Bitrate") {
                    Picker("Audio bitrate", selection: bitrateBinding) {
                        ForEach(CodecCompatibility.audioBitrateOptions(for: settings.audioCodec,
                                                                       channels: settings.channels),
                                id: \.self) { Text(label($0)).tag($0) }
                    }
                    .disabled(!settings.audioCodec.supportsBitrate)
                }
            } else {
                note(settings.audioCodec == .none
                     ? "No audio in the output."
                     : "Audio is copied as it is, with no re-encode.")
                    .frame(height: Self.twoRows, alignment: .topLeading)
            }
            // Stream mapping is ignored for GIF, so there is nothing to open.
            if settings.container != .gif { moreOptions }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Options that are not touched on most runs: HDR tone mapping and stream mapping.
    /// Collapsed, it still says what is switched on, so a changed setting is never hidden.
    private var moreOptions: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            Button {
                if reduceMotion { showMore.toggle() } else { withAnimation(.easeOut(duration: 0.15)) { showMore.toggle() } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showMore ? 90 : 0))
                        .frame(width: 10)
                    Text("More options")
                    if !showMore, let summary = activeSummary {
                        Text("· \(summary)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showMore ? "expanded" : "collapsed")

            if showMore {
                if canToneMap {
                    Toggle("Tone map HDR to SDR", isOn: $viewModel.settings.toneMapHDR)
                        .help("Convert HDR (PQ/HLG, BT.2020) video to Rec.709 SDR using "
                              + "VideoToolbox, so it no longer looks washed out on SDR "
                              + "displays. Only HDR files are affected; SDR files in the batch "
                              + "convert as usual. Switched on automatically when the first HDR "
                              + "file is loaded.")
                }
                Toggle("Keep all audio and subtitle tracks", isOn: $viewModel.settings.preserveAllStreams)
                    .help("Map every audio and subtitle stream from the source (and "
                          + "attachments, into MKV) instead of only the first of each kind. "
                          + "The target container must be able to hold them.")
                controlRow("Default subtitle") {
                    Picker("Default subtitle", selection: $viewModel.settings.subtitleDefault) {
                        ForEach(SubtitleDefault.presets, id: \.self) { Text(label($0)).tag($0) }
                    }
                    .disabled(!settings.preserveAllStreams || !settings.container.supportsSubtitles)
                }
            }
        }
    }

    /// Tone mapping needs the video re-encoded, so it has nothing to do for Copy or None.
    private var canToneMap: Bool {
        settings.videoCodec != .copy && settings.videoCodec != .none
    }

    /// What is switched on inside "More options", for its collapsed title. Tone mapping is
    /// reported only while an HDR file is loaded, since it does nothing otherwise.
    private var activeSummary: String? {
        var active: [String] = []
        if viewModel.hasHDRSource && canToneMap {
            active.append(settings.toneMapHDR ? "tone map on" : "tone map off")
        }
        if settings.preserveAllStreams { active.append("all tracks kept") }
        return active.isEmpty ? nil : active.joined(separator: ", ")
    }

    // MARK: - Pieces

    private func controlRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: Self.labelWidth, alignment: .leading)
            control().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.rowHeight)
    }

    private func note(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Bindings & helpers

    private var bitrateKbpsBinding: Binding<Int> {
        Binding(get: { viewModel.settings.videoBitrateKbps },
                set: { viewModel.settings.videoBitrateKbps = min(max($0, 1), 100_000) })
    }
    private var crfBinding: Binding<Double> {
        Binding(get: { Double(viewModel.settings.crf) },
                set: { viewModel.settings.crf = Int($0.rounded()) })
    }
    private var bitrateBinding: Binding<AudioBitrate> {
        Binding(get: { viewModel.settings.audioBitrate },
                set: { viewModel.settings.audioBitrate = $0 })
    }
    private var channelsBinding: Binding<AudioChannels> {
        Binding(get: { viewModel.settings.channels },
                set: { viewModel.setChannels($0) })
    }
    private var audioReencoding: Bool {
        settings.audioCodec != .copy && settings.audioCodec != .none
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
}

/// A whole number shown without a thousands separator, read by keeping only its digits.
/// `.number` follows the Mac's region: where that groups with a dot (en_VN, de_DE) 2000
/// shows as "2.000", which reads as 2 kbps. `.number.grouping(.never)` fixes the display but
/// then reads a typed "2.500" or "4,000" as 2 or 4, so the parsing is done here instead.
private struct WholeNumberFormat: ParseableFormatStyle {
    func format(_ value: Int) -> String { String(value) }

    var parseStrategy: Strategy { Strategy() }

    struct Strategy: ParseStrategy {
        func parse(_ value: String) throws -> Int {
            guard let number = Int(value.filter(\.isASCII).filter(\.isNumber)) else {
                throw CocoaError(.formatting)
            }
            return number
        }
    }
}
