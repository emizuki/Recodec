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

/// Accumulates Data chunks appended from a readabilityHandler behind a lock.
/// Draining stderr concurrently prevents the pipe buffer from filling when ffmpeg
/// writes more than ~64 KB to stderr, which would cause ffmpeg to block and never exit.
private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var accumulated: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
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

        // Drain stderr concurrently so ffmpeg never blocks on a full pipe buffer.
        // readDataToEndOfFile() after process exit would deadlock if ffmpeg wrote >~64 KB.
        let stderrBuffer = LockedBuffer()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrBuffer.append(chunk)
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
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        // Final synchronous drain: bytes written by ffmpeg just before exit may still sit in
        // the kernel pipe buffer and not yet have been delivered to the readabilityHandler.
        // This is safe post-exit because the write-end of the pipe is now closed and the
        // concurrent handler has already been nil'd — no double-read is possible.
        stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
        let stderrData = stderrBuffer.accumulated

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
