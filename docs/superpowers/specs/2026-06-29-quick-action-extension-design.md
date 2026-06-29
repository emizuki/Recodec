# Design: Finder Quick Action Extension (Plan 2)

**Date:** 2026-06-29
**Status:** Approved (brainstorming complete)
**Builds on:** Plan 1 — the MediaConverter app + `MediaConverterCore` package (merged to `main`).

## Goal

Add a Finder **Quick Action** named "Convert Media." When the user selects video/audio file(s) in
Finder and triggers it, the existing MediaConverter app opens **pre-loaded with those files**, so the
user picks container/codec/preset and converts — the window already validated in Plan 1.

Bundled into the same work: a set of converter-default refinements (smarter defaults + a wider audio
bitrate range) that touch the app's load path, which Plan 2 modifies anyway.

## Locked decisions (from brainstorming)

- **Mechanism:** a macOS **Action Extension** (`.appex`), Apple's native Quick Action path. It appears in
  Finder's Quick Actions list and Preview pane and is enabled in **System Settings → Privacy & Security →
  Extensions → Finder**. The extension is a **thin pass-through** — it does NOT run ffmpeg (extensions are
  sandboxed/short-lived, and an in-place action that doesn't return every input file makes Finder delete
  them). The engine + UI stay in the non-sandboxed app.
- **Handoff (verified):** the extension calls
  `NSWorkspace.shared.open(urls, withApplicationAt: containerAppURL, configuration:)` to open the selected
  files *with* the container app. This method (`openURLs:withApplicationAtURL:configuration:completionHandler:`)
  carries **no `NS_EXTENSION_UNAVAILABLE` marker** in the macOS 26.5 SDK, so a sandboxed extension may call
  it. A user-initiated open grants the app access to exactly those files → **no App Group, no URL scheme, no
  security-scoped bookmarks, no TCC prompts** for Desktop/Documents/Downloads. Bonus: making the app
  file-openable also lists it in Finder's **"Open With"** for video/audio.
- **Behavior:** Quick Action → app opens pre-loaded with the files → user picks settings → Convert.
  No immediate/one-click conversion; no settings persistence (both explicitly out of scope for v1).
- **File types:** video **and** audio. The activation rule scopes the action to files conforming to
  `public.movie` / `public.audiovisual-content` **or** `public.audio`.

## Architecture & data flow

```
MediaConverter.xcodeproj   (XcodeGen)
├─ MediaConverter            app (existing) — gains file-open handling
│   └─ AppDelegate.application(_:open:[URL]) → ConversionViewModel.loadFiles(urls) + bring window forward
└─ ConvertQuickAction.appex  NEW Action Extension (sandboxed), embedded in App.app/Contents/PlugIns/
    └─ ActionRequestHandler.beginRequest(with:)
```

```
Finder: select video/audio file(s) → right-click → Quick Actions → "Convert Media"
   │   (enabled once in System Settings → Privacy & Security → Extensions → Finder)
   ▼
ConvertQuickAction.appex — beginRequest(with context:)
   • read file URLs from context.inputItems → NSItemProvider attachments
   • compute the container app URL from the extension's own bundle path
   • NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration:)
   • context.completeRequest(returningItems: context.inputItems)   ← return inputs so Finder won't delete them
   ▼
MediaConverter.app — application(_:open: [URL])   (via NSApplicationDelegateAdaptor)
   • route URLs → ConversionViewModel.loadFiles(urls); activate + bring the window to front
   ▼
Existing window: defaults pre-filled → pick container/codec/preset → Convert
```

## Components & file structure

```
project.yml                                   + ConvertQuickAction target, embedded in the app
Packages/MediaConverterCore/Sources/MediaConverterCore/
├─ ConversionSettings.swift                   bitrate presets → +384/448/512/640; per-codec defaultCRF
│                                             (h264 20, hevc 25, av1 28, vp9 28); default preset → .slow;
│                                             default settings → mp4 / hevc / aac / crf 25 / slow / source / auto / hw off
├─ ConversionViewModel.swift                  recommendedAudioCodec(forSource:) + apply on first load
└─ ContainerAppLocator.swift  (new)           pure: appURL(fromExtensionBundleURL:) — strips
                                              /Contents/PlugIns/<name>.appex → the .app URL  (unit-tested)
App/
├─ MediaConverterApp.swift                    + @NSApplicationDelegateAdaptor; share the view model with the delegate
├─ AppDelegate.swift          (new)           application(_:open:[URL]) → loadFiles + NSApp.activate + window front
└─ Info.plist                                 + CFBundleDocumentTypes for video/audio UTIs (also enables "Open With")
Extension/   (new target ConvertQuickAction.appex — sandboxed)
├─ ActionRequestHandler.swift                 NSObject, NSExtensionRequestHandling; beginRequest (see data flow)
├─ Info.plist                                 NSExtension dict: finder-action point id, principal class,
│                                             NSExtensionActivationRule (video+audio), Finder preview label/icon
└─ ConvertQuickAction.entitlements            com.apple.security.app-sandbox = YES (required for extensions)
```

### Sharing the view model with the AppDelegate

The SwiftUI `@main` App owns the `ConversionViewModel` (`@StateObject`). The `NSApplicationDelegateAdaptor`'s
delegate needs the same instance to route opened files. Use a single shared reference (e.g. an `AppModel`
holding the view model, read by both the SwiftUI scene and the `AppDelegate`) so `application(_:open:)` and
the window bind to one view model. (Exact wiring pinned in the plan.)

## Conversion-default refinements (bundled)

These modify `MediaConverterCore` and supersede the Plan 1 defaults where noted.

### Audio bitrate range

