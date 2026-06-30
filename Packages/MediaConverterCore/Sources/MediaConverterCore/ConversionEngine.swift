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

    /// Reset the cancelled flag — call ONCE at the start of a conversion.
    func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    /// Store the process atomically — call BEFORE run(). Does NOT touch the
    /// cancelled flag (reset() owns that, once per conversion).
    func begin(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    /// Whether cancel() has been requested for the current conversion.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
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
        state.reset()
        let passLog = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("recodec-pass-\(UUID().uuidString)")
        defer { cleanupPassLog(prefix: passLog) }

        let commands = ArgumentBuilder.build(settings: settings, input: input.path,
                                             output: output.path, source: source, passLog: passLog)
        let count = commands.count
        do {
            for (index, args) in commands.enumerated() {
                if state.isCancelled { throw ConversionError.cancelled }
                try await runProcess(args: args, durationSeconds: source.durationSeconds) { fraction in
                    onProgress((Double(index) + fraction) / Double(count))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        onProgress(1.0)
    }

    /// Runs one ffmpeg command to completion, forwarding parsed progress. Throws
    /// `.cancelled` or `.ffmpegFailed`; the caller owns output/passlog cleanup.
    private func runProcess(args: [String], durationSeconds: Double?,
                            onProgress: @escaping (Double) -> Void) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-progress", "pipe:1", "-nostats"] + args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let lockedParser = LockedParser(durationSeconds: durationSeconds)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            onProgress(lockedParser.consume(text))
        }

        // Drain stderr concurrently so ffmpeg never blocks on a full pipe buffer. A readDataToEndOfFile() after exit would deadlock if ffmpeg wrote >~64 KB.
        let stderrBuffer = LockedBuffer()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrBuffer.append(chunk)
        }

        // Store the process BEFORE run() so cancel() can find it immediately.
        state.begin(process)

        // Set terminationHandler BEFORE run() to close the race where the process exits between run() and handler assignment, leaving the continuation stuck.
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
        // Final synchronous drain: bytes ffmpeg wrote just before exit may still sit in the kernel pipe buffer. Safe post-exit — the write end is closed and the concurrent handler is already nil'd.
        stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
        let stderrData = stderrBuffer.accumulated

        if state.finishAndWasCancelled() {
            throw ConversionError.cancelled
        }
        guard process.terminationStatus == 0 else {
            let tail = String(decoding: stderrData.suffix(800), as: UTF8.self)
            throw ConversionError.ffmpegFailed(code: process.terminationStatus, stderrTail: tail)
        }
    }

    /// Removes every file at the passlog prefix (encoders name them differently:
    /// `-0.log`, `-0.log.mbtree`, `-0.log.cutree`, …).
    private func cleanupPassLog(prefix: String) {
        let dir = (prefix as NSString).deletingLastPathComponent
        let base = (prefix as NSString).lastPathComponent
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for file in files where file.hasPrefix(base) {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(file))
        }
    }

    public func cancel() {
        state.cancel()
    }
}
