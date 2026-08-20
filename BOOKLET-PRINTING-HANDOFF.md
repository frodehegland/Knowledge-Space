# Booklet printing — receiving the hand-off from Author

*For the Claude working on Knowledge Space. Written from Author's side
(19 August 2026). Two files have been copied into `Knowledge Space/`
(the macOS target's synchronized folder), so they are already compiling
— the macOS build was verified green with them in place. What remains
is wiring the UI.*

## What arrived

- `Knowledge Space/BookletImposer.swift`
- `Knowledge Space/EPUBBookletRenderer.swift`

Both are **verbatim copies of Author's canonical versions** at
`Liquid Author/Publishing/` in the author_mac repo. Keep them
byte-identical: fix bugs in Author first, then re-copy. They are
self-contained (CoreGraphics, PDFKit, Compression, TextKit) — no
Author types, no new package dependencies.

## What they do

- `BookletImposer.imposed(from: PDFDocument, footerTitle: String?)`
  → a new PDFDocument of landscape sheets, two pages up, saddle-stitch
  order, padded to a multiple of four. Print double-sided flipped on
  the **short edge**, fold the stack in half, and it reads as a book.
  The footer prints the document's title small and gray at the foot of
  every page — deliberate groundwork for the coming hold-paper-up-to-
  the-camera feature, so a physical page can name its source.

- `BookletImposer.runPrintOperation(for:jobTitle:window:)` (macOS only)
  → runs the print panel preset to landscape, borderless, two-sided
  with short-edge flip. The panel stays up so the person can confirm.

- `EPUBBookletRenderer.pdfDocument(fromEPUBAt: URL)` → paginates an
  .epub onto A4 portrait pages in spine order, ready for the imposer.
  **Main thread only** (the HTML importer requires it). Contains its
  own minimal zip reader — stored and raw-deflate entries, sizes from
  the central directory, container.xml found anywhere in the tree so
  folder-wrapped zips work.

## Suggested wiring

Knowledge Space already holds a library of EPUBs. On any library item
(and any PDF the app can reach):

```swift
let source: PDFDocument? = url.pathExtension.lowercased() == "epub"
    ? EPUBBookletRenderer.pdfDocument(fromEPUBAt: url)
    : PDFDocument(url: url)
let title = url.deletingPathExtension().lastPathComponent
if let source, let booklet = BookletImposer.imposed(from: source, footerTitle: title) {
    BookletImposer.runPrintOperation(for: booklet, jobTitle: title, window: someWindow)
}
```

A context-menu item ("Print Booklet…") on the library entry is the
natural door. Failure should say plainly the file could not be laid
out as pages — never a silent nothing.

## Platform notes

- The main Knowledge Space target is macOS: printing works as above.
- The iOS target has its own synchronized folder (`Knowledge Space
  iOS/`); the same two files compile there unchanged (the code is
  platform-guarded), but print via `UIPrintInteractionController` with
  the imposed PDF's `dataRepresentation()` instead of
  `runPrintOperation`.
- visionOS cannot print at all. If booklets are ever wanted from the
  Augmented Library extension, impose to a PDF and share/save it; the
  imposition code runs there as-is.

## Verified on Author's side

- Imposition order checked empirically: solid-color pages rendered and
  sampled per sheet half — 4 pages → front [4|1], back [2|3]; 5 pages
  pad to 8 with blanks landing on the correct faces.
- EPUB path checked end to end with a generated two-chapter EPUB:
  spine order honored over manifest order, multi-page pagination,
  footer present on both halves of every sheet.
- Not yet verified anywhere: a physical duplex print on a real printer
  (whether the short-edge preset survives specific drivers).

## Received — Knowledge Space side (19 August 2026)

Wired as suggested: **Print Booklet…** sits in the context menu of both
file shelves — every PDF on the PDF shelf, and every EPUB on the EPUB
shelf (imported works print from their companion .epub; files not yet
imported print directly). The shared door is `printBooklet(from:state:)`
in `Views/FileShelvesView.swift`; failure lands as the app's transient
notice, never a silent nothing. macOS build verified green. A physical
duplex print remains unverified here too.
