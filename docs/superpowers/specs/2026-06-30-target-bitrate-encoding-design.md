# Target-Bitrate (2-Pass) Encoding — Design

**Date:** 2026-06-30

## Goal

Add a second video rate-control mode to Recodec: alongside the current
**Quality (CRF)** mode, let the user target a specific **video bitrate (kbps)**,
encoded with **2-pass** software encoding for accuracy, with a live estimated
output-size readout. CRF remains the default mode at all times.

## Motivation

CRF targets constant perceptual quality but produces unpredictable file sizes.
Users who need a small or specific-size file (sharing a clip, fitting an upload
limit — the YTS-style workflow) want to pin the bitrate instead. ffmpeg's
software encoders (x264/x265/SVT-AV1/libvpx-vp9) do this accurately with 2-pass.
VideoToolbox (hardware) can target a bitrate too, but only single-pass — it
cannot 2-pass — so bitrate mode stays available on hardware and only the **2-pass**
option is gated to software encoders.

## Scope

In scope: a Quality/Bitrate mode switch, a kbps input, an estimated-size
readout, an optional **2-pass** toggle (software only), single-pass hardware
bitrate, and disabling 2-pass under VideoToolbox.

Out of scope (YAGNI): target-file-size input (user chose direct bitrate),
CBR/`-maxrate`/`-bufsize` caps, and per-file size estimates for batches beyond
the first file.

## Design

### Model — `ConversionSettings`

- `enum RateControl { case quality, bitrate }`, stored as `rateControl`,
  **defaulting to `.quality`** (CRF). The default never changes to bitrate.
- `videoBitrateKbps: Int`, default `2000`.
- `twoPass: Bool`, default `true`. Effective 2-pass =
  `rateControl == .bitrate && twoPass && !useHardware` (software encoders only);
  VideoToolbox always encodes single-pass.
- A pure helper for the readout:
  `estimatedOutputBytes(videoKbps: Int, audioKbps: Int, durationSeconds: Double) -> Int`
  = `(videoKbps + audioKbps) * 1000 / 8 * durationSeconds`.

Bitrate mode only applies to software-encodable video codecs (the same set that
report `supportsCRF`: h264, hevc, av1, vp9). For copy / none / ProRes, and for
GIF / audio-only containers, `rateControl` is ignored and treated as `.quality`.

### ArgumentBuilder — return `[[String]]`

`build(...)` returns a list of ffmpeg commands instead of one. CRF, copy, none,
ProRes, GIF, and audio-only are unchanged — today's output wrapped in a
single-element array.

Bitrate mode (`rateControl == .bitrate`, software-encodable video codec)
replaces `-crf` (and VP9's `-b:v 0`) with `-b:v <k>k` and branches on the
encoder and 2-pass:

- **Software, 2-pass on → two commands** sharing a caller-provided
  `-passlogfile <p>`:
  - **Pass 1:** `-c:v <sw> -b:v <k>k <preset> -pass 1 -passlogfile <p> -an -f null /dev/null`
  - **Pass 2:** `-c:v <sw> -b:v <k>k <preset> -pass 2 -passlogfile <p> <pix_fmt/profile/tag> <audio> <faststart> <output>`
- **Software, 2-pass off → one command:** `-c:v <sw> -b:v <k>k <preset> <pix_fmt/profile/tag> <audio> <faststart> <output>` (single-pass ABR).
- **VideoToolbox → one command:** `-c:v <hw> -b:v <k>k <pix_fmt/profile/tag> <audio> <faststart> <output>` — single-pass hardware bitrate, using `-b:v` in place of the quality path's `-q:v`.

`-pix_fmt yuv420p`, H.264 `-profile:v high`, and HEVC `hvc1` tagging carry over
from the existing path; pass 1 drops audio. `build` gains a passlog-prefix
parameter (supplied by the engine so the builder stays free of filesystem side
effects); it is unused in single-command modes.

### Engine — sequential passes

`convert(...)` runs each command from the returned list in order:

- Wrap each with `-progress pipe:1 -nostats` as today and parse progress.
- Combined progress across N commands: command *i* maps its 0–1 fraction into
  `[i/N, (i+1)/N]`. So 2-pass shows pass 1 over 0–50% and pass 2 over 50–100%;
  single-command jobs are unchanged (0–100%).
- Abort the remaining commands on failure or cancel; surface the failing pass's
  error (existing error handling).
- The engine creates the passlog prefix under `NSTemporaryDirectory()` (unique
  per conversion) and deletes every file at that prefix afterward, on success or
  failure (encoders name them differently — `-0.log`, `-0.log.mbtree`, etc. — so
  clean up by prefix rather than by fixed suffix).

### UI — `ContentView`

The existing "Quality" row becomes mode-aware, shown only when the video codec
is software-encodable (the current `supportsCRF` condition):

- A segmented control: **Quality** | **Bitrate**.
- **Quality** → the existing CRF slider + "CRF NN".
- **Bitrate** → a kbps input (stepper/field) with a trailing **`≈ 85 MB`**
  estimate computed from the first loaded file's `durationSeconds`
  (`items.first?.info`). If duration is unknown, the estimate shows `—`.
  For audio: add the chosen audio bitrate when re-encoding; assume ~128 kbps
  for Copy; 0 for None. The readout is labeled `≈` (approximate).
- Bitrate mode also shows a **2-pass** toggle (default on). 2-pass needs a
  software encoder, so when *Use VideoToolbox* is on the **2-pass** toggle is
  **disabled (grayed)** and encoding falls back to single-pass hardware bitrate.
  Bitrate mode and VideoToolbox are **not** mutually exclusive — only the 2-pass
  option is gated by hardware.

The iPhone-ready badge and codec/container compatibility are unaffected
(bitrate is a rate-control detail, not a codec/container combination).

## Edge cases

- **Duration unknown** → bitrate mode still works (bitrate needs no duration);
  only the size estimate shows `—`.
- **Batch with mixed durations** → the estimate reflects the first file; output
  sizes scale per file. Acceptable and labeled approximate.
- **Switching codec to copy/none/ProRes** while in bitrate mode → the mode
  control disappears; on a re-encode codec it reappears in its last state.
- **Cancel during pass 1** → no pass 2; passlog cleaned up.

## Testing

- **ArgumentBuilder:** CRF/copy/none/ProRes/GIF each emit exactly one command
  (unchanged contents). Bitrate + software + 2-pass → two commands with correct
  `-pass 1/2`, shared `-passlogfile`, `-b:v <k>k` (no `-crf`), `-an` + `-f null`
  on pass 1, audio + output on pass 2. Bitrate + software + 1-pass → one command
  with `-b:v` and no `-crf`/`-pass`. Bitrate + VideoToolbox → one command using
  the hardware encoder with `-b:v` (not `-q:v`).
- **Estimate helper:** `estimatedOutputBytes` for representative inputs.
- **Settings logic:** bitrate mode is reported unavailable for
  copy/none/ProRes/GIF/audio-only; VideoToolbox-on makes effective 2-pass false
  while leaving bitrate mode active.
- **Engine/ViewModel:** with a fake engine, a 2-pass bitrate conversion runs two
  commands and reports progress spanning both, and cancel stops after pass 1; a
  single-pass bitrate conversion runs one command.
- Update existing ArgumentBuilder tests for the `[[String]]` return shape.