`AudioBitrate.presets` becomes: **Auto, 96, 128, 160, 192, 256, 320, 384, 448, 512, 640 kbps**. Offered for
AAC/MP3/Opus (codecs where `supportsBitrate` is true). 640 is the ceiling — chiefly useful for multichannel
(e.g. AAC 5.1); it is offered for all channel layouts (not channel-gated), which keeps the UI simple.

### Per-codec default CRF (quality-matched to H.264 CRF 20)

Using H.264 CRF 20 as the quality reference, each codec's `defaultCRF` is set to deliver comparable quality:

| Codec | defaultCRF | was (Plan 1) | basis |
|---|---|---|---|
| H.264 (x264) | **20** | 23 | reference standard |
| HEVC (x265) | **25** | 28 | x265 ≈ x264 + 5 (well-established) |
| AV1 (SVT-AV1) | **28** | 30 | approximate (±2) |
| VP9 (libvpx) | **28** | 31 | approximate (±2) |

Because the per-codec defaults are now quality-matched, `videoCodecChanged()` (which resets CRF to the new
codec's `defaultCRF`) **preserves roughly the same visual quality across codec switches** instead of jumping
quality tiers.

### Default settings

Applied at launch and reflected when files load:

| Setting | Default |
|---|---|
| Container | `.mp4` |
| Video codec | `.hevc` |
| **Audio codec** | **`.copy` if the (first) source file's audio is AAC, else `.aac`** (source-aware) |
| Quality (CRF) | **25** (HEVC default = ≈ H.264 CRF 20 quality) |
| Encoder preset | **`.slow`** |
| Channels | `.source` |
| Audio bitrate | `.auto` |
| Hardware (VideoToolbox) | **off** |

The static default (no file loaded) uses `.aac`. The **source-aware audio default** is computed from the
**first** loaded file's audio codec and applied on a **fresh load** (item count goes 0 → ≥1); afterward the
audio setting is the user's to change. One shared settings panel governs the whole batch (consistent with how
the iPhone-compatibility badge already reads `items.first`).

## Activation rule (video + audio)

`NSExtensionActivationRule` scopes the Quick Action to files conforming to `public.movie` /
`public.audiovisual-content` **or** `public.audio`, so it appears only on video/audio files. The exact rule
form (a `SUBQUERY` predicate over `extensionItems` matching the UTType conformances) is pinned in the plan
against Apple's documentation and verified by the Quick Action actually appearing on the right files.

## Error handling & edge cases

- **Multi-select:** all selected files are passed in one `open(urls:…)` call; the app loads them as a batch.
- **Return inputs:** `completeRequest(returningItems: context.inputItems)` — an action that returns fewer
  items than it received signals Finder the files were consumed/transformed, and Finder deletes the missing
  ones. Always return the inputs unchanged.
- **App already running:** `open(urls:withApplicationAt:)` delivers the files to the running instance via
  `application(_:open:)`; the handler loads them and brings the window forward.
- **Non-media or unreadable file:** the activation rule keeps the action off non-media files; an unreadable
  file still flows through Plan 1's probe → `.failed("Couldn't read this file")` path.
- **`beginRequest` is synchronous** but `NSItemProvider` loading is async — collect URLs with a thread-safe
  accumulator and only call `completeRequest` once all attachments resolve.

## Testing

**Pure unit tests (`swift test`, in the package):**
- `AudioBitrate.presets` includes 384/448/512/640 and excludes nonsense.
- Per-codec `defaultCRF` equals 20 / 25 / 28 / 28 for h264 / hevc / av1 / vp9.
- `recommendedAudioCodec(forSource:)` → `.copy` when source audio is `"aac"`, `.aac` otherwise (incl. nil).
- The source-aware default is applied on a fresh load and not on subsequent loads.
- `ContainerAppLocator.appURL(fromExtensionBundleURL:)` strips `/Contents/PlugIns/<name>.appex` correctly
  (and returns nil / is robust for an unexpected path).

**Manual QA (Finder integration is not unit-testable):**
- Build → run the app once → enable "Convert Media" in System Settings → Extensions → Finder.
- Right-click a video file → Quick Actions → **Convert Media** → app opens pre-loaded → convert.
- Repeat for an audio file; for a multi-file selection; for a file on the Desktop (TCC sanity — must not
  prompt, because the open grant covers it).
- Confirm the action does **not** appear on non-media files.

## Out of scope (v1) / future

- Settings persistence ("open with last-used settings") and one-click/no-window conversion.
- Bundled ffmpeg, Developer ID signing, notarization, App Store / sandboxing the container app.
- A custom URL scheme / App Group (not needed with the open-with-app handoff).

## Risks / to verify during implementation

- **Exact `NSExtensionPointIdentifier` + activation rule.** Sources differed
  (`com.apple.services` vs `com.apple.finder.sync.extpoint.finderAction`); pin the correct Finder-action
  identifier and the precise media activation predicate, and verify the Quick Action appears on video/audio
  files only. (XcodeGen authors the Info.plist by hand — no Xcode template wizard — so these keys must be
  exact.)
- **`NSItemProvider` file-URL loading** API choice (`loadInPlaceFileRepresentation` /
  `loadFileRepresentation` / `loadItem(forTypeIdentifier:)`) and async handling within the synchronous
  `beginRequest` (use a detached task / dispatch group; thread-safe accumulation).
- **Container-app URL resolution** from the extension bundle (derive by trimming the bundle path; fall back
  to `NSWorkspace.urlForApplication(withBundleIdentifier:)`).
- **Signing/visibility.** Ad-hoc signing locally; the app must run once and the extension be toggled on in
  System Settings; the Quick Action may require the app to live in a stable location (e.g. /Applications).
