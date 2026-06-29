import Foundation

public protocol ConversionEngineProtocol {
    func convert(input: URL, output: URL, settings: ConversionSettings, source: MediaInfo,
                 onProgress: @escaping (Double) -> Void) async throws
    func cancel()
}

public enum ConversionError: Error {
    case ffmpegFailed(code: Int32, stderrTail: String)
    case cancelled
}

public final class FFmpegConversionEngine: ConversionEngineProtocol {
    private let ffmpeg: String
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init(ffmpeg: String) { self.ffmpeg = ffmpeg }

    public func convert(input: URL, output: URL, settings: ConversionSettings, source: MediaInfo,
                        onProgress: @escaping (Double) -> Void) async throws {
        lock.lock(); cancelled = false; lock.unlock()

        let conversionArgs = ArgumentBuilder.build(settings: settings, input: input.path,
                                                   output: output.path, source: source)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-progress", "pipe:1", "-nostats"] + conversionArgs

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Stream progress from stdout.
        var parser = ProgressParser(durationSeconds: source.durationSeconds)
        let parserLock = NSLock()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            parserLock.lock()
            parser.consume(text)
            let fraction = parser.fraction
            parserLock.unlock()
            onProgress(fraction)
        }

        lock.lock(); self.process = process; lock.unlock()

        try process.run()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        lock.lock(); let wasCancelled = cancelled; self.process = nil; lock.unlock()
        if wasCancelled {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.cancelled
        }
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: output)
            let tail = String(decoding: stderrData.suffix(800), as: UTF8.self)
            throw ConversionError.ffmpegFailed(code: process.terminationStatus, stderrTail: tail)
        }
        onProgress(1.0)
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        process?.terminate()
        lock.unlock()
    }
}
