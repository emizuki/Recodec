<div align="center">

<img src="App/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="120" alt="Recodec">

# Recodec

**A simple, native macOS media converter — right-click to convert video and audio into iPhone-friendly formats, powered by ffmpeg.**

<img src="docs/screenshot.png" width="760" alt="Recodec with a mixed batch: per-file iPhone-ready verdicts and an HDR clip marked for tone mapping">

</div>

## Why I built this

macOS already puts an "Encode Selected Video Files" item in the Finder right-click menu, but it's built on AVFoundation (Apple's `avconvert`), which only understands a narrow set of codecs and containers. Hand it an MKV, a WebM, an AV1 or VP9 video, or many common audio formats and it simply won't touch them — there's nothing it can do with those files.

ffmpeg, on the other hand, reads and writes almost anything. Recodec keeps the convenience of a Finder right-click but backs it with ffmpeg, so the formats Apple's converter can't open or produce just work: select files, right-click **Convert Media** (or drag them onto the window), pick a target format, and go.

## Features

- **Right-click "Convert Media"** in Finder (a macOS Service), plus drag-and-drop and an Add Files… picker.
- **Batch convert** with per-file progress.
- **Containers:** MP4, MOV, M4V, MKV, WebM, M4A, MP3, GIF, FLAC, WAV.
- **Video:** H.264, HEVC, AV1, VP9, ProRes — or **Copy** (passthrough, no re-encode).
- **Audio:** AAC, MP3, ALAC, Opus, FLAC, PCM, AC-3, E-AC-3 — or Copy.
- **Controls:** per-codec quality (CRF), encoder preset, channels (up to 7.1 where the encoder supports it), audio bitrate (up to 1536 kbps), and optional VideoToolbox hardware encoding.
- **Keep all audio and subtitle tracks** (opt-in, under **More options**) — carry every audio and subtitle stream through (and attachments, into MKV) instead of one of each, transcoding only the first audio track.
- **HDR → SDR tone mapping** — iPhone and macOS screen recordings in HDR (PQ/HLG) look washed out once shared; Recodec detects them, marks them with an **HDR → SDR** chip in the file list, and tone maps to Rec.709 on VideoToolbox.
- **Live iPhone-ready verdict, per file** — each row says whether that file comes out iPhone-ready under your current settings (and why not), and the footer counts them ("2 of 4 iPhone-ready"). With **Copy** the answer depends on the source, so a batch can mix both.
- Only codec/container combinations ffmpeg can actually mux are offered (the matrix is verified against ffmpeg, not guessed).
- **Reasons, not "Conversion failed!":** when ffmpeg cannot convert a file, its row shows the first error ffmpeg logged (the muxer's own sentence), or, for a track the container cannot hold, which track and what to do.

## HDR sources

iPhones record Dolby Vision / HLG by default, and the macOS Screenshots app
records the screen in HDR (PQ, BT.2020, 10-bit) on an HDR-capable display.
Both play back fine on the device that made them, but the moment such a clip
is re-encoded without care — or just viewed on an SDR screen — the BT.2020
pixels get interpreted as Rec.709 and the picture goes flat and grey.

Recodec reads the video's transfer function when a file is loaded, from the stream
and from the first decoded frame (HLG can be signalled only inside the bitstream, where
the stream entry never shows it). If it
is PQ or HLG the **Tone map HDR to SDR** toggle (under **More options**) switches itself on, and the
conversion runs Apple's own tone mapper (`scale_vt`, the one QuickTime uses)
on VideoToolbox before encoding: H.264 and HEVC are decoded in hardware, other
codecs by ffmpeg, and the frames are then uploaded to the GPU for the mapping
step. The output is tagged Rec.709
throughout and the HDR mastering / content light level metadata is stripped,
so players do not re-flag it as HDR. The *ambient viewing environment* side data some
iPhone clips carry is not an HDR flag and is left as it is.

Notes:

- Tone mapping needs the video re-encoded; with video **Copy** the Video column says
  so and the toggle is not shown.
- The toggle switches itself *on* when the list goes from having no HDR file to
  having one, and is never switched off automatically, so a manual choice
  survives adding more files to the batch.
- Only HDR files are tone mapped. SDR files in the same batch are converted
  exactly as they would be with the toggle off.
- The mapping runs in 10-bit 4:2:0: a 4:2:2 or 4:4:4 HDR source (ProRes) is chroma
  subsampled on the way through, even when the output codec is 4:2:2 again, and
  an alpha channel is dropped.
- It needs an ffmpeg that includes the `scale_vt` filter (the Homebrew build
  does; check with `ffmpeg -filters | grep scale_vt`). Recodec asks ffmpeg for its
  filters at launch; without `scale_vt` the toggle stays off and is disabled with a
  note, and HDR files are converted without tone mapping.
- If you mostly record for sharing, turn HDR off at the source instead:
  Screenshots app → Options → HDR, or iPhone Settings → Camera → Record Video →
  HDR Video.

## Download

Get `Recodec-X.Y.Z.zip` from [Releases](https://github.com/emizuki/Recodec/releases), unzip it and drag
`Recodec.app` to Applications. Each release is signed with a Developer ID certificate and notarized by
Apple; the `.sha256` file next to the zip checks the download (`shasum -a 256 -c Recodec-X.Y.Z.zip.sha256`).

## Requirements

- macOS 13 (Ventura) or later
- Apple silicon: the release builds are arm64 only. On an Intel Mac, build from source.
- [`ffmpeg`](https://ffmpeg.org/) installed on your machine (see below)

## Install ffmpeg (required)

Recodec needs `ffmpeg` and `ffprobe` available on your system:

```sh
brew install ffmpeg
```

Recodec checks for ffmpeg on launch and shows a hint if it's missing.

### Why isn't ffmpeg bundled?

Recodec is a thin, native front-end: it builds ffmpeg commands and shows you the results — it doesn't reimplement any encoding. Shipping ffmpeg *inside* the app is deliberately avoided, because:

- **ffmpeg moves fast.** Installing it through Homebrew means you get the newest codecs, fixes, and hardware support on ffmpeg's schedule — not whenever a bundled copy happens to be updated.
- **Licensing.** A full ffmpeg build (with x264/x265) is GPL; redistributing it inside an app pulls in licensing and notarization obligations that don't belong on a small tool. Recodec just *invokes* ffmpeg as a separate program, so its own code stays unencumbered.
- **Size & trust.** The app stays tiny, and you run the same ffmpeg you already trust rather than an unknown binary baked into someone else's bundle.

The trade-off is one extra step — `brew install ffmpeg`. Realistically, if you'd reach for a tool like this, you almost certainly have it already.

## Usage

1. **From Finder:** select one or more media files → right-click → **Convert Media**.
2. **Or:** open Recodec and drag files in, or click **Add Files…**.
3. Choose a format, codec, and quality; keep an eye on the **iPhone-ready** badge.
4. Click **Convert**. Converted files are written next to the originals.

Files can be removed individually or with **Clear All** while metadata is loading. Results arriving after a file is removed are ignored.

## Build from source

Recodec uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project, and keeps its logic in a Swift package (`MediaConverterCore`) covered by tests.

```sh
brew install xcodegen ffmpeg
xcodegen generate          # creates Recodec.xcodeproj (git-ignored)
open Recodec.xcodeproj      # build & run in Xcode

# run the core tests
cd Packages/MediaConverterCore && swift test
```

## License

Recodec's own source is released under the MIT License. ffmpeg is separate software under its own license (LGPL/GPL) and is **not** bundled — Recodec calls the copy you install.
