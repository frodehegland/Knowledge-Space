# The Origami EPUB Profile — Producer's Specification

*Version origami-text/1, as implemented August 2026 by Origami Text, Augmented Library,
Reader, and Knowledge Space (one shared implementation), and read from Author's sibling
dialect. This document is self-contained: an LLM or a program following it exactly will
produce EPUBs that open in any EPUB reader and round-trip losslessly through the Origami
ecosystem. Where this document and the reference implementation disagree, the
implementation (`OrigamiEPUBExport.swift` / `OrigamiEPUBImport.swift`) is authoritative.*

*The companion document `ORIGAMI-DOCUMENT-FORMAT.md` specifies the `.liquid.json` document
model this profile serializes. You do not need it to produce a valid EPUB from this file
alone, but it explains the model's semantics.*

---

## 0. What an Origami EPUB is

An Origami EPUB holds **dual citizenship**:

1. It is a **valid EPUB 3** — any reader (Apple Books, Calibre, Thorium) opens it and shows
   readable, styled text. Nothing Origami-specific is required to read the words.
2. It is a **complete Origami document** — an Origami-aware reader recovers everything:
   every paragraph under its stable id (the hook for high-resolution addressing), heading
   levels, speaker attribution, citations with verbatim BibTeX, endnotes, glossary
   (Defined Concepts), live tables, images, stretchtext folds, and excerpt provenance.

The profile's design rule is **graceful degradation**: every Origami structure rides in
markup a plain EPUB reader renders acceptably, with the machine-readable form carried
either in attributes on that markup or in one JSON metadata file (`origami.json`).
Nothing essential lives only in a database or a filename.

The profile uses **one semantic content document** (`content.xhtml`) — not one file per
chapter. A multi-file spine is how the importer recognizes a *plain* EPUB (which it then
reads chapter by chapter); an Origami EPUB is one flow.

## 1. The container: ZIP rules

An EPUB is a ZIP archive. The profile's requirements:

- The **first entry** must be `mimetype`, **stored** (compression method 0, no ZIP extra
  field before its data), containing exactly the ASCII bytes `application/epub+zip` —
  no trailing newline, no BOM.
- Every other entry may be **stored (0) or deflated (8)**; no other compression methods.
  The reference exporter stores everything uncompressed with true CRC-32s (the standard
  ZIP polynomial, `0xEDB88320`); most general-purpose ZIP tools deflate — both are fine.
- No ZIP64: keep entries and the archive under 4 GB, entry count under 65,535.
- Entry names use forward slashes, no leading slash, no `..` segments.

Producing with standard tooling works:

```
zip -X0 book.epub mimetype
zip -rX9 book.epub META-INF OEBPS
```

## 2. Package layout

```
mimetype
META-INF/container.xml
OEBPS/content.opf
OEBPS/nav.xhtml
OEBPS/content.xhtml
OEBPS/origami.json
OEBPS/images/<file>…        (only when the document carries images)
OEBPS/data/<scene-id>.liquidinfo.json…   (only when a figure carries a scene dataset, §2.4)
```

### 2.1 `META-INF/container.xml` — verbatim

```xml
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
```

### 2.2 `OEBPS/content.opf` — the package document

```xml
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="pub-id">urn:al:DOCUMENT-ID</dc:identifier>
    <dc:title>DOCUMENT TITLE</dc:title>
    <dc:creator>AUTHOR NAME</dc:creator>
    <dc:date>YYYY-MM-DD</dc:date>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>
    <item id="origami-metadata" href="origami.json" media-type="application/json"/>
    <item id="img1" href="images/figure1.png" media-type="image/png"/>
  </manifest>
  <spine><itemref idref="content"/></spine>
</package>
```

- `DOCUMENT-ID` is the document's Origami address (see §6). The `urn:al:` prefix is the
  profile's URN namespace; keep it.
- `<dc:date>` carries the document's **human-assigned date** (the meeting's day, the
  work's publication date) at whatever precision is known — `2026-08-17`, `2026-08`, or
  `2026`. Omit the element entirely when there is none.
- One `<item>` per image file, `id` values `img1`, `img2`, … in order of first appearance.
- The spine names `content.xhtml` **first** (importers take the first `itemref` as the
  content document). Text content inside metadata elements is XML-escaped per §4.1.
