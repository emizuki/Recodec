# Target-Bitrate (2-Pass) Encoding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Bitrate" video rate-control mode (target kbps, optionally 2-pass) alongside the existing CRF mode, with a live size estimate.

**Architecture:** `ConversionSettings` gains the mode + bitrate + 2-pass fields and two derived flags. `ArgumentBuilder.build` returns a *list* of ffmpeg commands (`[[String]]`) — one for every existing mode, two for software 2-pass — and `FFmpegConversionEngine` runs the list sequentially (these change together in one task, since the return-type change couples them). `ContentView` adds the mode switch, kbps field, estimate, and 2-pass toggle.

**Tech Stack:** Swift 5, SwiftUI, XCTest, ffmpeg CLI (libx264/libx265/libsvtav1/libvpx-vp9, *_videotoolbox).

## Global Constraints

- Platform: macOS 13+, Swift 5; all pure logic lives in `MediaConverterCore` with XCTest coverage.
- **CRF is the permanent default** mode (`rateControl` defaults to `.quality`).
- Bitrate mode applies only to software-encodable video codecs (`videoCodec.supportsCRF` == h264/hevc/av1/vp9). Ignored for copy/none/ProRes and GIF/audio-only.
- **2-pass is software-only.** VideoToolbox encodes bitrate single-pass; the 2-pass toggle is disabled (grayed) when `useHardware` is on.
- Default `videoBitrateKbps` = 2000. The size estimate is approximate (labeled `≈`).
- `ArgumentBuilder.build` returns `[[String]]`; single-command modes return a one-element array with byte-for-byte the same arguments as today.
- The `FFmpegConversionEngine.convert` public signature is unchanged.

---

### Task 1: Settings model — rate-control mode, bitrate, 2-pass, derived flags, size estimate

**Files:**
- Modify: `Packages/MediaConverterCore/Sources/MediaConverterCore/ConversionSettings.swift`
- Test: `Packages/MediaConverterCore/Tests/MediaConverterCoreTests/ConversionSettingsTests.swift`

**Interfaces:**
- Produces:
  - `enum RateControl: String, CaseIterable, Sendable { case quality, bitrate }`
  - `ConversionSettings.rateControl: RateControl` (default `.quality`)
  - `ConversionSettings.videoBitrateKbps: Int` (default `2000`)
  - `ConversionSettings.twoPass: Bool` (default `true`)
  - `var usesBitrate: Bool` — `rateControl == .bitrate && videoCodec.supportsCRF`
  - `var effectiveTwoPass: Bool` — `usesBitrate && twoPass && !useHardware`
  - `var estimatedAudioKbps: Int`
  - `func estimatedOutputBytes(durationSeconds: Double) -> Int`

- [ ] **Step 1: Write the failing tests** — append to `ConversionSettingsTests.swift`:

