# Finder Quick Action Extension Implementation Plan (Plan 2 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Finder **Quick Action** ("Convert Media") that, on selected video/audio files, opens the existing MediaConverter app pre-loaded with them — plus bundled converter-default refinements (wider audio bitrate, source-aware audio default, slow preset, quality-matched per-codec CRF).

**Architecture:** A new sandboxed **Action Extension** target (`ConvertQuickAction.appex`) embedded in the app. Its `beginRequest` reads the selected file URLs and calls `NSWorkspace.shared.open(urls, withApplicationAt: containerAppURL, configuration:)` (verified extension-available in the macOS 26.5 SDK). The app gains an `NSApplicationDelegateAdaptor` whose `application(_:open:)` routes the files to `ConversionViewModel.loadFiles` and brings the window forward. A user-initiated open grants the app access to the files — no App Group, URL scheme, or bookmarks.

**Tech Stack:** Swift 5 mode (toolchain 6.3), SwiftPM (local package), XCTest, SwiftUI + AppKit, Foundation, `NSExtensionRequestHandling`, `NSWorkspace`, XcodeGen, system Homebrew ffmpeg.

**Builds on:** Plan 1 (`main`) — `MediaConverterCore` package + the SwiftUI app. Do not re-create those; modify them.

## Global Constraints

- **Branch:** do all work on `feat/quick-action-extension` (created off `main`). Do NOT implement on `main`.
- **Commits:** per-task commits ARE authorized. Run real `git commit` (signing is on via 1Password — leave it on). End every commit message with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. `git add` ONLY the files a task changes — never `git add -A` (the generated `.xcodeproj` and `.build/` are gitignored).
- **Package tests:** `swift test --package-path Packages/MediaConverterCore`. Keep the build warning-free.
- **App/extension build:** `xcodegen generate` then `xcodebuild -project MediaConverter.xcodeproj -scheme MediaConverter -configuration Debug build`. The app + extension are **ad-hoc signed** (`CODE_SIGN_IDENTITY = "-"`); do NOT pass `CODE_SIGNING_ALLOWED=NO` for the extension tasks — the `.appex` must be signed to load/appear.
- **Public API:** preserve existing public signatures from Plan 1 unless a task explicitly changes them.
- **Quality standard:** per-codec default CRF is quality-matched to H.264 CRF 20 → **H.264 20, HEVC 25, AV1 28, VP9 28**.
- **Bundle ids:** app `com.emizuki.MediaConverter`; extension `com.emizuki.MediaConverter.ConvertQuickAction`.
- Manual-QA tasks require: build (ad-hoc signed) → run the app once (registers the extension) → enable it in System Settings → Privacy & Security → Extensions → Finder.

---

### Task 1: Widen audio bitrate range to 640 kbps

**Files:**
- Modify: `Packages/MediaConverterCore/Sources/MediaConverterCore/ConversionSettings.swift` (the `AudioBitrate.presets` array)
- Test: `Packages/MediaConverterCore/Tests/MediaConverterCoreTests/ConversionSettingsTests.swift`

**Interfaces:**
- Consumes: existing `AudioBitrate` enum.
- Produces: `AudioBitrate.presets` now ends at 640.

- [ ] **Step 1: Write the failing test** (add to `ConversionSettingsTests`)

```swift
func testAudioBitratePresetsUpTo640() {
    let kbps = AudioBitrate.presets.compactMap { if case .kbps(let k) = $0 { return k } else { return nil } }
    XCTAssertEqual(kbps, [96, 128, 160, 192, 256, 320, 384, 448, 512, 640])
    XCTAssertEqual(AudioBitrate.presets.first, .auto)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/MediaConverterCore --filter ConversionSettingsTests/testAudioBitratePresetsUpTo640`
Expected: FAIL (current list stops at 320).

- [ ] **Step 3: Update `AudioBitrate.presets`**

