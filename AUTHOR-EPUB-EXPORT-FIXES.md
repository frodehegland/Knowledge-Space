# Author — Origami EPUB export fixes

*Found while building Knowledge Space's Origami EPUB import (16 August 2026), by
reading Author's own export byte for byte. Evidence file:
`With an image 1(Frode-Hegland-2026-08-15T22_41_50Z).epub` (Desktop), generator
`Author (macOS)`, exported from `With an image 1.liquid`. Knowledge Space and
Augmented Library import these files tolerantly, so nothing here blocks reading —
but every item below loses information or breaks a promise the format makes.
Ordered by how much they matter.*

---

## 1. Citation keys are truncated to 25 characters

Every citation key in the export — the `references` pool in `origami.json`, the
`@software{…}` keys in `references.bib`, the body's `data-citation-key`, and the
`backmatter.xhtml#bib-…` hrefs — is a UUID cut to its first 24 characters plus a
trailing dash:

```
AB88F3D2-0529-4966-A75E-      (should be a full 36-character UUID)
F4596B96-9D0A-44F1-9E25-
```

It looks like a `prefix(25)` (or a 25-character field) applied at export. The
truncation is at least *consistent* — body and pool agree, so citations resolve —
but:

- two different citations can collide once 11 characters are gone;
- a key ending in `-` is fragile in BibTeX tooling (some parsers trim or reject
  trailing punctuation in keys);
- the key no longer matches the citation's identity anywhere else in the
  ecosystem (the CSL `id` field carries the same truncated form, so the damage
  propagates).

**Fix:** emit the full identifier everywhere the key appears. If a shorter key is
wanted for BibTeX aesthetics, derive one cleanly (e.g. a hash prefix without
trailing punctuation) — but body, pool, `.bib`, and CSL must all carry the same,
collision-safe key.

## 2. The body cites a key the pool does not carry

The body's third paragraph cites `01BAFD5A-514D-45D0-BAD1-`, but the
`origami.json` references pool and `references.bib` contain only `AB88F3D2-…`
and `F4596B96-…`. Meanwhile `F4596B96-…` is in the pool but cited nowhere in the
body. So one citation is dangling and one record is orphaned — it looks like the
same Interatlas view was cited twice and one instance was re-keyed after the
pool was built.

Importers keep the dangling token visible by design ("a broken export can be
seen, not guessed at"), so the reader literally sees `[cite:01BAFD5A-…]`.

**Fix:** build the reference pool from the body's actual citation instances at
export time, as the last step — never emit a `data-citation-key` that has no
pool entry, and prune pool entries nothing cites (or keep them, but the first
half is the invariant that matters).

## 3. The document's image is silently dropped

The document is *named* "With an image 1" and carries an image in Author — the
EPUB contains no image files, no `<figure>`, no `<img>`, and no placeholder in
`content.xhtml`. The picture simply vanishes, without a trace a reader could
notice.

**Fix:** export figures as files under `OEBPS/images/` with
`<figure><img src="images/…" alt="…"/></figure>` in the body (this is what the
Origami importers rebuild assets from). If an image cannot be exported, emit a
visible placeholder rather than nothing — silent loss is the one thing the
format forbids.

## 4. "Untitled" exported when the document has a name

`dc:title`, `origami.json → document.title`, and the self-citation BibTeX all
say `Untitled`, although the export itself records
`"filename": "With an image 1.liquid"` two lines below. The publishing title
(Author.plist's `title`) was never set, and the export prefers that empty field
over the name the document actually goes by. The same stale-publishing-title
pattern shows across the Author iCloud folder (e.g. "Dimensions of Gestures in
XR.liquid" whose plist title is a leftover thesis title).

**Fix:** when the publishing title is empty — or untouched template text — fall
back to the document's file name at export. The receiving library lists the
work by this title; "Untitled" costs the work its identity on every other
machine.

## 5. No `origami-id` in the metadata

`origami.json → document` carries `id: urn:uuid:…` (fresh per export?) but no
`origami-id`. That field is how a receiving library keeps the document's stable
address, so citations to the work resolve wherever it arrives; without it,
importers fall back to the identity key in the file name
(`(Frode-Hegland-2026-08-15T22_41_50Z)`) — which works until someone renames
the file.

**Fix:** write `origami-id` with the document's own address into
`document` in `origami.json`. (The importers already read it.)

## 6. The first citation anchor has no visible text

The first biblioref anchor in the body is empty — whitespace only:

```html
<a epub:type="biblioref" data-citation-key="AB88F3D2-…" href="…">
</a>
```

The later anchors carry a readable label ("View: Earth — Tracked whales.
Interatlas, 2026."). Origami importers regenerate labels from the pool so they
survive this, but in any plain EPUB reader (Books, Kindle) the first citation
renders as *nothing* — the reader cannot tell the text cites anything.

**Fix:** every citation anchor should carry its human-readable label. Graceful
degradation is the point of the profile: the EPUB must read whole without the
metadata.

## 7. Re-encoding strips the Interatlas citation from PNGs

*(Added 16 August, evening — from `8Image test interatlas(…17_39_53Z).epub`,
where the image now exports; #3's total loss is fixed in that build.)*

An Interatlas screenshot carries its View Citation inside the PNG itself
(the `visual-meta` iTXt chunk). Author's export re-encodes the image and
the chunk is gone from `OEBPS/images/img1.png`. The *markup* keeps the
association — the figure is wrapped in a citation anchor and the caption
paragraph repeats the key, which is how importers recover it — but the
image file itself no longer explains itself when it travels alone, which
is the chunk's whole point.

**Fix:** copy the original PNG bytes into the EPUB rather than
re-encoding — or, where re-encoding is unavoidable, carry the iTXt
`visual-meta` chunk across to the output file.

## 8. Minor: no `dc:date` / `document.date`

`origami.created` is present (`2026-08-15T22:41:53Z`) but neither `dc:date` nor
`document.date` is written, so receiving libraries list the work without a
date until they fall back to file metadata. One line to add.

---

*How the importers behave meanwhile: Knowledge Space and Augmented Library
resolve keys as exported (so #1 reads fine within one document), keep dangling
tokens visible (#2), take the identity key from the file name when `origami-id`
is missing (#5), and regenerate citation labels at reading time (#6). #3 and #4
cannot be repaired at import — the information never left Author.*
