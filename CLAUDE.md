# Working with Frode Hegland

*Context for Claude Code. This is a picture assembled from our conversations. It will be
incomplete and it will go stale. Frode — edit it. It is far more useful as your document
than as mine.*

---

## Who

Founder of **The Augmented Text Company**, based in London. Creator of **Author** (writing
and spatial knowledge application, macOS and visionOS), **Reader**, and the **Visual-Meta**
metadata format. PhD from Southampton — the thesis is Visual-Meta; his advisor was David
Millard. He runs the **Future Text Lab** (weekly, Mondays) and the annual **Future of Text
Symposium** — 2026 theme "The Future of Augmented Thought", 12 November, Conway Hall.

Before all this: fine art (Chelsea School of Art), advertising (Syracuse VPA), documentary
filmmaking. He is a lifelong photographer and shoots monochrome. **He has a real eye.** He
will notice your typography before he notices your architecture, and lazy visual defaults
read to him as carelessness.

**Douglas Engelbart was his mentor.** That is not a name to drop; it is the centre of
gravity of everything he builds. Vint Cerf is a long-standing collaborator and advocate.

---

## The philosophy — and what it means when you write code

### Interaction is the most fundamental thing

His thirty-year *Liquid Information* position: not matter, not information — **interaction**
is what is most fundamental in the universe.

> **In code:** the interaction model *is* the product, not a layer over the data model.
> Do not design the schema and then bolt a UI onto it. When a clean data model and a fluid
> interaction are in tension, the interaction wins and the schema bends. Start from the verb.

### Augmentation, not ease

Engelbart's project was augmenting human intellect, and he explicitly refused "make it
easy" as the highest value. The violin is hard; nobody proposes to fix that.

> **In code:** high ceilings are allowed. Learnable idioms beat self-evident ones. Build
> power surfaces — keyboard, voice, command — and do not sand off capability in the name of
> first-run friendliness. Ask *"will this person be better after a year of using this?"*,
> not *"can they use it in ten seconds?"*

### Documents must be self-describing, and must survive

Visual-Meta's core move: metadata travels **with** the artifact, in human-readable form,
inside the document. Origami Text and `.lqd` are the same instinct applied to EPUB and to
peer-to-peer authorship.

> **In code:** no opaque binary formats. Anything the software writes should be readable by
> a person with a text editor in fifty years, without our software. Prefer plain text,
> append-only, visible, self-describing. Graceful degradation is a hard requirement, not a
> nicety: a Visual-Meta PDF is still a PDF; an Origami Text EPUB is still an EPUB.

### Formality considered harmful

From the spatial hypertext lineage (Shipman & Marshall). Forcing a person to declare
structure before they understand it produces structure they will spend a year fighting.

> **In code:** defaults are informal. Structure emerges and is *offered*, never demanded.
> Never require someone to name a relationship, pick a category, or draw a link in order to
> proceed.

### The person owns the space

A position, once placed by a person, is theirs.

> **In code:** never let an algorithm rewrite a user-placed position. No auto-relayout, no
> "tidying up", no force-directed solve over someone's arrangement. Stability is what turns
> a layout into memory. This is invariant #1 of the Knowledge Space prototype and it holds
> everywhere else too.

### Text is the point

He runs the Future of **Text**. Graphs, maps, spaces and constellations are scaffolding
that helps you find a sentence.

> **In code:** anything that makes text less readable is a regression, however impressive it
> looks. Legibility beats visualisation. Restraint beats decoration.

### The AI works with the same view and the same controls

David Millard's principle, which Frode has adopted: the AI co-agent operates on Author's
Map through exactly the mechanisms the human has — one unified `Command` type, a single
execution path, `SelectionQuery` kept separate from commands, a deixis resolver for "this",
"that", "these".

> **In code:** no privileged back door for the AI. If the co-agent can do it, the human can
> do it, and it is visible when it happens.

---

## How he works — and how to work with him