```swift
func testDefaultRateControlIsQuality() {
    let s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20)
    XCTAssertEqual(s.rateControl, .quality)
    XCTAssertEqual(s.videoBitrateKbps, 2000)
    XCTAssertTrue(s.twoPass)
    XCTAssertFalse(s.usesBitrate)
    XCTAssertFalse(s.effectiveTwoPass)
}

func testUsesBitrateOnlyForSoftwareEncodableCodecs() {
    var s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20)
    s.rateControl = .bitrate
    XCTAssertTrue(s.usesBitrate)
    s.videoCodec = .copy
    XCTAssertFalse(s.usesBitrate, "bitrate mode does not apply to copy")
    s.videoCodec = .prores
    XCTAssertFalse(s.usesBitrate, "bitrate mode does not apply to ProRes")
}

func testEffectiveTwoPassRequiresSoftwareAndToggle() {
    var s = ConversionSettings(container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 25)
    s.rateControl = .bitrate
    XCTAssertTrue(s.effectiveTwoPass, "bitrate + software + twoPass on")
    s.useHardware = true
    XCTAssertFalse(s.effectiveTwoPass, "VideoToolbox cannot 2-pass")
    s.useHardware = false
    s.twoPass = false
    XCTAssertFalse(s.effectiveTwoPass, "2-pass toggled off")
    s.twoPass = true
    s.rateControl = .quality
    XCTAssertFalse(s.effectiveTwoPass, "quality mode is never 2-pass")
}

func testEstimatedOutputBytes() {
    var s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20,
                               audioBitrate: .kbps(128))
    s.rateControl = .bitrate
    s.videoBitrateKbps = 2000
    // (2000 + 128) kbps * 1000 / 8 * 60s = 15,960,000 bytes
    XCTAssertEqual(s.estimatedOutputBytes(durationSeconds: 60), 15_960_000)
    XCTAssertEqual(s.estimatedAudioKbps, 128)
}

func testEstimatedAudioKbpsDefaults() {
    var s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .none, crf: 20)
    XCTAssertEqual(s.estimatedAudioKbps, 0)
    s.audioCodec = .copy
    XCTAssertEqual(s.estimatedAudioKbps, 128)
    s.audioCodec = .aac            // lossy, auto bitrate
    XCTAssertEqual(s.estimatedAudioKbps, 128)
    s.audioCodec = .flac           // lossless, not modeled
    XCTAssertEqual(s.estimatedAudioKbps, 0)
}
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `cd Packages/MediaConverterCore && swift test --filter ConversionSettingsTests`
Expected: compile failure (`rateControl`/`usesBitrate`/… not members).

- [ ] **Step 3: Implement** — in `ConversionSettings.swift`, add the enum above `ConversionSettings`:

```swift
public enum RateControl: String, CaseIterable, Sendable {
    case quality, bitrate
}
```

Add three stored properties to the struct (after `proResProfile`):

```swift
    public var rateControl: RateControl
    public var videoBitrateKbps: Int
    public var twoPass: Bool
```

Extend the initializer — add these parameters at the **end** of the signature (defaults keep every existing call site valid) and assign them:

```swift
                preset: EncoderPreset = .slow, proResProfile: ProResProfile = .hq,
                rateControl: RateControl = .quality, videoBitrateKbps: Int = 2000,
                twoPass: Bool = true) {
        // ...existing assignments...
        self.rateControl = rateControl
        self.videoBitrateKbps = videoBitrateKbps
        self.twoPass = twoPass
    }
```

Add the derived flags + estimate as an extension at the end of the file:

```swift
extension ConversionSettings {
    /// Bitrate mode only applies to software-encodable video codecs; for
    /// copy/none/ProRes it is ignored and the conversion behaves as quality mode.
    public var usesBitrate: Bool { rateControl == .bitrate && videoCodec.supportsCRF }

    /// True only when ffmpeg should run two passes: bitrate mode, the toggle on,
    /// and a software encoder (VideoToolbox cannot 2-pass).
    public var effectiveTwoPass: Bool { usesBitrate && twoPass && !useHardware }

    /// Approximate audio bitrate folded into the size estimate. Lossless/PCM are
    /// variable and not modeled (treated as 0); the estimate is labeled `≈`.
    public var estimatedAudioKbps: Int {
        switch audioCodec {
        case .none: return 0
        case .copy: return 128
        default:
            guard audioCodec.supportsBitrate else { return 0 }
            if case .kbps(let k) = audioBitrate { return k }
            return 128
        }
    }

    /// Estimated output size in bytes for bitrate mode, from the target video
    /// bitrate, the estimated audio bitrate, and the source duration.
    public func estimatedOutputBytes(durationSeconds: Double) -> Int {
        Int(Double(videoBitrateKbps + estimatedAudioKbps) * 1000 / 8 * durationSeconds)
    }
}
```

- [ ] **Step 4: Run the tests, verify they pass**

Run: `swift test --filter ConversionSettingsTests`
Expected: PASS. Then `swift test` — the full suite still passes (new fields default-initialized, `Equatable` re-synthesized).

- [ ] **Step 5: Commit**

```bash
git add Packages/MediaConverterCore/Sources/MediaConverterCore/ConversionSettings.swift \
        Packages/MediaConverterCore/Tests/MediaConverterCoreTests/ConversionSettingsTests.swift