```swift
    public static let presets: [AudioBitrate] = [
        .auto, .kbps(96), .kbps(128), .kbps(160), .kbps(192), .kbps(256),
        .kbps(320), .kbps(384), .kbps(448), .kbps(512), .kbps(640),
    ]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/MediaConverterCore --filter ConversionSettingsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/MediaConverterCore/Sources/MediaConverterCore/ConversionSettings.swift Packages/MediaConverterCore/Tests/MediaConverterCoreTests/ConversionSettingsTests.swift
git commit -m "feat: extend audio bitrate options up to 640 kbps"
```

---

### Task 2: Quality-matched per-codec CRF + slow default + CRF-25 default

**Files:**
- Modify: `Packages/MediaConverterCore/Sources/MediaConverterCore/ConversionSettings.swift` (`VideoCodec.defaultCRF`; `ConversionSettings.init` default `preset`; `ConversionSettings.iPhoneDefault`)
- Modify (test update): `Packages/MediaConverterCore/Tests/MediaConverterCoreTests/ArgumentBuilderTests.swift` (the one default-preset assertion)
- Test: `Packages/MediaConverterCore/Tests/MediaConverterCoreTests/ConversionSettingsTests.swift`

**Interfaces:**
- Produces: `VideoCodec.defaultCRF` → h264 20, hevc 25, av1 28, vp9 28; `ConversionSettings` default `preset` is `.slow`; `iPhoneDefault.crf == 25`.
- Consumes: existing `VideoCodec`, `EncoderPreset`, `ConversionSettings`.

- [ ] **Step 1: Write the failing tests** (add to `ConversionSettingsTests`)

```swift
func testQualityMatchedDefaultCRF() {
    XCTAssertEqual(VideoCodec.h264.defaultCRF, 20)
    XCTAssertEqual(VideoCodec.hevc.defaultCRF, 25)
    XCTAssertEqual(VideoCodec.av1.defaultCRF, 28)
    XCTAssertEqual(VideoCodec.vp9.defaultCRF, 28)
}

func testDefaultsAreSlowAndCRF25() {
    let s = ConversionSettings.iPhoneDefault
    XCTAssertEqual(s.crf, 25)
    XCTAssertEqual(s.preset, .slow)
    // unspecified preset also defaults to slow
    XCTAssertEqual(ConversionSettings(container: .mp4, videoCodec: .h264, audioCodec: .aac, crf: 20).preset, .slow)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MediaConverterCore --filter ConversionSettingsTests/testQualityMatchedDefaultCRF`
Expected: FAIL (current values 23/28/30/31; preset default medium).

- [ ] **Step 3: Update `ConversionSettings.swift`**

In `VideoCodec.defaultCRF`:

```swift
    public var defaultCRF: Int {
        switch self {
        case .h264: return 20
        case .hevc: return 25
        case .av1:  return 28
        case .vp9:  return 28
        case .copy, .none: return 20
        }
    }
```

Change the `init` default `preset` parameter to `.slow`:

```swift
    public init(container: Container, videoCodec: VideoCodec, audioCodec: AudioCodec,
                crf: Int, channels: AudioChannels = .source,
                audioBitrate: AudioBitrate = .auto, useHardware: Bool = false,
                preset: EncoderPreset = .slow) {
```

Update `iPhoneDefault` to CRF 25:

```swift
    public static let iPhoneDefault = ConversionSettings(
        container: .mp4, videoCodec: .hevc, audioCodec: .aac, crf: 25)
```

- [ ] **Step 4: Update the one affected ArgumentBuilder test**

In `ArgumentBuilderTests.swift`, `testH264SoftwareToMP4` constructs settings without an explicit preset, so its expected args must change `medium` → `slow`:

```swift
        XCTAssertEqual(args, [
            "-hide_banner", "-y", "-i", "/in.mov",
            "-c:v", "libx264", "-preset", "slow", "-crf", "23", "-pix_fmt", "yuv420p", "-profile:v", "high",
            "-c:a", "aac",
            "-movflags", "+faststart", "/out.mp4"
        ])
```

