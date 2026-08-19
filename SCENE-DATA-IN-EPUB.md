# Scene datasets in the EPUB package — what Liquid Information and Author each change

*Agreed shape, 19 August 2026. A Liquid Information view cited in a
document currently travels three ways: the link's `scene=` payload, the
PNG's `liquid-scene` iTXt chunk, and (nothing yet) the EPUB package.
This adds the package as the durable carrier for large datasets. The
authoritative format text is §2.4 of ORIGAMI-EPUB-SPECIFICATION.md
(bundled with Knowledge Space); this file is the work split. Knowledge
Space's own import, export, reader, and Open Source hand-off already
implement their side — details at the end so both apps know what they
are talking to.*

## The ladder (shared picture)

A reader restores a scene from the **first rung that answers**:

1. `OEBPS/data/<scene-id>.liquidinfo.json` in the package — the full
   truth when present.
2. The PNG's `liquid-scene` chunk — full below the threshold, trimmed
   (structure and viewpoint, minus bulk points) above it, so an image
   that escapes the package alone still carries as much as is sane.
3. The link's `scene=` payload — present only when it fits.
4. The scene id, looked up locally — the last resort, and the only
   rung that requires the reader to already have the file.

**The threshold, everywhere: 8,000 characters of compressed base64url
payload.** At or below it, links carry the scene and chunks are full.
Above it, links carry no `scene=`, chunks are trimmed, and the package
file (or a `.liquidinfo` file hand-off) carries the data.

---

## Liquid Information (the 3D scene creator) — what to change

1. **Round point values to the source's precision before writing
   anything.** Open-Meteo gives 0.1mm; the current export writes
   `11.306666666666667`. Quantizing to what was measured cuts datasets
   several-fold with zero loss of meaning and pushes most scenes below
   the threshold entirely. Do this first; it may be the only change
   most scenes ever notice.
2. **Apply the threshold when minting the citable PNG:**
   - Payload ≤ 8,000 chars: exactly today's behaviour — full
     `liquid-scene` chunk, `url` field carrying the `scene=` payload.
   - Payload > 8,000 chars: the `url` carries **no** `scene=` (id,
     `vp=`, `title=` only), and the `liquid-scene` chunk is the
     **trimmed scene**: the full JSON with each series' `points`
     emptied, everything else — nodes, edges, series metadata,
     `sourceName`, `sourceURL`, `unit`, viewpoint — intact.
3. **Register the `.liquidinfo` document type** (UTI +
   `CFBundleDocumentTypes`), and open such a file as a received scene.
   Above the threshold, senders hand the scene across as a temporary
   `.liquidinfo` file instead of a URL — Knowledge Space already does.
   Same rules as the link hand-off (LIQUID-OPEN-SOURCE-HANDOFF.md):
   build the view wholly from the file, never overwrite a local scene
   with the same id, render from the inline points without re-fetching
   `sourceURL`.
4. **Nothing else changes.** The link domain, the `/liquid/` path, the
   raw-DEFLATE + base64url encoding, the `vp=` viewpoint query, and the
   `visual-meta` citation chunk all stay exactly as they are.

## Author (the EPUB creator) — what to change

When a document being exported contains a Liquid PNG (an image whose
PNG data carries a `liquid-scene` iTXt chunk):

1. **Write the scene into the package** as
   `OEBPS/data/<scene-id>.liquidinfo.json` — the chunk's text
   byte-for-byte when the chunk is full. When the chunk is the trimmed
   form (its series have empty `points`), the PNG cannot supply the
   data; write the file from the full scene if Author holds it (e.g.
   the citation arrived with a `scene=` link payload — inflate that),
   and otherwise write the trimmed scene as-is — a partial rung is
   still better than none. Deduplicate by scene id: the same scene
   figured twice is one file.
2. **Manifest it**, never in the spine:
   `<item id="scene1" href="data/<scene-id>.liquidinfo.json"
   media-type="application/json"/>`.
3. **Add the pointer to the citation**: in the reference pool's BibTeX
   for that figure, add `scene-resource =
   {data/<scene-id>.liquidinfo.json}`. This is the field readers
   resolve; the PNG's embedded copy of the record won't have it (Liquid
   can't know package paths), so it lives on the pool's copy.
4. **Escape nothing extra**: the path is plain ASCII (scene ids are
   UUIDs or slugs); the existing BibTeX escaping rules apply unchanged.
5. **Carry the file with its figure**: when a section is carved out as
   an excerpt, or a document is re-exported, a `data/` scene file
   travels whenever its image does — treat `scene-resource` like an
   image reference when trimming pools.

## Issues both sides should hold

- **Drift is the failure mode.** The package file and the chunk must be
  written from the same bytes at the same moment. The package file wins
  when both are present; a trimmed chunk is *expected* to disagree with
  it (that's its job), which is why readers take the package file
  first.
- **The image escaping the package is the reason the chunk survives.**
  Never drop the chunk because the package file exists.
- **The cited numbers are the displayed numbers.** No rung ever
  re-fetches `sourceURL` to draw.
- **Plain text, always.** The package file is uncompressed JSON — the
  ZIP compresses it in transit, and a person with a text editor in
  fifty years reads it without any of our software.

## What Knowledge Space already does (so you can test against it)

- **Import**: any `*.liquidinfo.json` package file rides into the
  document and survives round-trips.
- **Export**: such files are written back under `OEBPS/data/` and
  manifested — an EPUB through Knowledge Space keeps its scene data.
- **Reader**: a figure's Open Source resolves the scene by the ladder
  above — package file (via `scene-resource`, or matched to the link's
  scene id when the field is absent), then chunk.
- **Open Source**: scene ≤ threshold → link with `scene=` aboard;
  above it → a temporary `.liquidinfo` file handed to Liquid
  Information (macOS), with the Finder-reveal fallback until the
  document type is registered. Every click also puts the full hand-off
  on the clipboard for testing (LIQUID-OPEN-SOURCE-HANDOFF.md).