git commit -m "feat(core): add bitrate rate-control mode, 2-pass flag, and size estimate to settings"
```

---

### Task 2: ArgumentBuilder command list + multi-pass engine

`ArgumentBuilder.build` and `FFmpegConversionEngine` change **together in one commit**: the new `[[String]]` return type breaks the engine's call site, so a builder-only commit would not compile. Implement both, then run the suite, then commit once.

**Files:**
- Modify: `Packages/MediaConverterCore/Sources/MediaConverterCore/ArgumentBuilder.swift`
- Modify: `Packages/MediaConverterCore/Sources/MediaConverterCore/ConversionEngine.swift`
- Test: `Packages/MediaConverterCore/Tests/MediaConverterCoreTests/ArgumentBuilderTests.swift`
- Test: `Packages/MediaConverterCore/Tests/MediaConverterCoreTests/ConversionEngineTests.swift`

**Interfaces:**
- Consumes: `ConversionSettings.usesBitrate`, `.effectiveTwoPass`, `.videoBitrateKbps` (Task 1).
- Produces: `ArgumentBuilder.build(settings:input:output:source:passLog:) -> [[String]]` (new `passLog: String = ""` parameter; one command except software 2-pass returns `[pass1, pass2]`). `FFmpegConversionEngine` runs the list sequentially with combined progress and passlog cleanup; `convert(...)` signature unchanged.

- [ ] **Step 1: Update the ArgumentBuilder tests and add the bitrate + engine tests.**

In `ArgumentBuilderTests.swift`, wrap every existing expected array in an outer array (contents unchanged). Example — change `XCTAssertEqual(args, [ … ])` to `XCTAssertEqual(args, [[ … ]])`. Apply to all 13 existing tests. Then add:

```swift
func testBitrateSoftwareTwoPass() {
    var s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20)
    s.rateControl = .bitrate
    s.videoBitrateKbps = 2500
    let cmds = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4",
                                     source: src, passLog: "/tmp/p")
    XCTAssertEqual(cmds, [
        ["-hide_banner", "-y", "-i", "/in.mov",
         "-c:v", "libx264", "-preset", "slow", "-b:v", "2500k", "-pix_fmt", "yuv420p", "-profile:v", "high",
         "-pass", "1", "-passlogfile", "/tmp/p", "-an", "-f", "null", "/dev/null"],
        ["-hide_banner", "-y", "-i", "/in.mov",
         "-c:v", "libx264", "-preset", "slow", "-b:v", "2500k", "-pix_fmt", "yuv420p", "-profile:v", "high",
         "-pass", "2", "-passlogfile", "/tmp/p",
         "-c:a", "aac",
         "-movflags", "+faststart", "/out.mp4"],
    ])
}

func testBitrateSoftwareSinglePass() {
    var s = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20)
    s.rateControl = .bitrate
    s.videoBitrateKbps = 2500
    s.twoPass = false
    let cmds = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4", source: src)
    XCTAssertEqual(cmds, [[
        "-hide_banner", "-y", "-i", "/in.mov",
        "-c:v", "libx264", "-preset", "slow", "-b:v", "2500k", "-pix_fmt", "yuv420p", "-profile:v", "high",
        "-c:a", "aac",
        "-movflags", "+faststart", "/out.mp4"
    ]])
}

