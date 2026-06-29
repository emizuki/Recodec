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

    public var compatibility: IPhoneCompatibility {
        IPhoneCompatibilityChecker.evaluate(settings, source: items.first?.info ?? MediaInfo())
    }

    public func loadFiles(_ urls: [URL]) async {
        for url in urls where !items.contains(where: { $0.url == url }) {
            items.append(InputItem(url: url))
            let index = items.count - 1
            items[index].status = .probing
            do {
                let info = try await probe(url)
                items[index].info = info
                items[index].status = .ready
            } catch {
                items[index].status = .failed("Couldn't read this file")
            }
        }
    }

    public func convertAll() async {
        cancelRequested = false
        isConverting = true
        defer { isConverting = false }
        for index in items.indices {
            guard !cancelRequested else { break }
            guard case .ready = items[index].status, let info = items[index].info else { continue }
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
                items[index].status = .failed(Self.message(for: error))
            }
        }
    }

    /// Called when the container picker changes. Resets any codec that is incompatible
    /// with the new container to the first valid option, then normalises CRF.
    public func containerChanged() {
        let validVideo = CodecCompatibility.videoCodecs(for: settings.container)
        if !validVideo.contains(settings.videoCodec) {
            settings.videoCodec = validVideo[0]
        }
        let validAudio = CodecCompatibility.audioCodecs(for: settings.container)
        if !validAudio.contains(settings.audioCodec) {
            settings.audioCodec = validAudio[0]
        }
        videoCodecChanged()
    }

    /// Called when the video codec picker changes. Resets CRF to the new codec's default
    /// and clamps it within the codec's valid range.
    public func videoCodecChanged() {
        let range = settings.videoCodec.crfRange
        settings.crf = settings.videoCodec.defaultCRF
        settings.crf = min(max(settings.crf, range.lowerBound), range.upperBound)
    }

    public func cancel() {
        cancelRequested = true
        engine.cancel()
    }

    private func updateProgress(at index: Int, to fraction: Double) {
        guard items.indices.contains(index) else { return }
        items[index].progress = fraction
    }

    private static func message(for error: Error) -> String {
        if case ConversionError.ffmpegFailed(_, let tail) = error {
            return tail.split(separator: "\n").last.map(String.init) ?? "ffmpeg failed"
        }
        return error.localizedDescription
    }
}