- Strict validators also want `<meta property="dcterms:modified">…</meta>`; Origami
  readers neither write nor require it, but adding one is harmless.

### 2.3 `OEBPS/nav.xhtml` — the navigation document

```xml
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>DOCUMENT TITLE</title></head>
<body>
<nav epub:type="toc"><ol><li><a href="content.xhtml">DOCUMENT TITLE</a></li></ol></nav>
</body>
</html>
```

A single-entry table of contents is the profile's canonical form. A producer may add one
`<li>` per heading (linking `content.xhtml#<heading id>`) for nicer reader navigation;
Origami importers ignore nav.xhtml either way.

### 2.4 `OEBPS/data/` — scene datasets

A figure that is a **Liquid Information view** (a citable PNG carrying a `liquid-scene`
iTXt chunk) may bring its complete scene document into the package as
`OEBPS/data/<scene-id>.liquidinfo.json` — the same JSON the PNG's chunk carries, plain
text, uncompressed (the ZIP container does the compressing; a person with a text editor
does the reading). This is the durable home for scenes whose datasets are too large to
travel in a link or comfortably inside every copy of an image.

Rules:

- One file per scene, named by the scene's id, written **byte-identical to the scene's
  source at the moment of export** — never regenerated separately from the PNG's chunk,
  so the two cannot drift.
- Manifested (`media-type="application/json"`), **never in the spine** — a non-spine
  foreign resource needs no fallback and the file stays a valid EPUB everywhere:

  ```xml
  <item id="scene1" href="data/SCENE-ID.liquidinfo.json" media-type="application/json"/>
  ```

- The figure's reference-pool entry points at it with a `scene-resource` field in its
  BibTeX (§5.3) — package-relative, human-readable, ignorable by any other reader:

  ```
  scene-resource = {data/SCENE-ID.liquidinfo.json}
  ```

- The **package file is the full truth** when present. The PNG's own chunk still travels
  (the image alone must survive escaping the package); above the sender's size threshold
  the chunk may be the *trimmed* form — the scene minus its bulk point data — and the
  package file carries everything. Readers restore from the package file first, the
  chunk second, the link's `scene=` payload third.
- The scene's data points are the cited numbers: readers render from the file, never by
  re-fetching the series' `sourceURL` (that is provenance, and the reader may be
  offline).
- When a section is carved out (§5.7) or a document re-exported, a scene file travels
  whenever its figure does — treat `scene-resource` like an image reference when
  trimming pools.

## 3. `OEBPS/content.xhtml` — the content document

The frame, verbatim apart from the title and the flow:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>DOCUMENT TITLE</title></head>
<body>
<section>
…the flow: one block element per paragraph…
</section>
</body>
</html>
```

It must be **well-formed XML** (importers parse it with a strict XML parser, not an HTML
parser): every element closed, every attribute quoted, `&` `<` `>` `"` escaped in text
and attribute values (§4.1). No `<style>` or `<script>` is required; a producer may add a
`<link>`ed stylesheet (manifested) for plain-reader presentation — Origami importers
ignore styling.

### 3.1 Paragraph ids — the addressing contract

**Every block element carries an `id` attribute**, unique within the document. This is
the profile's most important rule: the id is the paragraph's *address*. A citation like
`f.hegla.093252x#p14` resolves to the element whose id is `p14`. Ids must contain no
whitespace, `#`, or `/`; the convention is `p1`, `p2`, … for paragraphs and stable
tokens for special blocks. **Never renumber ids between revisions of the same document**
— stability is what makes fine-grained citation possible.

(Importers also accept `data-id`, which wins over `id` when both are present, and invent
`p<n>` ordinals when both are missing — but a producer must always write `id`, **on
`<hr/>` too**: an invented ordinal can collide with an authored `p<n>` id. The reference
exporter currently writes rules bare; readers tolerate it, producers should not copy it.)

### 3.2 Block forms

Each Origami paragraph becomes exactly one of these, in document order:

| Origami structure | XHTML form |
|---|---|
| Heading, rank 1 | `<h2 id="…">text</h2>` |
| Heading, rank 2 | `<h3 id="…">text</h3>` |
| Heading, rank 3 (deepest) | `<h4 id="…">text</h4>` |
| Plain paragraph | `<p id="…">inline content</p>` |
| Speaker turn (first paragraph) | `<p id="…"><strong class="speaker">Name:</strong> inline content</p>` |
| Speaker turn (continuation) | `<p id="…" data-speaker="Name">inline content</p>` |
| Horizontal rule (text `---`) | `<hr id="…"/>` |
| Image | `<figure id="…"><img src="images/FILE" alt="ALT"/></figure>` |
| Table | see §3.5 |
| Stretchtext fold | see §3.6 |

Details:

- **Headings.** Ranks deeper than 3 clamp to 3 (`<h4>`). Do not emit `<h1>` — importers
  treat a leading `<h1>` matching the document title as a title echo and drop it (that is
  Author's dialect, §7). On import both `h1` and `h2` read as rank 1.
- **Heading credit.** When a section has its own writer (distinct from the document's
  author), the heading carries `data-contributing-authors="Name"` and that person is
  credited for the section.
- **Speaker turns** (transcripts, conversations). The first paragraph of a turn *leads
  with the name in the text itself* — `Name:` followed by a space — with the name wrapped
  in `<strong class="speaker">` so plain readers see **Name:** and Origami readers
  recover the `speaker` field. A turn's later paragraphs carry the name only as
  `data-speaker` (the words stay clean). The name inside the strong must end with the
  colon.
- **Images.** The `src` is relative to `content.xhtml` (`images/<file>`); the file must
  exist in the package and the manifest. Media types: `image/png`, `image/jpeg`,
  `image/gif`, `image/svg+xml`, `image/webp`. Reuse one file for repeated images. Always
  give `alt` (empty string when there is nothing to say).

### 3.3 Inline conventions

Inside headings and paragraphs, after XML-escaping the text (§4.1), these forms carry the
Origami text conventions. An Origami importer folds each back to its plain-text form
(shown right), which is how the words live in `.liquid.json`:

| Meaning | XHTML form | Origami text form |
|---|---|---|
| Bold | `<strong>…</strong>` | `**…**` |
| Italic | `<em>…</em>` | `*…*` |
| Mark (Author's highlight) | `<mark>…</mark>` | `==…==` |
| Code | `<code>…</code>` | `` `…` `` |
| Web link | `<a href="https://…">label</a>` | `[label](https://…)` |
| Citation | see §3.4 | `[cite:key]` |
| Endnote dagger | see §3.4 | `[note:id]` |

Do not nest the emphasis forms; do not let a `<strong>`/`<em>`/`<mark>` run begin or end
on whitespace (put the space outside the element). Importers also read `<b>` as bold,
`<i>` as italic, and unwrap `<dfn>`, but a producer emits only the forms above.

### 3.4 Citations and endnotes

**A citation** points at an entry in the reference pool (§5.3) by key. The anchor carries
the key in `data-citation-key` and the entry's 1-based place in the reference list in
`data-citation-number`; the visible label is the number, bracketed — `[1]` — the one
form every EPUB reader shows sensibly without knowing this profile:

```xml
<a epub:type="biblioref" role="doc-biblioref" data-citation-key="hegland2021vm"
   data-citation-number="1"
   href="backmatter.xhtml#bib-hegland2021vm">[1]</a>
```

Three rules make this robust for every producer:

1. **The label is `[n]`** and the `href` resolves to a real bibliography entry
   (`backmatter.xhtml#bib-<key>`, §3.7) — so in a traditional reader the citation is a
   working numbered citation: `[1]` in the text, the full reference one click away.
   Richer renderings — the author–date as the author wrote it — travel as `citedAs` on
   the pool entry (§5.3), where an Origami reader restyles citations to the reader's
   chosen form. The anchor text is the floor, not the ceiling.
2. **The key is complete, stable, and unique** within the work — never truncated (a cut
   UUID collides), never regenerated between exports of the same document.
3. **`data-citation-number` is authoritative.** A reader must not renumber on its own,
   or the in-text citations and the visible reference list would disagree; the numbers
   run in bibliography order.

Importers identify the citation by `data-citation-key` and **read, never regenerate**,
what the file carries: pool `citedAs` first, the anchor's text next, the number always.
Adjacent anchors sharing one key collapse to one citation token, their text fragments
read as one label. When the pool does not know a cited key (a malformed export), an
importer should mint a record from the anchor's own text rather than drop the citation —
parsing "Names YYYY" to author and year, keeping a short text as the title and a long
one as the record's note — so the citation stays clickable and restylable. The raw key
is a last resort shown bracketed, only when everything else is missing; an unresolved
citation never surfaces as machine syntax.

**An endnote dagger** marks where a note attaches. The note's *words* do not appear in
the flow; they ride in `origami.json` (§5.4). The dagger:

```xml
<a epub:type="noteref" role="doc-noteref" href="backmatter.xhtml#en-1">&#8224;</a>
```

Here the `href` **fragment is load-bearing**: the part after `#` must be exactly the
note's id in the `endnotes` array. `&#8224;` is the dagger character (†).

**An inline note** (a footnote living beside its paragraph, not at the back) is the
same noteref anchor pointing at a same-document footnote aside, which follows the host
block:

```xml
<a epub:type="noteref" role="doc-noteref" href="#fn-1">&#8224;</a>
…
<aside epub:type="footnote" role="doc-footnote" id="fn-1">
<p id="P-fn-1">The note's words, in place.</p></aside>
```

The note also rides in `origami.json` under `footnotes` (`{id, anchor, text}` — the id
matching the aside's, the anchor naming the host block). A plain EPUB reader shows the
aside beneath the paragraph (or as a popup — Apple Books treats `doc-footnote` asides
so); an Origami importer files the note's words under its id with the endnotes and
**never inlines the aside as body text** — the words are the note's, not the flow's,
and the dagger reveals them on demand.

**An inline note as stretchtext** (Author's "Inline notes: Stretchtext" export) folds
open *in place* in an Origami reader while degrading to an appendix note everywhere
else. The anchor carries `class="ot-inline-note"` and points at the note's entry among
the back matter's endnotes; there is no same-document aside:

```xml
<a epub:type="noteref" role="doc-noteref" class="ot-inline-note"
   href="backmatter.xhtml#en-fn-1">&#8225;</a>
```

The note's words ride with the endnotes — in `origami.json → endnotes` and in the back
matter's Notes list — under the fragment's id (`en-fn-1`). In a plain EPUB reader the
mark (`&#8225;`, ‡) is a working link to a readable appendix entry, the same journey a
citation makes. An Origami reader shows the mark as `[]` and, opened, continues the
sentence in place — `[` before the note's words, `]` after — a click on any of it
folding the note back. Importers writing the Origami document format carry the mark as
an `[inote:<id>]` token; the anchor's own glyph is chrome, not content.

### 3.5 Tables

A table appears in the flow as markup carrying its **computed values** (so every reader
sees the data), and points at the live table — values *and formulas* — in `origami.json`
(§5.5) via `data-table-id`:

```xml
<table id="p9" data-table-id="t1">
<tr><td>Year</td><td>Documents</td></tr>
<tr><td>2026</td><td>1900</td></tr>
</table>
```

The `id` is the table's paragraph address (its place in the flow); `data-table-id` is the
key into the `tables` pool. Cell text is XML-escaped plain text — no markup inside cells.

### 3.6 Stretchtext

Stretchtext is expandable detail: paragraphs a reader can fold away. Consecutive folded
paragraphs sharing one fold wrap in a single `<aside>`:

```xml
<aside class="ot-stretchtext-content" id="stretch-1" hidden="hidden">
<p id="p6">The folded detail, a normal paragraph in every other way.</p>
<p id="p7">More folded detail.</p>
</aside>
```

- `class` must contain `ot-stretchtext-content`; the aside's `id` is the fold's id.
- `hidden="hidden"` keeps the detail collapsed in plain EPUB readers (they honor the
  HTML `hidden` attribute); Origami readers make it a fold that opens and closes.
- Paragraphs inside are ordinary blocks per §3.2 with their own stable ids.
- A toggle anchor in the host paragraph (`<a class="ot-stretchtext…">›</a>`) is chrome
  from Author's dialect; producers need not emit one, and importers discard it.

### 3.7 Back matter (`backmatter.xhtml`)

A document that cites or carries endnotes **must** ship `backmatter.xhtml`, listed in
the manifest and at the spine's end. It is what makes the package whole for a reader
that knows nothing of this profile: every `[n]` in the text is a link that lands on a
real, readable entry.

```xml
<section epub:type="bibliography" role="doc-bibliography">
<h2>References</h2>
<ol>
<li id="bib-hegland2021vm">Frode Hegland. (2021). “Visual-Meta: An Approach to
Surfacing Metadata”. Proceedings of the 32nd ACM Conference on Hypertext.</li>
</ol>
</section>
<section epub:type="endnotes" role="doc-endnotes">
<h2>Notes</h2>
<ol>
<li id="en-1">The note's words, in full.</li>
</ol>
</section>
```

- Every `data-citation-key` in the body has its `<li id="bib-<key>">`, in
  `data-citation-number` order, carrying a human-readable reference line (authors, year,
  title, venue, DOI — however much the record knows). An empty `<li>` is a broken
  promise: the anchor's link goes nowhere useful.
- Every noteref dagger's fragment has its `<li id="<note-id>">` with the note's words.
- The pool (§5.3) remains the machine's truth — BibTeX, `citedAs`, `number`; the back
  matter is the same truth in human form. They must agree.

## 4. Escaping and whitespace

### 4.1 XML escaping

In all text content and attribute values, escape in this order and nothing else:

```
&  →  &amp;      <  →  &lt;      >  →  &gt;      "  →  &quot;
```

All other characters — accents, CJK, emoji, typographic quotes — are UTF-8 directly.

### 4.2 Whitespace

One paragraph is one block element; producers write each block on its own line. Newlines
*inside* a block element read as spaces (importers collapse runs of whitespace around
line breaks to a single space), so do not rely on line breaks for meaning within a
paragraph.

## 5. `OEBPS/origami.json` — the metadata payload

One JSON object, UTF-8, pretty-printed with sorted keys (a person should be able to read
it in a text editor — the profile's self-describing rule). Only `document` and `origami`
are required; every other key is omitted when empty. Importers ignore unknown keys —
that is how the profile grows — and a producer must emit only what it can explain.

```json
{
  "document": {
    "title": "Spatial Reading, Considered",
    "authors": [{ "name": "Frode Hegland" }],
    "origami-id": "f.hegla.101500k",
    "id": "urn:al:f.hegla.101500k",
    "date": "2026-08-17"
  },
  "origami": { "format": "origami-text", "generator": "YourTool 1.0" },
  "references": { … },
  "glossary": { … },
  "endnotes": [ … ],
  "tables": [ … ],
  "excerptOf": { … }
}
```

### 5.1 `document` (required)

- `title` — the document's title (must agree with `dc:title`).
- `authors` — an array of `{ "name": "…" }` objects, first author first.
- `origami-id` — the document's Origami address (§6), the same id the OPF identifier
  carries after `urn:al:`. This is what lets citations to the work resolve wherever the
  EPUB arrives.
- `id` — `"urn:al:" + origami-id`.
- `date` — the human-assigned date (`YYYY-MM-DD`, `YYYY-MM`, or `YYYY`); omit when none.

### 5.2 `origami` (required)

`format` is always `"origami-text"`. `generator` names the producing tool — be honest.

### 5.3 `references` — the citation pool

A dictionary keyed by citation key (the `data-citation-key` values used in the body),
each entry carrying the cited work's **verbatim BibTeX**, and optionally `citedAs` (the
in-text display text as the author wrote it) and `number` (the entry's 1-based place in
the reference list, matching the body anchors' `data-citation-number`):

```json
"references": {
  "hegland2021vm": {
    "bibtex": "@phdthesis{hegland2021vm,\n  author = {Frode Hegland},\n  title = {Visual-Meta: An Approach to Surfacing Metadata},\n  school = {University of Southampton},\n  year = {2021},\n}",
    "citedAs": "(Hegland, 2021)",
    "number": 1
  }
}
```

Every key the body cites should have an entry here; an entry the body never cites is
allowed (it still counts as a reference of the document). Inside BibTeX values, escape
the BibTeX special characters `& % $ # _ { } ~ ^` and backslash; braces that *delimit*
fields stay. A citation of another **Origami library document** may additionally carry
the target's address in the entry as `vm-id = {<address>#<paragraph-id>}` — that is what
lets a receiving library resolve the citation to the live document. A citation of a
**Liquid Information view** whose scene dataset rides in the package (§2.4) additionally
carries `scene-resource = {data/<scene-id>.liquidinfo.json}` — the package-relative path
readers use to restore the scene whole.

### 5.4 `endnotes`

An array, in note order, each `{ "id": "…", "text": "…" }`. The `id` must match a
dagger's href fragment (§3.4); `text` is the note's words in Origami text form (the §3.3
right-hand column — `**bold**`, `[cite:key]`, and addresses all allowed). On import the
notes return as a closing "Notes" section.

### 5.5 `tables`

An array of live tables, keyed to the body's `data-table-id` values:

```json
"tables": [{
  "identifier": "t1",
  "rowCount": 2,
  "columnCount": 2,
  "cells": [
    [{ "value": "Year" }, { "value": "Documents" }],
    [{ "value": "2026" }, { "value": "1900", "formula": "=B1*1" }]
  ]
}]
```

`cells` is row-major; `formula` is optional (the spreadsheet formula behind a computed
`value`). The markup's cell text (§3.5) must equal the `value`s here.

### 5.6 `glossary` — Defined Concepts

A dictionary keyed by concept id (a stable string; UUIDs are customary), each:

```json
"glossary": {
  "c-visual-meta": {
    "phrase": "Visual-Meta",
    "entry": "Metadata carried inside the document, in human-readable form.",
    "tags": ["format"],
    "citations": [],
    "urls": ["https://visual-meta.info"]
  }
}
```

`phrase` is required; `entry` (the explanation), `tags` (zero or one tag is customary),
`citations` (keys into `references`), and `urls` may be empty.

### 5.7 `excerptOf` — provenance of a carved-out section

Present only when this EPUB is a section extracted from another document:

```json
"excerptOf": {
  "id": "f.hegla.093252x",
  "title": "The Original Document's Title",
  "author": "Frode Hegland",
  "date": "2026-07-11",
  "headingID": "h-section",
  "headingText": "The Extracted Section's Heading"
}
```

`id` and `headingID` are required (the original document's address and the extracted
heading's paragraph id); `date` optional. An excerpt keeps the original's paragraph ids
unchanged, so citations made from the excerpt address the original.

## 6. Document addresses

An Origami address is a short human-readable id, deterministic from author and creation
time:

```
<first-initial> "." <surname, ≤5 chars> "." <HHmmss UTC> <day-character>
Frode Hegland, created 2026-07-11T09:32:52Z  →  f.hegla.093252x
```

Names transliterate to lowercase ASCII `a–z0–9`; the day-character is
`"abcdefghijklmnopqrstuvwxyz0123456789"[daysSinceUnixEpoch mod 36]`. Excerpts use
`excerpt-<16 hex chars>` (a stable hash of `<original-id>#<heading-id>`), so re-extracting
the same section yields the same id. A producer minting a fresh document generates the
address from its author and moment; a producer re-exporting an existing Origami document
**must keep the document's existing id**. Full rules: `ORIGAMI-DOCUMENT-FORMAT.md` §3.

## 7. What readers also accept (Author's dialect and older exports)

A producer emits only the forms above. But the shared importer also reads a sibling
dialect (Author's EPUB export and older Origami exports) — listed here so a *validator or
re-writer* built from this specification does not reject real files:

- Metadata may be named `visual-meta.json` instead of `origami.json`, or be **embedded**
  in the content document as `<script id="origami-metadata">` (or
  `id="visual-meta-payload"`) wrapping the JSON in CDATA — the package file wins over the
  embedded copy.
- The flow may be wrapped in `<main>` instead of written directly into `<body>`; sections
  may nest in `<section>`, `<div>`, or `<article>` freely (importers recurse).
- The document title may echo as a leading `<h1>`; importers drop that echo.
- A placeholder metadata title ("Untitled", or blank) never makes the imported record:
  importers take the title from the leading `<h1>` instead (shown once, as the
  document's header, not again in the body), else from the `.liquid` filename
  origami.json records.
- `authors` may be an array of plain strings (`["Name"]`).
- The metadata may carry `concepts` (an array with `id`/`name`/`description` — the older
  spelling of `glossary`), a `citations` array (entries with `id`, `bibtex`, and `urls`
  where an `origamitext://open/<address>` URL marks a citation of a library document),
  and a `map` object (`views` with node positions, `connections`) for spatial layouts.
- One citation may be split across several adjacent anchors sharing one
  `data-citation-key`; importers read them as one token, their text as one label.
- Anchors may carry no `data-citation-number` (exports before 2026-08-18); importers
  derive the numbers from the bibliography list's own order (`<li id="bib-<key>">`,
  in sequence) when a package file carries one, and otherwise fall back to the
  anchor's text.
- A `<figure>` may wrap its `<img>` in a cited anchor (`epub:type="biblioref"` with an
  `http` href); importers mint a reference from it when the pool lacks the key.
- An EPUB with **no Origami metadata at all** is read as a plain book: every spine
  document in order, ids prefixed `s1-`, `s2-`, … per chapter.

## 8. Strict EPUB validation

The profile's citation and dagger anchors point at `backmatter.xhtml`, which the
reference exporter does not include — Origami readers never dereference those hrefs
(§3.4), and mainstream readers tolerate a dangling link, but **epubcheck flags it**. A
producer that must pass epubcheck cleanly includes a minimal backmatter:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Backmatter</title></head>
<body>
<section epub:type="bibliography">
<p id="bib-hegland2021vm">Hegland, F. (2021). Visual-Meta: An Approach to Surfacing Metadata. University of Southampton.</p>
</section>
<section epub:type="endnotes">
<p id="en-1">The note's words, repeated from origami.json for human readers.</p>
</section>
</body>
</html>
```

— manifested (`<item id="backmatter" href="backmatter.xhtml"
media-type="application/xhtml+xml"/>`) and appended to the spine **after** content
(`<itemref idref="backmatter" linear="no"/>`; content.xhtml must stay first). One anchor
target per citation key (`bib-<key>`) and per note id. Origami importers ignore the file;
`origami.json` remains the source of truth.

## 9. Producer checklist

1. `mimetype` first in the ZIP, stored, exactly `application/epub+zip`.
2. Every block element in `content.xhtml` has a unique, stable `id`.
3. `content.xhtml` is well-formed XML; `&` `<` `>` `"` escaped everywhere.
4. The spine's first itemref is `content.xhtml`; `origami.json` is in the manifest.
5. `document.origami-id`, the OPF `dc:identifier` (`urn:al:` + id), and the filename's
   id (where the `<slug>--<id>.epub` naming is used) all agree.
6. Every `data-citation-key` in the body has a `references` entry; every dagger's href
   fragment has an `endnotes` entry; every `data-table-id` has a `tables` entry; every
   `<img src>` has a package file and a manifest item; every `scene-resource` field has
   a `data/` package file and a manifest item (§2.4).
6a. Citation anchors read `[n]`, carry a complete (never truncated) stable
   `data-citation-key` and a `data-citation-number`, and `backmatter.xhtml` holds a
   readable `bib-<key>` entry for every one of them and a note body for every dagger
   (§3.4, §3.7). A citing document without its back matter ships broken links.
7. Speaker turns lead with `<strong class="speaker">Name:</strong>` and a space;
   continuations carry `data-speaker`.
8. Titles, authors, and dates agree between the OPF and `origami.json`.
9. Nothing essential is outside the package: a person with the EPUB alone holds the
   whole document.

## 10. Complete worked example

A small document exercising every structure. ZIP these nine entries (mimetype first) and
the result opens in any EPUB reader and imports losslessly into Origami Text, Augmented
Library, Reader, and Knowledge Space.

**`mimetype`**

```
application/epub+zip
```

**`META-INF/container.xml`** — §2.1 verbatim.

**`OEBPS/content.opf`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="pub-id">urn:al:f.hegla.101500k</dc:identifier>
    <dc:title>Spatial Reading, Considered</dc:title>
    <dc:creator>Frode Hegland</dc:creator>
    <dc:date>2026-08-17</dc:date>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>
    <item id="origami-metadata" href="origami.json" media-type="application/json"/>
    <item id="img1" href="images/figure1.png" media-type="image/png"/>
  </manifest>
  <spine><itemref idref="content"/></spine>
</package>
```

**`OEBPS/nav.xhtml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Spatial Reading, Considered</title></head>
<body>
<nav epub:type="toc"><ol><li><a href="content.xhtml">Spatial Reading, Considered</a></li></ol></nav>
</body>
</html>
```

**`OEBPS/content.xhtml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Spatial Reading, Considered</title></head>
<body>
<section>
<h2 id="h-intro">Spatial Reading</h2>
<p id="p1">As argued in <a epub:type="biblioref" role="doc-biblioref" data-citation-key="hegland2021vm" href="backmatter.xhtml#bib-hegland2021vm">(Hegland, 2021)</a>, metadata should travel <strong>with</strong> the artifact<a epub:type="noteref" role="doc-noteref" href="backmatter.xhtml#en-1">&#8224;</a> — <mark>inside the document</mark>, in <em>human-readable</em> form.</p>
<figure id="p2"><img src="images/figure1.png" alt="A reading arrangement, laterally spread"/></figure>
<p id="p3">Growth of the shared library:</p>
<table id="p4" data-table-id="t1">
<tr><td>Year</td><td>Documents</td></tr>
<tr><td>2026</td><td>1900</td></tr>
</table>
<aside class="ot-stretchtext-content" id="stretch-1" hidden="hidden">
<p id="p5">A folded aside: the detail a reader may unfurl, losing nothing when it stays furled.</p>
</aside>
<hr id="rule-1"/>
<h3 id="h-voices" data-contributing-authors="Mark Anderson">Voices from the Lab</h3>
<p id="p6"><strong class="speaker">Frode Hegland:</strong> The lateral arrangement matters more than the depth.</p>
<p id="p7" data-speaker="Frode Hegland">And the arrangement, once made, is the reader's own.</p>
<p id="p8"><strong class="speaker">Mark Anderson:</strong> I would add a caveat about citation practice.</p>
</section>
</body>
</html>
```

**`OEBPS/origami.json`**

```json
{
  "document": {
    "authors": [{ "name": "Frode Hegland" }],
    "date": "2026-08-17",
    "id": "urn:al:f.hegla.101500k",
    "origami-id": "f.hegla.101500k",
    "title": "Spatial Reading, Considered"
  },
  "endnotes": [
    { "id": "en-1", "text": "The move Visual-Meta made for PDF, this profile makes for EPUB." }
  ],
  "glossary": {
    "c-visual-meta": {
      "citations": ["hegland2021vm"],
      "entry": "Metadata carried inside the document, in human-readable form, so it survives with the artifact.",
      "phrase": "Visual-Meta",
      "tags": ["format"],
      "urls": ["https://visual-meta.info"]
    }
  },
  "origami": { "format": "origami-text", "generator": "Worked Example 1.0" },
  "references": {
    "hegland2021vm": {
      "bibtex": "@phdthesis{hegland2021vm,\n  author = {Frode Hegland},\n  title = {Visual-Meta: An Approach to Surfacing Metadata},\n  school = {University of Southampton},\n  year = {2021},\n}"
    }
  },
  "tables": [
    {
      "cells": [
        [{ "value": "Year" }, { "value": "Documents" }],
        [{ "value": "2026" }, { "value": "1900" }]
      ],
      "columnCount": 2,
      "identifier": "t1",
      "rowCount": 2
    }
  ]
}
```

**`OEBPS/images/figure1.png`** — any PNG.

What round-trips: every block under its own address (`h-intro`, `p1`…`p8`, `h-voices`,
`rule-1`, `stretch-1` as a fold) — a citation with its verbatim BibTeX — an endnote — a marked,
bolded, italicized sentence — an image as an asset — a live table — a rule — a section
credited to its own writer — two speakers, each statement ascribable, the continuation
clean. A reader in 2076 with nothing but a ZIP tool and a text editor can recover all
of it.

---

*Reference implementation: `OrigamiEPUBExport.swift` and `OrigamiEPUBImport.swift`,
identical in Origami Text, Augmented Library, and Knowledge Space; a fix in one home is
carried to the others. The format belongs to the people who write in it.*