func testBitrateHardwareIsSinglePassWithBitrate() {
    var s = ConversionSettings(container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 25,
                               useHardware: true)
    s.rateControl = .bitrate
    s.videoBitrateKbps = 3000
    let cmds = ArgumentBuilder.build(settings: s, input: "/in.mov", output: "/out.mp4", source: src)
    XCTAssertEqual(cmds, [[
        "-hide_banner", "-y", "-i", "/in.mov",
        "-c:v", "hevc_videotoolbox", "-b:v", "3000k", "-pix_fmt", "yuv420p", "-tag:v", "hvc1",
        "-c:a", "aac",
        "-movflags", "+faststart", "/out.mp4"
    ]])
}
```

In `ConversionEngineTests.swift`, add the 2-pass integration test (mirrors the existing HEVC test; skipped without ffmpeg):

```swift
func testTwoPassBitrateProducesOutput() async throws {
    guard let tools = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg not installed") }
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    let input = dir.appendingPathComponent("eng2p-in-\(UUID().uuidString).mp4")
    let output = dir.appendingPathComponent("eng2p-out-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }

    let gen = Process()
    gen.executableURL = URL(fileURLWithPath: tools.ffmpeg)
    gen.arguments = ["-hide_banner", "-loglevel", "error",
                     "-f", "lavfi", "-i", "testsrc=size=160x120:rate=15:duration=1",
                     "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                     "-shortest", "-c:v", "libx264", "-c:a", "aac", "-y", input.path]
    try gen.run(); gen.waitUntilExit()

    let source = try await MediaProbe(ffprobe: tools.ffprobe).probe(input)
    var settings = ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 23)
    settings.rateControl = .bitrate
    settings.videoBitrateKbps = 800
    XCTAssertTrue(settings.effectiveTwoPass)

    let progressBox = ProgressBox()
    let engine = FFmpegConversionEngine(ffmpeg: tools.ffmpeg)
    try await engine.convert(input: input, output: output, settings: settings, source: source) { f in
        progressBox.record(f)
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    let result = try await MediaProbe(ffprobe: tools.ffprobe).probe(output)
    XCTAssertEqual(result.videoCodecName, "h264")
    XCTAssertGreaterThan(progressBox.max, 0.0)
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()))?
        .filter { $0.hasPrefix("recodec-pass-") } ?? []
    XCTAssertTrue(leftovers.isEmpty, "passlog temp files must be removed")
}
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `cd Packages/MediaConverterCore && swift test`
Expected: compile failure (`build` returns `[String]` without `passLog:`; the engine still calls the old API).

- [ ] **Step 3a: Replace `ArgumentBuilder.swift`:**