(The codec is constructed with explicit `crf: 23` there, so `defaultCRF` changes don't affect this array — only the preset string does.)

- [ ] **Step 5: Run the full suite to verify it passes**

Run: `swift test --package-path Packages/MediaConverterCore`
Expected: PASS — all tests green (the `videoCodecChanged`/`containerChanged` tests reference `defaultCRF` by property, so they adapt automatically).

- [ ] **Step 6: Commit**

```bash
git add Packages/MediaConverterCore/Sources/MediaConverterCore/ConversionSettings.swift Packages/MediaConverterCore/Tests/MediaConverterCoreTests/ConversionSettingsTests.swift Packages/MediaConverterCore/Tests/MediaConverterCoreTests/ArgumentBuilderTests.swift
git commit -m "feat: quality-matched per-codec CRF (h264 20/hevc 25/av1 28/vp9 28) + slow preset default"
```

---

### Task 3: Source-aware default audio codec

**Files:**
- Modify: `Packages/MediaConverterCore/Sources/MediaConverterCore/ConversionSettings.swift` (add static helper) and `ConversionViewModel.swift` (apply on first load)
- Test: `Packages/MediaConverterCore/Tests/MediaConverterCoreTests/ConversionViewModelTests.swift`

**Interfaces:**
- Produces: `static func ConversionSettings.recommendedAudioCodec(forSource: MediaInfo) -> AudioCodec`; `ConversionViewModel.loadFiles` sets `settings.audioCodec` from the first file on a fresh load.
- Consumes: `MediaInfo`, `AudioCodec`, the existing `loadFiles`.

- [ ] **Step 1: Write the failing tests** (add to `ConversionViewModelTests`)

```swift
func testRecommendedAudioCodec() {
    XCTAssertEqual(ConversionSettings.recommendedAudioCodec(forSource: MediaInfo(audioCodecName: "aac")), .copy)
    XCTAssertEqual(ConversionSettings.recommendedAudioCodec(forSource: MediaInfo(audioCodecName: "mp3")), .aac)
    XCTAssertEqual(ConversionSettings.recommendedAudioCodec(forSource: MediaInfo(audioCodecName: nil)), .aac)
}

func testFreshLoadSetsAudioDefaultFromSource() async {
    let vm = ConversionViewModel(
        engine: FakeEngine(),
        probe: { _ in MediaInfo(durationSeconds: 5, videoCodecName: "h264", audioCodecName: "aac") },
        toolsAvailable: true, fileExists: { _ in false })
    XCTAssertEqual(vm.settings.audioCodec, .aac)            // static default before load
    await vm.loadFiles([URL(fileURLWithPath: "/a.mov")])
    XCTAssertEqual(vm.settings.audioCodec, .copy)           // source is aac → Copy on fresh load
}

func testSecondLoadDoesNotOverrideAudio() async {
    let vm = ConversionViewModel(
        engine: FakeEngine(),
        probe: { _ in MediaInfo(durationSeconds: 5, videoCodecName: "h264", audioCodecName: "aac") },
        toolsAvailable: true, fileExists: { _ in false })
    await vm.loadFiles([URL(fileURLWithPath: "/a.mov")])    // → .copy
    vm.settings.audioCodec = .mp3                            // user override
    await vm.loadFiles([URL(fileURLWithPath: "/b.mov")])    // not a fresh load
    XCTAssertEqual(vm.settings.audioCodec, .mp3, "subsequent loads must not override the user's audio choice")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MediaConverterCore --filter ConversionViewModelTests/testRecommendedAudioCodec`
Expected: FAIL (`recommendedAudioCodec` not defined).

- [ ] **Step 3: Add the helper** (in `ConversionSettings.swift`)

```swift
extension ConversionSettings {
    /// Audio codec to default to for a freshly-loaded source: Copy when the source audio is
    /// already AAC (avoid a needless re-encode), otherwise AAC.
    public static func recommendedAudioCodec(forSource source: MediaInfo) -> AudioCodec {
        source.audioCodecName == "aac" ? .copy : .aac
    }
}
```

- [ ] **Step 4: Apply it on a fresh load** (in `ConversionViewModel.loadFiles`)

```swift
    public func loadFiles(_ urls: [URL]) async {
        let wasEmpty = items.isEmpty
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
        // On a fresh load (list was empty), default the audio codec from the first source.
        if wasEmpty, let first = items.first?.info {
            settings.audioCodec = ConversionSettings.recommendedAudioCodec(forSource: first)
        }
    }
```

- [ ] **Step 5: Run the full suite to verify it passes**

Run: `swift test --package-path Packages/MediaConverterCore`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/MediaConverterCore/Sources/MediaConverterCore/ConversionSettings.swift Packages/MediaConverterCore/Sources/MediaConverterCore/ConversionViewModel.swift Packages/MediaConverterCore/Tests/MediaConverterCoreTests/ConversionViewModelTests.swift
git commit -m "feat: default audio to Copy when source is already AAC, else AAC"
```

---

### Task 4: ContainerAppLocator (extension → app URL)

**Files:**
- Create: `Packages/MediaConverterCore/Sources/MediaConverterCore/ContainerAppLocator.swift`
- Test: `Packages/MediaConverterCore/Tests/MediaConverterCoreTests/ContainerAppLocatorTests.swift`

**Interfaces:**
- Produces: `enum ContainerAppLocator { static func appURL(fromExtensionBundleURL: URL) -> URL? }`. Consumed by the extension (Task 6).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MediaConverterCore

final class ContainerAppLocatorTests: XCTestCase {
    func testDerivesContainerAppURL() {
        let ext = URL(fileURLWithPath: "/Apps/MediaConverter.app/Contents/PlugIns/ConvertQuickAction.appex")
        let app = ContainerAppLocator.appURL(fromExtensionBundleURL: ext)
        XCTAssertEqual(app?.path, "/Apps/MediaConverter.app")
    }
    func testReturnsNilForUnexpectedShape() {
        let bad = URL(fileURLWithPath: "/a/b/c/d")
        XCTAssertNil(ContainerAppLocator.appURL(fromExtensionBundleURL: bad))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/MediaConverterCore --filter ContainerAppLocatorTests`
Expected: FAIL (`ContainerAppLocator` not defined).

- [ ] **Step 3: Write `ContainerAppLocator.swift`**

```swift
import Foundation

public enum ContainerAppLocator {
    /// Given an embedded extension's bundle URL (…/MyApp.app/Contents/PlugIns/Ext.appex),
    /// return the containing `.app` URL, or nil if the path isn't of that shape.
    public static func appURL(fromExtensionBundleURL bundleURL: URL) -> URL? {
        let appURL = bundleURL
            .deletingLastPathComponent()   // …/Contents/PlugIns
            .deletingLastPathComponent()   // …/Contents
            .deletingLastPathComponent()   // …/MyApp.app
        return appURL.pathExtension == "app" ? appURL : nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/MediaConverterCore --filter ContainerAppLocatorTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/MediaConverterCore/Sources/MediaConverterCore/ContainerAppLocator.swift Packages/MediaConverterCore/Tests/MediaConverterCoreTests/ContainerAppLocatorTests.swift
git commit -m "feat: derive container app URL from an embedded extension bundle path"
```

---

### Task 5: Make the app open media files (delegate + doc types)

**Files:**
- Create: `App/AppModel.swift`, `App/AppDelegate.swift`
- Modify: `App/MediaConverterApp.swift` (use the shared model + delegate adaptor), `project.yml` (app `CFBundleDocumentTypes`)

**Interfaces:**
- Consumes: `ConversionViewModel`, `FFmpegLocator`, `MediaProbe`, `FFmpegConversionEngine`.
- Produces: `AppModel.shared.viewModel` (the single shared view model); the app receives opened file URLs via `application(_:open:)`.

> No unit tests — verification is a build + an `open -a` smoke test (the file-open path can't be unit-tested meaningfully). Steps replace the test cycle with build-and-drive.

- [ ] **Step 1: Create `App/AppModel.swift`** (moves the view-model construction out of the App)

```swift
import Foundation
import MediaConverterCore

@MainActor
final class AppModel {
    static let shared = AppModel()
    let viewModel: ConversionViewModel

    private init() {
        if let tools = FFmpegLocator.locate() {
            let probe = MediaProbe(ffprobe: tools.ffprobe)
            viewModel = ConversionViewModel(
                engine: FFmpegConversionEngine(ffmpeg: tools.ffmpeg),
                probe: { try await probe.probe($0) },
                toolsAvailable: true)
        } else {
            viewModel = ConversionViewModel(
                engine: NoopEngine(),
                probe: { _ in MediaInfo() },
                toolsAvailable: false)
        }
    }
}

private final class NoopEngine: ConversionEngineProtocol {
    func convert(input: URL, output: URL, settings: ConversionSettings, source: MediaInfo,
                 onProgress: @escaping (Double) -> Void) async throws {}
    func cancel() {}
}
```

- [ ] **Step 2: Create `App/AppDelegate.swift`**

```swift
import AppKit
import MediaConverterCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            await AppModel.shared.viewModel.loadFiles(urls)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}
```

- [ ] **Step 3: Rewrite `App/MediaConverterApp.swift`** to use the shared model + delegate

```swift
import SwiftUI
import MediaConverterCore

@main
struct MediaConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppModel.shared.viewModel

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 420, minHeight: 460)
        }
        .windowResizability(.contentSize)
    }
}
```

(Remove the old `makeViewModel()` / `NoopEngine` from this file — they now live in `AppModel.swift`.)

- [ ] **Step 4: Declare document types in `project.yml`** (under the `MediaConverter` target's `info.properties`)

```yaml
        CFBundleDocumentTypes:
          - CFBundleTypeName: Movie
            CFBundleTypeRole: Viewer
            LSHandlerRank: Alternate
            LSItemContentTypes: [public.movie, public.audiovisual-content]
          - CFBundleTypeName: Audio
            CFBundleTypeRole: Viewer
            LSHandlerRank: Alternate
            LSItemContentTypes: [public.audio]
```

- [ ] **Step 5: Build**

Run:
```bash
xcodegen generate && xcodebuild -project MediaConverter.xcodeproj -scheme MediaConverter -configuration Debug build CODE_SIGNING_ALLOWED=NO
```
Expected: `** BUILD SUCCEEDED **`. Fix any compile error (e.g., if Swift concurrency objects to `@StateObject = AppModel.shared.viewModel`, the build will say so — resolve while keeping the shared single instance).

- [ ] **Step 6: Manual smoke test — open a file into the app**

Run:
```bash
APP=$(xcodebuild -project MediaConverter.xcodeproj -scheme MediaConverter -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d"/"n}')
mkdir -p "$HOME/Desktop/MediaConverterDemo"
ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc=size=320x240:rate=30:duration=2" -f lavfi -i "sine=frequency=440:duration=2" -shortest -c:v libx264 -c:a aac -y "$HOME/Desktop/MediaConverterDemo/open-test.mov"
open -a "$APP" "$HOME/Desktop/MediaConverterDemo/open-test.mov"
```
Verify by hand: the app launches (or comes forward) with `open-test.mov` already in its file list (status reaches `video: h264 · audio: aac`), and — because the source is AAC — the Audio control shows **Copy**. Also confirm MediaConverter now appears under Finder → right-click → **Open With** for a video file.

- [ ] **Step 7: Commit**

```bash
git add App/AppModel.swift App/AppDelegate.swift App/MediaConverterApp.swift project.yml
git commit -m "feat: app opens media files via application(_:open:) and shared AppModel"
```

---

### Task 6: ConvertQuickAction extension (the Finder Quick Action)

**Files:**
- Create: `Extension/ActionRequestHandler.swift`, `Extension/Info.plist` (authored via `project.yml`), `Extension/ConvertQuickAction.entitlements`
- Modify: `project.yml` (add the `ConvertQuickAction` app-extension target; embed it in the app)

**Interfaces:**
- Consumes: `ContainerAppLocator.appURL(fromExtensionBundleURL:)` (Task 4); the app's `application(_:open:)` (Task 5).
- Produces: the embedded `.appex` that vends the "Convert Media" Quick Action.

> Manual-QA task (Finder integration is not unit-testable). Concrete code below, then a build + verify-and-adjust loop with specific fallbacks.

- [ ] **Step 1: Add the extension target to `project.yml`**

```yaml
targets:
  ConvertQuickAction:
    type: app-extension
    platform: macOS
    sources: [Extension]
    dependencies:
      - package: MediaConverterCore
    info:
      path: Extension/Info.plist
      properties:
        CFBundleDisplayName: Convert Media
        NSExtension:
          NSExtensionPointIdentifier: com.apple.services
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).ActionRequestHandler
          NSExtensionAttributes:
            NSExtensionServiceRoleType: NSExtensionServiceRoleTypeEditor
            NSExtensionServiceAllowsFinderPreviewItem: true
            NSExtensionServiceFinderPreviewLabel: Convert Media
            NSExtensionServiceFinderPreviewIconName: NSActionTemplate
            NSExtensionServiceToolbarPaletteLabel: Convert Media
            NSExtensionActivationRule: >-
              SUBQUERY(extensionItems, $item,
                SUBQUERY($item.attachments, $att,
                  ANY $att.registeredTypeIdentifiers UTI-CONFORMS-TO "public.audiovisual-content"
                  OR ANY $att.registeredTypeIdentifiers UTI-CONFORMS-TO "public.audio"
                ).@count == $item.attachments.@count
              ).@count == extensionItems.@count
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.emizuki.MediaConverter.ConvertQuickAction
        CODE_SIGN_ENTITLEMENTS: Extension/ConvertQuickAction.entitlements
        CODE_SIGN_STYLE: Automatic
        CODE_SIGN_IDENTITY: "-"
        SWIFT_VERSION: "5.0"
        SKIP_INSTALL: NO
```

And add the embed dependency to the existing `MediaConverter` target:

```yaml
    dependencies:
      - package: MediaConverterCore
      - target: ConvertQuickAction
        embed: true
```

- [ ] **Step 2: Create `Extension/ConvertQuickAction.entitlements`** (extensions must be sandboxed)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 3: Create `Extension/ActionRequestHandler.swift`**

```swift
import Foundation
import AppKit
import UniformTypeIdentifiers
import MediaConverterCore

final class ActionRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let providers = context.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let resolved: URL?
                switch item {
                case let u as URL: resolved = u
                case let data as Data: resolved = URL(dataRepresentation: data, relativeTo: nil)
                default: resolved = nil
                }
                if let resolved, resolved.isFileURL {
                    lock.lock(); urls.append(resolved); lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            defer { context.completeRequest(returningItems: context.inputItems, completionHandler: nil) }
            guard !urls.isEmpty,
                  let appURL = ContainerAppLocator.appURL(fromExtensionBundleURL: Bundle.main.bundleURL)
            else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config, completionHandler: nil)
        }
    }
}
```

- [ ] **Step 4: Generate + build (ad-hoc signed — do NOT disable signing)**

Run:
```bash
xcodegen generate && xcodebuild -project MediaConverter.xcodeproj -scheme MediaConverter -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`, and the built `MediaConverter.app/Contents/PlugIns/ConvertQuickAction.appex` exists:
```bash
APP=$(xcodebuild -project MediaConverter.xcodeproj -scheme MediaConverter -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d"/"n}')
ls -d "$APP/Contents/PlugIns/ConvertQuickAction.appex" && codesign -dv "$APP/Contents/PlugIns/ConvertQuickAction.appex" 2>&1 | head -3
```

- [ ] **Step 5: Register + enable, then verify in Finder (manual)**

```bash
open "$APP"      # registers the app + extension with Launch Services; quit it after it appears
```
Then, by hand:
1. System Settings → Privacy & Security → Extensions → **Finder** → enable **Convert Media**.
2. In Finder, right-click `~/Desktop/MediaConverterDemo/open-test.mov` → **Quick Actions** → **Convert Media**.
3. Expected: MediaConverter comes forward **pre-loaded** with that file → pick settings → Convert.
4. Repeat for an audio file (e.g. make `open-test.m4a`), a multi-file selection, and a file on the Desktop (must not trigger a TCC prompt — the open grant covers it).
5. Confirm the action does **not** appear on a non-media file (e.g. a `.txt`).

- [ ] **Step 6: Verify-and-adjust loop (only if Step 5 fails)**

- Quick Action absent from the menu → confirm the System Settings toggle; re-register: `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"`; if still absent, copy the app to `/Applications` and re-run; double-check `NSExtensionPointIdentifier` is `com.apple.services` and the activation-rule predicate is valid (a malformed predicate silently disables the action).
- Appears but files don't reach the app → confirm `ContainerAppLocator.appURL(...)` resolves to the real app (log `Bundle.main.bundleURL`); if `loadItem(forTypeIdentifier: UTType.fileURL.identifier)` yields no URLs, switch to `loadInPlaceFileRepresentation(forTypeIdentifier: UTType.item.identifier)` and capture the in-place URL; if `NSWorkspace.open` is blocked, the `com.apple.security.files.user-selected.read-only` entitlement (Step 2) is what permits access — confirm it's present.
- Files disappear from Finder after running → ensure `completeRequest(returningItems: context.inputItems, …)` returns the inputs unchanged.

- [ ] **Step 7: Commit**

```bash
git add project.yml Extension/
git commit -m "feat: Finder Quick Action extension hands selected media to the app"
```

---

## Self-Review (completed during authoring)

- **Spec coverage:** Action Extension + handoff → Task 6; app receives files → Task 5; bitrate to 640 → Task 1; per-codec CRF + slow + CRF-25 default → Task 2; source-aware audio default → Task 3; `ContainerAppLocator` → Task 4; video+audio activation rule → Task 6 Info.plist; testing (pure units + manual QA) → spread across tasks with Task 5/6 manual checklists. Out-of-scope items (settings persistence, one-click, App Group/URL scheme, bundling/notarization) are not implemented — correct.
- **Placeholder scan:** every code step has complete code; commands have expected output; the only deliberately open parts are the Task 6 verify-and-adjust fallbacks, which are explicit (this is inherent Finder-integration uncertainty the spec flagged, not vague hand-waving).
- **Type consistency:** `ConversionSettings.recommendedAudioCodec(forSource:)`, `ContainerAppLocator.appURL(fromExtensionBundleURL:)`, `AppModel.shared.viewModel`, `VideoCodec.defaultCRF`, `EncoderPreset.slow`, and the existing `loadFiles`/`ConversionEngineProtocol.convert` signatures are used identically across tasks and match Plan 1.
- **Known risk carried into manual QA:** exact `NSExtensionActivationRule` predicate, `NSExtensionServiceRoleType`, and `NSItemProvider` loading API are verified empirically in Task 6 Steps 5–6 with concrete fallbacks (the spec called these out).