*(Restored from the record's summary of the original; wording reconstructed.)*

- **Small runnable steps over grand refactors.** Deliver something that builds and can be
  tried, then iterate. Do not restructure half the project to land one feature.
- **Give the reasoning, not just the diff.** He wants to understand *why* a change is right;
  an unexplained edit is half a delivery.
- **Push back.** He explicitly wants disagreement when an argument is warranted. Agreeing
  pleasantly counts as a failure. The best decisions in this project's history came from
  argument.
- **Verify, don't assume.** Check edits actually landed; check against his screenshots and
  known-good references when behaviour looks wrong.

## Vocabulary — load-bearing, preserve it exactly

**knowledge space** (not canvas) · **furl / unfurl** (not collapse/expand) ·
**Defined Concept** (not tag) · **satellite** · **Entry** (never "node" in user-facing
text) · **Core** and **Contextual** space · **Summon** · **Map**.

## Hard technical rules

- Always **escape BibTeX special characters** (`& % $ # _ { } ~ ^ \` and accented/Unicode).
- **Zotero** is accessed only via the local API at `localhost:23119`.
- Identifiers are **UUIDv7**; revisions are **append-only**.
- The **macOS and visionOS Author builds differ deliberately** — do not unify them without
  explicit instruction.

---

## Addendum — changes since 11 July 2026 *(new; added on restoration, 3 August)*

- In LiquidView and the Liquid document line, spec UUIDs were replaced with **short
  human-readable addresses** (`f.hegla.093000k` — initials, surname, timestamp) that double
  as filenames. UUIDv7 persists elsewhere; check per-project which scheme applies.
- The Origami app/format was **MIT-licensed** (~13 July) and forked into **Digital Letters**
  (23 July), interoperable via the same format. Bundled open-source docs are authoritative —
  format or behaviour changes must be reflected in them.
- **Augmented Library** (renamed from "Liquid", 2 Aug) and the new **Reader** share
  **AugmentedLibraryCore**; Knowledge Space's Map runs on the shared **MapEngine** package,
  whose AI agent implements the same-view-same-controls principle via tool-calling.
- Never edit `project.pbxproj` directly while Xcode is open; prefer shared Swift packages
  and synchronized groups. Write large-file edits to disk and grep-verify — big open files
  can silently revert agent edits.

---

## For THIS repo (Knowledge Space) — how Claude Code should apply the above

*Added by Claude on 2026-08-04, to keep the Author-centric guidance above from being
misapplied to this codebase. The document above is Frode's and authoritative on
philosophy; the notes here are project-specific reconciliations verified against the
current code and the Knowledge Space memory notes.*

- **Identifiers here are short human-readable addresses, NOT UUIDv7.** This app uses
  `LiquidAddress` (`f.hegla.093000k` = initials.surname.timestamp), which also names the
  file. Follow the addendum, not the headline "UUIDv7" rule, in this repo.
- **Vocabulary applies to user-facing text only.** This app's macOS UI speaks its own
  words — Notes, Files, Actions, Inbox, To Do — and does not use the Author lexicon
  (furl/unfurl, Defined Concept, satellite, Summon, Core/Contextual). Internal code
  legitimately says `node` and "canvas points" (the Map's metric); do not rewrite those.
  Apply "knowledge space (not canvas)" and "Entry, not node" only in strings a person reads.
- **visionOS / the Map is paused (as of 2026-08-02): macOS + iOS only.** "The person owns
  the space / never auto-relayout" is a Map invariant — hold it for when the Map resumes;
  it does not constrain the macOS list/reader UI that is the current work.
- **Documents-survive is already the law here.** Every document is a self-describing
  `.liquid.json` (Origami format) in a shared community folder; the app is "just ways of
  seeing" plain text on disk. Never introduce an opaque store. See `OrigamiText/` and
  `ORIGAMI-DOCUMENT-FORMAT.md`.
- **The file on disk is the truth for a note's words.** Metadata changes must merge onto the
  current file bytes (`AppState.mutateNoteFile`), never re-serialize a stale in-memory doc —
  doing so has wiped unsaved writing. This is the "interaction wins / don't lose the person's
  words" principle made concrete.
- **Legibility is a hard gate.** Per "text less readable is a regression": treat contrast and
  typography problems as bugs to fix, not caveats to note. (E.g. white text on a faint pill
  is a regression, not a delivered request.)
- **Prefer running the app over static reasoning when behaviour looks wrong** — build after
  each change, and verify runtime bugs live rather than by inference alone.
- **Project mechanics** are recorded in Claude's memory index (`MEMORY.md`, loaded each
  session): pbxproj is untouchable (steering hook), many Xcode settings need the UI, edits to
  files open in Xcode can silently revert (grep-verify), the community folder holds ~1900
  real docs (add additively, never rewrite `People.json`).
