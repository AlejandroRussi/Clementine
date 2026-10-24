# Clementine

A clean-room macOS menu bar file utility modeled on the observed behavior of
Tangerine 2.0.2 (`com.th.Tangerine`). It was built from a static survey of the
shipped bundle (Info.plist, linked frameworks, bundled resources, type names and
UI strings). No Tangerine code or resources are reused.

## Use

1. Start dragging files in Finder.
2. While dragging, tap the trigger keys (⌥ Option by default; change it in Settings).
3. Drop the files on a format or tool in the wheel. Results are saved beside the originals.

You can also drop files on the menu bar icon, or use **Choose Files…**, and then
click an action. **Float** is an always-on-top shelf for holding files and
dragging them back out. Its context menu has Copy, Copy Path, AirDrop, Move To,
Open Terminal, Quick Look and all the tools.

## Build

```bash
./build_app.sh          # -> build/Clementine.app
open build/Clementine.app
```

Optional encoders: `brew install ffmpeg webp` adds MP3/FLAC output, MKV/WebM/AVI input, and WebP output.

Headless mode, for scripting or tests:

```bash
.build/debug/Clementine --cli convert:heic photo.jpg
.build/debug/Clementine --cli compress clip.mov
```

Operations: `convert:<fmt>` (incl. `convert:pptx` for PDFs and `convert:pdf` for .pptx/.ppt/.key), `compress`, `strip`, `resize:<px>`, `ocr`, `qr`,
`combine`, `split`, `pdf2png`, `gif`, `audio`, `mute`, `zip`, `extract`.

Timeline edits: `trim:<start>-<end>`, `cut:<t1>,<t2>[:joined:<removed clip idx>,…]`,
`join`, `speed:<0.25–4>`, `crop:<x>,<y>,<w>,<h>`, `normalize[:<LUFS>[:<ceiling dB>]]`,
`channels:<mono|stereo>[:<left>,<right>]`, `silence[:<dB>]`, `loudness`.

Image edits (rects are normalized 0…1, top-left origin): `crop:<x>,<y>,<w>,<h>`,
`annotate:<marks.json>`, `redact:<x>,<y>,<w>,<h>[;…][:blur|pixelate|solid]`, `redact-auto[:style]`,
`background[:<preset 0–5|blurred|#rrggbb>[:<padding>[:<ratio>[:lift]]]]`, `collage[:<columns>[:fill|fit]]`.

In the app, single videos get **Trim / Split / Speed / Crop** targets and single audio files get
**Trim / Channels / Normalize / Trim Silence**. Two or more videos get **Join**. Each opens an
editor window with a scrubbable timeline (Space plays, B splits, Delete removes a clip).
A single image gets **Annotate / Redact / Crop / Background**; several images get **Crop** (same
share of each) and **Collage**.

A single PDF gets **Pick Pages**: click pages in a thumbnail grid (⇧-click for a run) or type
ranges like `1-3, 5, 8-`, then save them as one PDF, a PDF per page, or PNG/JPEG images.
From the CLI: `pages:<1-3,5,8->[:pdf|pdfs|png|jpg]`.

**Shred** (every file type, also in Float's menu) removes files immediately and shows an undo
banner for 30 seconds. Press ⌘Z, click Undo, or choose **Undo Shred** from the menu bar to put
them back. After that, each file is overwritten once with random data, flushed to disk and
deleted. Quitting Clementine erases anything still waiting. On SSDs and APFS, overwriting can't
guarantee old blocks are gone (copy-on-write, snapshots, wear leveling), so FileVault is what
really protects deleted data. The CLI `shred` erases right away, with no undo.

## What Tangerine does (observed) vs. what Clementine implements

| Tangerine feature (evidence: type names / UI strings) | Clementine |
|---|---|
| Menu bar agent (`LSUIElement`, `MenuBarController`) | ✅ |
| Drag + modifier tap opens conversion wheel (`DragGestureMonitor`, `DragModifierCombination`, "Conversion wheel") | ✅ no Accessibility permission needed |
| Image conversion / compression / target size (ImageIO, bundled `cwebp`) | ✅ convert + 3 compression strengths; ❌ target-size mode |
| Video/audio convert, compress, GIF, mute, extract audio (AVFoundation + bundled `ffmpeg`) | ✅ (ffmpeg optional, from Homebrew) |
| Video trim / split / join / speed / crop editors (`VideoTrimEditor`, `VideoSplitEditor`, `VideoSpeedEditor`, `CropEditor`) | ✅ AVFoundation, no ffmpeg needed |
| Audio trim with silence auto-trim, loudness normalize (-16 LUFS default, peak ceiling), Mono/Stereo channels with L/R volume | ✅ built-in BS.1770 meter; ceiling uses sample peak, not true peak |
| Audio bleep, waveform visualizer video, channel/normalized audio preview | ❌ |
| PDF combine / split / organize / to images / compress | ✅ except visual page organizer |
| Documents ↔ PDF/DOCX/RTF/TXT/HTML, Markdown | ✅ via NSAttributedString |
| PowerPoint ⇄ PDF (Tangerine bundles Java + Apache POI) | ✅ natively: PPTX → PDF via Quick Look's Office renderer + WebKit (Keynote fallback); PDF → PPTX as one page image per slide with searchable text behind it |
| EPUB, Pages (`PagesWriter.js`), spreadsheets | ❌ |
| Metadata removal / editor (bundled ExifTool) | ✅ removal via ImageIO/AVFoundation/PDFKit; ❌ field editor |
| OCR text, QR reading (Vision) | ✅ |
| Annotate (arrow, draw, highlight, box, text, magnifier), redact (blur / pixelate / solid, face & text detection), crop (incl. same crop for every image) | ✅ |
| Background frame (gradient presets, color, blurred, custom image, canvas ratio, padding, corners, shadow) and collage (fill/fit, columns, spacing) | ✅ plus "Lift subject" cutout on macOS 14+ |
| Video redaction tracks, audio redaction (bleep) | ❌ |
| Archives: zip / extract incl. RAR | ✅ (bsdtar) |
| Float shelf (`FloatingFilePanel`, paper-clip stacks, rubber-band select) | ✅ simplified list shelf |
| AirDrop, copy files/paths, move, open Terminal | ✅ |
| Launch at login (`LoginItemController`), welcome onboarding | ✅ |
| Folder access grants (sandbox security-scoped bookmarks) | n/a, this build is not sandboxed |
| Paywall / RevenueCat subscription, usage counting | ❌ deliberately omitted |
