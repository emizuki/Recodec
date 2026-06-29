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

// MARK: - Private helpers

/// Owns the locked process/cancelled state so NSLock never lives inside an async function.
private final class ConversionState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Reset the cancelled flag and store the process atomically — call BEFORE run().
    func begin(_ process: Process) {
        lock.lock()
        cancelled = false
        self.process = process
        lock.unlock()
    }

    /// Clear the stored process and return whether the run was cancelled.
    func finishAndWasCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasCancelled = cancelled
        process = nil
        return wasCancelled
    }

    /// Mark as cancelled and terminate the current process if one is running.
    func cancel() {
        lock.lock()
        cancelled = true
        process?.terminate()
        lock.unlock()
    }
}

/// Wraps a ProgressParser behind a lock so the readabilityHandler closure can call it
/// without capturing a mutable variable.
private final class LockedParser: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: ProgressParser

    init(durationSeconds: Double?) {
        parser = ProgressParser(durationSeconds: durationSeconds)
    }

    /// Consume the text, update internal state, and return the current fraction.
    func consume(_ text: String) -> Double {
        lock.lock()
        defer { lock.unlock() }
        parser.consume(text)
        return parser.fraction
    }
}

// MARK: - Engine

public final class FFmpegConversionEngine: ConversionEngineProtocol {
    private let ffmpeg: String
    private let state = ConversionState()

    public init(ffmpeg: String) { self.ffmpeg = ffmpeg }

    public func convert(input: URL, output: URL, settings: ConversionSettings, source: MediaInfo,
                        onProgress: @escaping (Double) -> Void) async throws {
        let conversionArgs = ArgumentBuilder.build(settings: settings, input: input.path,
                                                   output: output.path, source: source)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-progress", "pipe:1", "-nostats"] + conversionArgs

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // LockedParser avoids capturing a mutable var in the readabilityHandler closure.
        let lockedParser = LockedParser(durationSeconds: source.durationSeconds)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let fraction = lockedParser.consume(text)
            onProgress(fraction)
        }

        // Store the process BEFORE run() so cancel() can find it immediately.
        state.begin(process)

        // Set terminationHandler BEFORE run() to eliminate the race where the process
        // could exit between run() and handler assignment, leaving the continuation stuck.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in cont.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        let wasCancelled = state.finishAndWasCancelled()
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
        state.cancel()
    }
}