```swift
import Foundation

public enum ArgumentBuilder {
    static func videoToolboxQuality(fromCRF crf: Int) -> Int {
        max(1, min(100, 100 - crf * 2))
    }

    /// Builds the ffmpeg command(s) for a conversion. Returns one command for
    /// every mode except software 2-pass bitrate, which returns `[pass1, pass2]`.
    /// `passLog` is the `-passlogfile` prefix (used only for 2-pass).
    public static func build(settings s: ConversionSettings, input: String, output: String,
                             source: MediaInfo, passLog: String = "") -> [[String]] {
        if s.container == .gif {
            return [["-hide_banner", "-y", "-i", input, "-an", output]]
        }

        let mp4Family: Set<Container> = [.mp4, .mov, .m4v]
        let inputArgs = ["-hide_banner", "-y", "-i", input]

        // Video encode args (codec + rate control + preset + pix_fmt + profile).
        // `videoTag` (container hvc1) is kept separate so pass 1 can omit it.
        var videoEncode: [String] = []
        var videoTag: [String] = []

        switch s.videoCodec {
        case .none:
            videoEncode = ["-vn"]
        case .copy:
            videoEncode = ["-c:v", "copy"]
            if source.videoCodecName == "hevc", mp4Family.contains(s.container) {
                videoTag = ["-tag:v", "hvc1"]
            }
        case .prores:
            if s.useHardware, let hw = s.videoCodec.hardwareEncoder {
                videoEncode = ["-c:v", hw, "-profile:v", String(s.proResProfile.ffmpegValue)]
            } else if let sw = s.videoCodec.softwareEncoder {
                videoEncode = ["-c:v", sw, "-profile:v", String(s.proResProfile.ffmpegValue)]
            }
        default: // h264 / hevc / av1 / vp9
            if s.useHardware, let hw = s.videoCodec.hardwareEncoder {
                videoEncode = ["-c:v", hw]
                videoEncode += s.usesBitrate
                    ? ["-b:v", "\(s.videoBitrateKbps)k"]
                    : ["-q:v", String(videoToolboxQuality(fromCRF: s.crf))]
            } else if let sw = s.videoCodec.softwareEncoder {
                videoEncode = ["-c:v", sw]
                if s.videoCodec.supportsPreset {
                    videoEncode += s.videoCodec == .av1
                        ? ["-preset", String(s.preset.svtAV1Value)]
                        : ["-preset", s.preset.x264Name]
                }
                if s.usesBitrate {
                    videoEncode += ["-b:v", "\(s.videoBitrateKbps)k"]
                } else {
                    videoEncode += ["-crf", String(s.crf)]
                    if s.videoCodec == .vp9 { videoEncode += ["-b:v", "0"] }
                }
            }
            if s.videoCodec == .h264 || s.videoCodec == .hevc {
                videoEncode += ["-pix_fmt", "yuv420p"]
            }
            if s.videoCodec == .h264 {
                videoEncode += ["-profile:v", "high"]
            }
            if s.videoCodec == .hevc, mp4Family.contains(s.container) {
                videoTag = ["-tag:v", "hvc1"]
            }
        }

        var audioArgs: [String] = []
        switch s.audioCodec {
        case .none:
            audioArgs = ["-an"]
        case .copy:
            audioArgs = ["-c:a", "copy"]
        default:
            if let enc = s.audioCodec.encoder {
                audioArgs = ["-c:a", enc]
                if s.audioCodec.supportsBitrate, let bitrate = s.audioBitrate.ffmpegArgument {
                    audioArgs += ["-b:a", bitrate]
                }
                if let ch = s.channels.count {
                    audioArgs += ["-ac", String(ch)]
                }
            }
        }

        let faststart = s.container.supportsFaststart ? ["-movflags", "+faststart"] : []

        if s.effectiveTwoPass {
            let pass1 = inputArgs + videoEncode
                + ["-pass", "1", "-passlogfile", passLog, "-an", "-f", "null", "/dev/null"]
            let pass2 = inputArgs + videoEncode
                + ["-pass", "2", "-passlogfile", passLog] + videoTag + audioArgs + faststart + [output]
            return [pass1, pass2]
        }
        return [inputArgs + videoEncode + videoTag + audioArgs + faststart + [output]]
    }
}
```

- [ ] **Step 3b: Refactor `FFmpegConversionEngine`.** Keep `ConversionState`, `LockedBuffer`, `LockedParser`, the protocol, and `ConversionError` exactly as they are. Replace the `convert(...)` method body and add two private methods:

```swift
    public func convert(input: URL, output: URL, settings: ConversionSettings, source: MediaInfo,
                        onProgress: @escaping (Double) -> Void) async throws {
        let passLog = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("recodec-pass-\(UUID().uuidString)")
        defer { cleanupPassLog(prefix: passLog) }

        let commands = ArgumentBuilder.build(settings: settings, input: input.path,
                                             output: output.path, source: source, passLog: passLog)
        let count = commands.count
        do {
            for (index, args) in commands.enumerated() {
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

        let stderrBuffer = LockedBuffer()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrBuffer.append(chunk)
        }

        state.begin(process)

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
```

- [ ] **Step 4: Run the full suite, verify it passes**

Run: `cd Packages/MediaConverterCore && swift test`
Expected: PASS — the 13 updated + 3 new ArgumentBuilder tests, the existing engine HEVC + failure-tail tests (single-command path unchanged), and the new 2-pass test.

