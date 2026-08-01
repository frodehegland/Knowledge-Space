# Knowledge Space — Your Data and How You Work With It

This explains **what you actually have** when you use Knowledge Space, in plain
terms, and the **everyday workflows** for putting things in and getting value
back out — on macOS and on Apple Vision Pro.

For the precise on-disk specification, see
`Knowledge Space/OrigamiText/ORIGAMI-DOCUMENT-FORMAT.md`. This document is the
human's-eye view of the same thing.

---

## Part 1 — The data, as you experience it

### The library is a folder

Everything you have is **files in one folder** — your community folder, usually
synced (iCloud, Dropbox, git). There is no database and no hidden layer. If
Knowledge Space vanished tomorrow, you would still have every document as a
plain, readable text file. You can back the folder up, move it, or open it in a
text editor, and nothing is lost.

The folder is **shared**: everyone in the community points their app at the same
folder (or a synced copy), so the library is collective. Reading it is
collaborative; what you keep private stays out of it (see *What stays on your
device*).

### A document is one file

The unit of everything is a **document** — one file. A note is a document. A
letter is a document. A meeting transcript is a document. A PDF you cite is
represented by a document. Every document carries its own facts inside it, so it
explains itself without the app.

Every document has:

- **A title.**
- **An author** — a plain person's name. Always the accountable human, even when
  an AI helped (then it's marked "AI on behalf of *Name*").
- **A date** — when it was written or is *about* (a note about yesterday's
  meeting can carry yesterday's date), separate from the exact moment it was
  created.
- **An address** — a short permanent identifier like `f.hegla.093252x`, derived
  from the author and creation time. This is also the filename. **The address
  never changes and files are never renamed**, so a link to a document keeps
  working forever.
- **A kind** (see below).
- **Its content** — either a body of **paragraphs**, or a **wrapped external
  file** (a PDF), but not both.

### Paragraphs are addressable

A document's body is an ordered list of **paragraphs**, and *each paragraph has
its own address* (`f.hegla.093252x#p3`). That's why you can link to, quote, or
transclude one exact paragraph of a document rather than the whole thing. In a
transcript, each statement is a paragraph attributed to its **speaker**, so a
whole meeting is one document you can read top to bottom while still pointing at
any single thing someone said.

### Kinds of document

The kind is a label the author chooses. The ones you'll meet in the app:

| Kind | What it is |
|---|---|
| **Note** | Your own quick thought, often captured in the moment (sometimes by voice). Always the author's own; shows *when* and *where*, not *who*. |
| **Letter** | An authored piece in the community's correspondence — the core kind. |
| **Journal / Thought** | Notes filed into their own places (from the phone or by filing). |
| **Transcript** | A meeting's words, each statement attributed to a speaker. |
| **Source** | A work of reference — a book, paper, or web page — as a first-class citizen with its own address. May wrap the actual file (a PDF). |
| **Quote** | Words lifted verbatim from a source into their own document, linked back to it. |
| **Annotation** | Your comment anchored to a place in a source. |
| **AI Chat** | A conversation captured from claude.ai, ChatGPT, or Gemini. |
| **Card** | A person's public identity record (name, affiliation, ORCID, photo). |
| **Trail** | A guided reading path through several documents. |
| **Glossary** | Terms from the community's discourse, glossed in your own words. |

Unknown kinds are always preserved and shown as-is — the vocabulary grows with
the community, and the app never throws away what it doesn't recognize.

### Links: the library is a web

A document can **link** to other documents, and each link has a **meaning**:

- *cites* — quotes or references (creates a **backlink** on the other document,
  and can transclude the exact paragraph)
- *responds-to* — replies or continues (threads a conversation)
- *supports*, *disagrees-with*, *questions*, *extends*, *summarizes*,
  *relates-to* — the shape of the discourse
- *revises* — this document is a new version of an older one
- *retracts* — this withdraws an older one

A link can point at a whole document, one paragraph, or the **exact words** (a
span) — and if the words have moved, it gracefully falls back to the paragraph
rather than breaking. Because addresses are derivable, you can even **cite a
document before it arrives** — the link resolves when it does.

### For-the-attention-of

A document can be **addressed to** one or more people ("for the attention of
Mark Anderson"). When something is addressed to *you*, the app marks it — that's
what the **Inbox** and attention views are built on. It's a plain name, so it
stays readable by anyone forever.

### Action standing

A document can carry a **standing** — *To Do, In Progress, Done, Cancelled,
Question* — its lifecycle, independent of where it's filed. Because the standing
travels *inside* the file, every device agrees on it. This is what the sidebar's
**Actions** places list.

### Concepts, layouts, and the Map

A document can also carry a pool of **concepts** (named ideas, optionally tagged
as a person, place, etc.) and one or more **layouts** — named **spatial
arrangements** of those concepts with positions and **connections** (lines
between them). This is the data the **Map** stands on: the same document, seen as
a space you arrange and walk through. Positions and connections live in the
document; *how* a node looks (size, color, open/closed) is the reading app's
business, not the document's.

### Sidecars: external files as citizens

A document can **wrap** an external file — a PDF above all — instead of having a
body. The PDF then gains an address, links, and a place in the web, exactly like
any other document. This is how a book or paper becomes something you can cite,
quote, and connect. (In the Map, a node standing for a wrapped file shows a
**blue dot** and offers **Open in Reader**.)

### History only grows

**Nothing rewrites a published document.** A new version is a *new* document that
*revises* the old one; a retraction is a *new* document that *retracts* it. The
app follows revision chains forward, so citations automatically point at the
current version, and superseded documents are hidden by default (with a toggle).
The record is append-only — you can always see what was said and when.

### What stays on your device (never written into documents)

Some things are **your private reading state** and are deliberately kept out of
the shared folder:

- **Filing** — which folder you've filed a note under (Thoughts, Journal,
  Notes, Letters, Archive).
- **Location aliases** — showing a place as "Home" or "Work".
- **Muting** — declining to see an author's documents.
- **Reading position** on a trail, and unread/read marks.
- **AI prompts** and appearance/layout preferences.

Who you decline to hear, and how you keep your own desk, are not part of anyone
else's record.

---

## Part 2 — Workflows

### macOS

**Capture a quick note**
⌘N (or *New Note*) → type → it saves itself into the folder as a **note** and
appears in the **Inbox**. A note captured by voice on the phone arrives the same
way, carrying the place it was made.

**Triage the Inbox**
Open the note, and in its controls column give it a **standing** (To Do) or
**file** it under a folder. Either one moves it out of the Inbox — the Inbox is
only what still awaits a verdict.

**Write a letter to someone**
Write it, and address it *for the attention of* a person. It joins the
correspondence, and on their copy of the library it's marked for them.

**Cite another document**
Reference an address in your text (`[f.hegla.100000a#p2]`) or use copy-cite. It
becomes a **live link**, and a **backlink** appears on the cited document. Arrive
by the link and the cited paragraph flashes; it can unfold in place
(transclusion).

**Bring in a source (a PDF)**
Add the work as a **source**. With the file on hand it becomes a sidecar wrapping
the PDF; without it, a record you can still cite. Then **quote** from it (a quote
document linked back to the source) or **annotate** a place in it.

**Read two documents together (transpointing)**
Open a document, then open a connected one **side by side** with their links
shown — argument and reply, source and response.

**Ask the library / see it whole**
Use the on-device AI views — **AI Insights, Themes, Open Questions, Agreements,
Disagreements, The Stranger** — to read the whole library and report back
(citing documents as live links). All on your Mac; no text leaves it. Prompts are
yours to edit in *Settings ▸ AI*.

**Capture an AI conversation**
On claude.ai / ChatGPT / Gemini, right-click ▸ **Send to Knowledge Space** (Safari
extension). It lands under **Library ▸ AI Chat** as a draft.

**Publish, revise, retract**
A note in the folder is already shared. **Publishing** a finished piece writes an
immutable copy (with a self-describing metadata appendix). To change a published
document, write a **new version** that *revises* it; to withdraw one, write a
document that *retracts* it. The originals are never touched.

**Make or share a view**
The views themselves are shareable single files. Export yours from *Settings ▸
Edit Views*, or start one with *Copy Starter Module*. (See `USER-GUIDE.md` and
`Knowledge Space/Views/VIEW-MODULES.md`.)

### visionOS (the Map)

**Open the library**
In the **Library** window, choose the community folder, then a document — or the
**folder map**, where every document is a node and links between documents are the
threads.

**Explore**
Nodes are concepts, notes, people, and documents, arranged in space. **Double-tap**
a card to open it and read its detail in place.

**Follow a link inward**
An open card that points at another Knowledge Space document offers **Open** — it
opens **in place**, and a **Back** button appears so you can step back out. You
can drill several documents deep and walk back the way you came.

**Open an external file**
A card wrapping a PDF (marked with a **blue dot**, lower-left) offers **Open in
Reader** — the file is handed to your reader app (or the share sheet if none
answers). Point Knowledge Space at where those files live in *Settings ▸ Library
▸ Reader Library*.

---

## The shape in one breath

> A **folder** of self-describing **documents**. Each has a title, an author, a
> date, and a permanent **address**; each is some **kind** (note, letter, source,
> transcript, quote…); each holds **paragraphs** (individually addressable) or
> **wraps a file**. Documents **link** to each other with meaning, are
> **addressed to** people, carry an action **standing**, and can hold **concepts**
> laid out in **space** for the Map. History only ever **grows**. Your private
> reading habits stay on your device; the documents stay shared and readable
> forever.
