# Liquid Information — receiving the Open Source hand-off

*For the Claude working on Liquid Information. Written from Knowledge
Space's side (19 August 2026), verified against a real export
(`liquid-view-20260819-london-tokyo-rain.png`). Knowledge Space's
"Open Source" on a Liquid PNG now always sends a link that carries the
**complete scene** — the receiver must assume the person clicking has
nothing but the image: no local `.liquidinfo` file, no scene id it can
look up, no access to the original data. Everything needed to re-create
the view is inside the link itself.*

## What arrives

One URL, in whichever of these forms your app's doors accept — same
text, only the scheme differs, so one parser serves all three:

```
liquidinfo://link.augmentedtext.com/liquid/v1/<scene-id>?vp=…&title=…&scene=<payload>
liquid://link.augmentedtext.com/liquid/v1/<scene-id>?vp=…&title=…&scene=<payload>
https://link.augmentedtext.com/liquid/v1/<scene-id>?vp=…&title=…&scene=<payload>
```

Knowledge Space tries, in order: the app chosen in its Settings, the
`liquidinfo://` scheme, the older `liquid://` scheme, then the https
link. If none of those doors exists it puts the link on the clipboard
and brings your app forward — so **also support paste-to-open**: a
pasted link must open exactly as a delivered one.

## Decoding the `scene` payload — exact rules

1. **Treat the URL as text.** Take everything after the first `?`,
   split on `&`, find the pair starting `scene=`. Do **not** round-trip
   the URL through a components/percent-encoding library first — the
   payload is base64url and re-encoding can corrupt it.
2. **base64url → bytes.** Map `-`→`+`, `_`→`/`, re-pad with `=` to a
   multiple of 4, then standard base64 decode.
3. **Inflate: the bytes are a raw DEFLATE stream** — no zlib header,
   no Adler-32 trailer. (Verified: this is what Liquid Information's
   own PNG export writes today. If your decoder expects zlib/RFC 1950
   it will fail with "incorrect header check".) Be tolerant the other
   way too: if raw inflate fails, try skipping the first 2 bytes and
   inflating the rest, in case an older sender wrote zlib.
4. **UTF-8 → JSON.** The result is a complete `.liquidinfo` scene
   document, `formatVersion` 2 — identical to what the PNG carries in
   its `liquid-scene` iTXt chunk. In the verified sample: 3,422 payload
   characters inflate to 12,232 bytes of JSON.

Any failure at any stage reads as "the link carried no scene" — then,
and only then, fall back to looking the scene id up locally; if that
fails too, say plainly that the link could not be re-created, never a
silent nothing.

## What to do with the received scene

1. **Build the view wholly from the payload.** Nodes, edges, groups,
   series, title — everything renders from the JSON. Never require the
   scene id (`/liquid/v1/<scene-id>`) to resolve locally first.
2. **The series' points are the data — do not re-fetch.** Each series
   carries every point inline (`points`, with `date`/`value`), plus
   `sourceName`, `sourceURL`, `unit`. `sourceURL` (e.g. the Open-Meteo
   query) is provenance for display and citation, not something to call
   before drawing. The reader may be offline; the numbers they see must
   be the numbers that were cited.
3. **Never overwrite a local scene.** If the receiver already has a
   scene with the same id, open the received one as its own unsaved /
   received copy and offer to save it — the arriving citation must not
   silently replace what the person has locally, and the person's local
   copy must not silently replace what the citation says was seen.
4. **Restore the very viewpoint.** The scene JSON carries `viewpoint`
   (`azimuth`, `elevation`, `distance`, `fisheye`, `target{x,y,z}`).
   The `vp=` query, when present, is the view at the moment of citation
   and wins over the JSON's stored viewpoint. Observed encoding, six
   comma-separated numbers:

   ```
   vp = target.x, target.y, target.z, azimuth, elevation, distance
   ```

5. **`title=` in the query is a filename-friendly slug** for contexts
   that only see the URL; the JSON's `title` field is the real title.

## When the scene is too large for a link — the file hand-off

Links carry scenes only up to **8,000 characters of compressed
base64url payload** (the shared threshold — see SCENE-DATA-IN-EPUB.md).
Above that, Knowledge Space writes the complete scene JSON to a
temporary **`.liquidinfo` file** and hands the *file* to Liquid
Information instead — through the chosen app, or whatever app is
registered for the type. For that door to exist, Liquid Information
must register the document type (the same one-entry spirit as the URL
scheme):

```xml
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key><string>Liquid Information Scene</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSItemContentTypes</key>
    <array><string>com.augmentedtext.liquidinfo.scene</string></array>
  </dict>
</array>
<key>UTImportedTypeDeclarations</key>
<array>
  <dict>
    <key>UTTypeIdentifier</key><string>com.augmentedtext.liquidinfo.scene</string>
    <key>UTTypeConformsTo</key><array><string>public.json</string></array>
    <key>UTTypeDescription</key><string>Liquid Information Scene</string>
    <key>UTTypeTagSpecification</key>
    <dict><key>public.filename-extension</key><array><string>liquidinfo</string></array></dict>
  </dict>
</array>
```

Opening the file follows the same rules as a link's scene payload:
build the view wholly from the JSON, never overwrite a local scene with
the same id, render from the inline points without re-fetching
`sourceURL`. Until the type is registered, Knowledge Space reveals the
written file in the Finder and says so — no dead click.

## The testing aid — compare received against sent

Every "Open Source" click in Knowledge Space now also puts the entire
hand-off on the clipboard, so you can diff what Liquid received against
what was sent. The block reads:

```
=== Open Source hand-off ===
link: https://link.augmentedtext.com/liquid/v1/…?…&scene=…
scheme form: liquidinfo://link.augmentedtext.com/liquid/v1/…
scheme form: liquid://link.augmentedtext.com/liquid/v1/…
scene (decoded from the link, 12232 chars):
{ …the full scene JSON, exactly as your decoder should produce it… }
```

The `scene` section is Knowledge Space decoding its own outgoing link —
if your inflate produces byte-identical JSON to that section, the
transport is proven and any remaining bug is in the scene restore, not
the decoding. (One caveat: on macOS, if every hand-off door fails,
Knowledge Space's fallback replaces the clipboard with just the plain
link — the block survives only when the hand-off itself was attempted.)

## Sender-side facts you can rely on

- A link that already carried a `scene=` payload travels **untouched**
  — byte-for-byte the URL out of the PNG's citation.
- A link that lacked one gains it from the scene Knowledge Space holds
  (the EPUB package's `data/` file first, the PNG's `liquid-scene`
  chunk second): compressed raw DEFLATE, base64url without padding,
  appended as `?scene=` or `&scene=` by plain string concatenation —
  but only up to the 8,000-character payload threshold; above it the
  hand-off is the `.liquidinfo` file described above, and the testing
  clipboard block says `scene: too large for the link — sent as a
  .liquidinfo file` followed by the full JSON.
- Round-trip is verified on Knowledge Space's side: chunk → link →
  decode reproduces the chunk's JSON exactly, through both the https
  and the schemed forms.
