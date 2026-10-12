import Foundation
import Combine

@MainActor
public final class ConversionViewModel: ObservableObject {
    public struct InputItem: Identifiable, Equatable {
        public let id: UUID
        public let url: URL
        public var info: MediaInfo?
        public var progress: Double
        public var status: Status

        public init(url: URL) {
            self.id = UUID()
            self.url = url
            self.info = nil
            self.progress = 0
            self.status = .pending
        }
    }

    public enum Status: Equatable {
        case pending, probing, ready, converting
        case done(URL)
        case failed(String)
    }

    @Published public var items: [InputItem] = []
    @Published public var settings: ConversionSettings = .iPhoneDefault
    @Published public var isConverting: Bool = false
    public let toolsAvailable: Bool

    private let engine: ConversionEngineProtocol
    private let probe: (URL) async throws -> MediaInfo
    private let fileExists: (URL) -> Bool
    private var cancelRequested = false

    public init(engine: ConversionEngineProtocol,
                probe: @escaping (URL) async throws -> MediaInfo,
                toolsAvailable: Bool,
                fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) {
        self.engine = engine
        self.probe = probe
        self.toolsAvailable = toolsAvailable
        self.fileExists = fileExists
    }

    /// Whether `item` ends up iPhone-ready under the current settings. With Copy the answer
    /// depends on the file, so it is judged per file. `nil` until the file has been read:
    /// judging it against an empty `MediaInfo` would blame the settings for a missing probe.
    public func compatibility(for item: InputItem) -> IPhoneCompatibility? {
        guard let info = item.info else { return nil }
        return IPhoneCompatibilityChecker.evaluate(settings, source: info)
    }

    /// iPhone-ready files out of the files read so far.
    public var compatibilityTally: CompatibilityTally {
        let verdicts = items.compactMap { compatibility(for: $0) }
        return CompatibilityTally(ready: verdicts.filter(\.isCompatible).count, total: verdicts.count)
    }

    public func loadFiles(_ urls: [URL]) async {
        let wasEmpty = items.isEmpty
        for url in urls where !items.contains(where: { $0.url == url }) {
            items.append(InputItem(url: url))
            let index = items.count - 1
            items[index].status = .probing
            let id = items[index].id
            do {
                let info = try await probe(url)
                guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
                // HDR sources look washed out on SDR displays unless tone mapped, so switch
                // it on when the list goes from having no HDR source to having one. Decided
                // here, as each result lands, not from a snapshot taken before the awaits:
                // the list can change meanwhile (overlapping loads, Remove, Clear All), and
                // a user who turned it off with an HDR file loaded must not see it flip
                // back on. Never switched off automatically.
                if info.isHDR && !hasHDRSource { settings.toneMapHDR = true }
                items[index].info = info
                items[index].status = .ready
            } catch {
                guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
                items[index].status = .failed("Couldn't read this file")
            }
        }
        // On a fresh load (list was empty), default the audio codec from the first source.
        if wasEmpty, let first = items.compactMap({ $0.info }).first {
            settings.audioCodec = ConversionSettings.recommendedAudioCodec(forSource: first)
            // Copy/None accept only `.source` channels; a stale Stereo/5.1 pick would
            // otherwise fail the combo check for every file in the batch.
            audioCodecChanged()
        }
    }

    /// Whether any loaded source carries an HDR transfer function.
    public var hasHDRSource: Bool {
        items.contains { $0.info?.isHDR == true }
    }