- [ ] **Step 5: Commit (builder + engine + both test files in one commit)**

```bash
git add Packages/MediaConverterCore/Sources/MediaConverterCore/ArgumentBuilder.swift \
        Packages/MediaConverterCore/Sources/MediaConverterCore/ConversionEngine.swift \
        Packages/MediaConverterCore/Tests/MediaConverterCoreTests/ArgumentBuilderTests.swift \
        Packages/MediaConverterCore/Tests/MediaConverterCoreTests/ConversionEngineTests.swift
git commit -m "feat(core): emit ffmpeg command lists and run them multi-pass for bitrate mode"
```

---

### Task 3: UI — rate-control switch, bitrate field, size estimate, 2-pass toggle

**Files:**
- Modify: `App/ContentView.swift`

No unit tests (the project has none for SwiftUI views); verified by building and running. This task consumes `RateControl`, `rateControl`, `videoBitrateKbps`, `twoPass`, and `estimatedOutputBytes(durationSeconds:)` from Task 1.

- [ ] **Step 1: Replace the Quality `GridRow`.** In `settingsForm`, the current block is:

```swift
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
```

Replace it with:

```swift
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
                    }
                } else {
                    GridRow {
                        Text("Bitrate")
                        HStack(spacing: 8) {
                            TextField("", value: $viewModel.settings.videoBitrateKbps, format: .number)
                                .frame(width: 72)
                                .multilineTextAlignment(.trailing)
                            Text("kbps").foregroundStyle(.secondary)
                            Text(estimatedSizeText).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    GridRow {
                        Text("")
                        Toggle("2-pass", isOn: $viewModel.settings.twoPass)
                            .disabled(viewModel.settings.useHardware)
                    }
                }
            }
```

- [ ] **Step 2: Add the estimate helper.** In the "Bindings & helpers" section of `ContentView`, add:

```swift
    private var estimatedSizeText: String {
        guard let duration = viewModel.items.first?.info?.durationSeconds, duration > 0 else { return "≈ —" }
        let bytes = viewModel.settings.estimatedOutputBytes(durationSeconds: duration)
        return "≈ " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
```

- [ ] **Step 3: Build and run; verify manually**

```bash
xcodegen generate
xcodebuild -project Recodec.xcodeproj -scheme Recodec -configuration Release \
  -derivedDataPath build/dd build
open build/dd/Build/Products/Release/Recodec.app
```

Expected, with a video file loaded and a software codec (e.g. H.264) selected:
- The Quality row shows a **Quality | Bitrate** segmented control; default is **Quality** with the CRF slider.
- Selecting **Bitrate** shows a kbps field (default 2000), a `≈ <size>` readout that updates with the bitrate and the loaded file, and a **2-pass** toggle (on).
- Turning on **Use VideoToolbox** disables (grays) the **2-pass** toggle; the kbps field stays active.
- Switching the video codec to **Copy** hides the Quality/Bitrate control entirely.

- [ ] **Step 4: Commit**

```bash
git add App/ContentView.swift
git commit -m "feat(ui): add bitrate rate-control mode with size estimate and 2-pass toggle"
```

---

## Self-Review

**Spec coverage:** mode switch + kbps input (Task 3); size estimate (Tasks 1, 3); 2-pass software-only via `effectiveTwoPass` (Tasks 1–2); single-pass hardware bitrate (Task 2); VideoToolbox disables 2-pass (Task 1 flag + Task 3 `.disabled`); CRF default (Task 1); command-list engine + passlog cleanup (Task 2); estimate/edge cases (Task 1 `estimatedAudioKbps`, Task 3 `≈ —`). All covered.

**Placeholders:** none — every step has full code and exact commands.

**Type consistency:** `rateControl`/`videoBitrateKbps`/`twoPass`/`usesBitrate`/`effectiveTwoPass`/`estimatedOutputBytes(durationSeconds:)` and `build(...passLog:) -> [[String]]` are used identically across Tasks 1–3.
