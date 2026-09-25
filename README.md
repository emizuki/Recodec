<div align="center">

<img src="App/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="120" alt="Recodec">

# Recodec

**A simple, native macOS media converter — right-click to convert video and audio into iPhone-friendly formats, powered by ffmpeg.**

<img src="docs/screenshot.png" width="760" alt="Recodec converting a mix of video and audio files">

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
- **Keep all tracks** (opt-in) — carry every audio, subtitle, and attachment stream through instead of one of each, transcoding only the first audio track.
- **HDR → SDR tone mapping** — iPhone and macOS screen recordings in HDR (PQ/HLG) look washed out once shared; Recodec detects them and tone maps to Rec.709 on VideoToolbox.
- **Live iPhone-ready badge** that reflects your current settings.
- Only codec/container combinations ffmpeg can actually mux are offered (the matrix is verified against ffmpeg, not guessed).

## Multi-track sources

By default Recodec lets ffmpeg pick the streams, which means **one video, one
audio, and one subtitle track** — ffmpeg's standard stream selection. For a
single-track source that is exactly right, and it stays the default so existing
conversions produce byte-identical output.

A disc remux is usually not a single-track source. Turn on **Streams → Keep all
tracks** and Recodec maps every stream from the input instead, copying subtitles
through untouched (they are re-muxed, never re-encoded). Chapters are preserved
either way.

Two things to know:

- The target container has to be able to hold what you map into it. MKV takes
  essentially anything; MP4 cannot store Blu-ray bitmap subtitles (PGS/VobSub)
  or SubRip, so *Keep all tracks* into MP4 will abort on a disc remux — use MKV
  for those. Audio-only targets (M4A, MP3, FLAC, WAV) and GIF drop subtitles
  automatically rather than failing the run.
- **Default subtitle** sets which subtitle track a player selects on its own. It
  needs *Keep all tracks*, because without mapping there is at most one subtitle
  track to flag. Picking a language clears the default flag on every subtitle
  stream first, then sets it on the first track matching that language — so a
  source shipping two "default" tracks does not carry the conflict through.
  Leave it on *Unchanged* to preserve whatever the source declared.

### Lossless and HD audio

The bitrate list goes to 1536 kbps and channels to 7.1, which matters when a
playback target cannot decode the source codec. The Plex tvOS client, for
example, only Direct Plays `aac`, `ac3`, and `eac3` — hand it TrueHD or FLAC and
the server transcodes, typically down to 640 kbps E-AC-3. Pre-encoding the track
yourself to E-AC-3 at 1536 kbps avoids the server-side transcode and keeps
considerably more of the source than the automatic one would.

The channel picker only offers what the selected encoder accepts, because ffmpeg
aborts on an unsupported layout rather than down-mixing. AC-3 and E-AC-3 stop at
5.1 (7.1 Dolby Digital Plus needs Dolby's own encoder, which ffmpeg does not
ship), MP3 is stereo-only, and ALAC is capped at 5.1 here — its 8-channel layout
is `7.1(wide)`, which routes the side channels to front-wide speakers and would
mislabel a standard 7.1 mix. AAC, Opus, FLAC and PCM take the full 7.1. Changing
codec clamps an out-of-range selection down rather than failing at convert time.

For genuinely lossless output, pair **Video: Copy** with **Audio: FLAC** in MKV:
the video is passed through untouched and the audio is re-encoded without loss
(ffmpeg's TrueHD decoder is bit-exact, and FLAC stores an MD5 of its source PCM
so you can verify the result).

With *Keep all tracks* on, only the **first** audio track is transcoded; the rest
are copied. A disc remux that ships a lossless primary track plus an AC-3
compatibility track keeps that second track byte-for-byte instead of re-encoding
it lossy-to-lossy at the primary track's bitrate.

## HDR sources

iPhones record Dolby Vision / HLG by default, and the macOS Screenshots app
records the screen in HDR (PQ, BT.2020, 10-bit) on an HDR-capable display.
Both play back fine on the device that made them, but the moment such a clip
is re-encoded without care — or just viewed on an SDR screen — the BT.2020
pixels get interpreted as Rec.709 and the picture goes flat and grey.

Recodec reads the video stream's transfer function when a file is loaded. If it
is PQ or HLG the **HDR → Tone map to SDR** toggle switches itself on, and the
conversion runs Apple's own tone mapper (`scale_vt`, the one QuickTime uses)
on VideoToolbox before encoding: hardware decode where the codec allows,
otherwise the software-decoded frames are uploaded to the GPU for the mapping
step. The output is tagged Rec.709 throughout and the HDR mastering / content
light level metadata is stripped, so players do not re-flag it as HDR.

Notes:

- Tone mapping needs the video re-encoded; it is greyed out for video **Copy**.
- The toggle is only ever switched *on* automatically, never off, so a manual
  choice survives adding more files to the batch. It is a no-op on SDR input.
- If you mostly record for sharing, turn HDR off at the source instead:
  Screenshots app → Options → HDR, or iPhone Settings → Camera → Record Video →
  HDR Video.

## Requirements

- macOS 13 (Ventura) or later
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