    public func convertAll() async {
        cancelRequested = false
        isConverting = true
        defer { isConverting = false }
        for index in items.indices {
            guard !cancelRequested else { break }
            // Convert any successfully-probed item, regardless of prior status: a .done or
            // .failed item must be re-convertible so pressing Convert again (e.g. after
            // changing the codec) re-runs it. Items that failed to probe have no info → skip.
            guard let info = items[index].info else { continue }
            // Pre-flight: reject unsupported codec/container combinations before invoking ffmpeg.
            guard CodecCompatibility.isValidCombo(settings) else {
                items[index].status = .failed("This codec/container combination isn't supported")
                continue
            }
            let input = items[index].url
            let output = OutputNamer.outputURL(forInput: input, container: settings.container, fileExists: fileExists)
            items[index].status = .converting
            items[index].progress = 0
            do {
                try await engine.convert(input: input, output: output, settings: settings, source: info) { [weak self] fraction in
                    Task { @MainActor in self?.updateProgress(at: index, to: fraction) }
                }
                items[index].status = .done(output)
                items[index].progress = 1
            } catch ConversionError.cancelled {
                items[index].status = .failed("Cancelled")
            } catch {
                items[index].status = .failed(error.localizedDescription)
            }
        }
    }

    /// Called when the container picker changes. Resets any codec that is incompatible
    /// with the new container to the first valid option, then normalises CRF.
    public func containerChanged() {
        let validVideo = CodecCompatibility.videoCodecs(for: settings.container)
        if !validVideo.contains(settings.videoCodec) {
            if let first = validVideo.first { settings.videoCodec = first }
            // CRF is codec-specific — only reset it when the codec actually changed.
            videoCodecChanged()
        }
        let validAudio = CodecCompatibility.audioCodecs(for: settings.container)
        if !validAudio.contains(settings.audioCodec) {
            if let first = validAudio.first { settings.audioCodec = first }
        }
        audioCodecChanged()
    }

    /// Called when the audio codec picker changes. Clamps the channel selection to
    /// what the new encoder accepts: ffmpeg aborts the run on an unsupported layout
    /// (e.g. 7.1 into E-AC-3) rather than down-mixing, so a stale selection left
    /// over from a more capable codec would fail at conversion time.
    public func audioCodecChanged() {
        let allowed = CodecCompatibility.channelOptions(for: settings.audioCodec)
        if !allowed.contains(settings.channels) {
            settings.channels = allowed.last ?? .source
        }
        channelsChanged()
    }

    /// The channel picker's entry point: sets the layout and normalises what depends on it, so a
    /// view cannot forget the second step.
    public func setChannels(_ channels: AudioChannels) {
        settings.channels = channels
        channelsChanged()
    }

    /// Clamps what depends on the layout (also called after a codec change). The bitrate ceiling
    /// depends on it: libopus takes 256 kbps per channel, so a high pick made on 5.1 must not
    /// carry over to stereo or mono, where the encoder rejects it. Same idea as the channel
    /// clamp above.
    public func channelsChanged() {
        if !CodecCompatibility.isAudioBitrateValid(settings.audioBitrate, for: settings.audioCodec,
                                                   channels: settings.channels) {
            settings.audioBitrate = CodecCompatibility.audioBitrateOptions(
                for: settings.audioCodec, channels: settings.channels).last ?? .auto
        }
    }

    /// Called when the video codec picker changes. Resets CRF to the new codec's default
    /// and clamps it within the codec's valid range.
    public func videoCodecChanged() {
        let range = settings.videoCodec.crfRange
        settings.crf = settings.videoCodec.defaultCRF
        settings.crf = min(max(settings.crf, range.lowerBound), range.upperBound)
        // A stale VideoToolbox flag would silently force software encoding (and gray
        // out the 2-pass toggle) for codecs without a hardware encoder; clear it.
        if settings.videoCodec.hardwareEncoder == nil {
            settings.useHardware = false
        }
    }

    public func cancel() {
        cancelRequested = true
        engine.cancel()
    }

    /// Remove a single file from the list. No-op while converting (the convert loop is
    /// index-based, so mutating the list mid-batch is unsafe).
    public func removeItem(id: UUID) {
        guard !isConverting else { return }
        items.removeAll { $0.id == id }
    }

    /// Remove all files from the list. No-op while converting.
    public func clearAll() {
        guard !isConverting else { return }
        items.removeAll()
    }

    private func updateProgress(at index: Int, to fraction: Double) {
        guard items.indices.contains(index) else { return }
        items[index].progress = fraction
    }
}
