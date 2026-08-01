# Knowledge Space — User Guide

Knowledge Space is a reading, writing, and thinking environment for a **community
folder**: a plain folder of self-describing `.liquid.json` documents (the Origami
format), usually kept in iCloud or another shared drive so a group works from the
same library. Nothing is locked inside the app — every document is readable text
on disk, and the app is just a set of ways of seeing and working with it.

The same folder is read by two apps that ship here:

- **macOS** — the full library: read, write, file, and see the community through
  many views.
- **visionOS** — the **Map**: the library as a spatial thing you stand inside.

They share the folder, the document format, and the view modules, so work done in
one shows up in the other.

---

## Getting started

1. Launch Knowledge Space.
2. When asked, **choose the community folder** — the folder of `.liquid.json`
   documents. On macOS this is *Choose Folder…*; on visionOS you pick it from the
   **Library** window. The choice is remembered between sessions.
3. The library scans, and the documents appear.

If the folder is empty, that is fine — start writing (macOS) and the notes you
make land in it.

---

## macOS

### The sidebar — ways into the library

The left column groups the whole library:

- **Inbox** — what is new and still awaits a verdict: your own notes plus anything
  unread. A note leaves the Inbox once you file it or give it a standing.
- **Timeline** — every note by time, newest first (Today, Yesterday, then dates).
- **Places** — the same notes grouped by country, with the town on each row.
- **Map** — the spatial view (also the whole of the visionOS app; see below).
- **People** — everyone with a contact record or identity card in the folder.
  Click a person for the notes that name them; click the reveal triangle to see
  their details; Ctrl-click to edit.
- **Transcripts** — meetings' words, each statement attributed.
- **Draft Letters** — letters still being written.
- **Actions** — notes by standing: To Do, In Progress, Done, Cancelled, Question.
- **Library** — the reference shelf: Sources, Books, Articles, Authors, Quotes,
  Notes, and **AI Chat** (conversations captured from the web).
- **Digest** — your own granted documents folder, distilled.
- **Filed** — one row per folder you have filed notes under.
- **Views** — the installed **view modules** (see *Views*, below).

### Writing and reading

- **New note:** ⌘N, or *New Note* in the sidebar. Type — it saves itself.
- Notes and letters are their own **writing page**; other kinds open in the
  **reader**.
- **In the list vs. in a pane** — in *Settings ▸ Appearance* you choose whether a
  clicked document grows open **in place** in the list, or opens in its own detail
  pane. Either way, all its words are held.
- **The note's controls** — when a note is open, rest the pointer on the **Show
  Column** icon (top-right of the open note) to bring its options column in beside
  the words: filing, action standing, location, and more. It follows the pointer
  and folds away when you leave.
- **Full screen** gives the words alone — an 800-point centered page. The left
  edge peeks the sidebar back in; the right edge peeks the controls.
- **Search** narrows every list by title, author, or text.

### Parallel reading (transpointing)

Open a document, then open a connected one **side by side** with the links
between them visible. Insight views and the Connections web can open a pair
directly.

### AI insight views (on-device)

Several views — **AI Insights, Themes, Open Questions, Agreements,
Disagreements, The Stranger**, and others — read the whole library with Apple
Intelligence **on the Mac**. No text leaves the machine. Each has a **Generate**
button and an editable prompt in *Settings ▸ AI*. They report in prose, citing
documents by address so the citations are live links. If Apple Intelligence is
unavailable, the view says so.

### Capturing AI chats (Safari extension)

With the Safari extension enabled, right-click in a conversation on **claude.ai,
ChatGPT, or Gemini** and choose **Send to Knowledge Space**. The conversation
lands under **Library ▸ AI Chat** as a draft.

### Identity and people

Your public identity is an ordinary card document in the folder (*your name,
affiliation, ORCID, photo*), the same card the phone reads and writes. People in
the **People** place come from the shared contact records (`People.json`) joined
with any identity cards in the folder.

---

## visionOS — the Map

On Apple Vision Pro, Knowledge Space **is the Map**: the library as a volume you
stand inside, documents and concepts as cards, the links between them as threads.

### Opening a library

- Open the **Library** window and choose the community folder.
- Choose a document to see its map, or show the **folder map** — every document a
  node, the links between documents the threads.

### Working with nodes

- A **node** is a card: a concept, a note, a person, a document.
- **Double-tap** a card to open it — its definition or detail unfolds in place.
- An open card carries its own commands (they live *inside* the card; tapping a
  node never opens anything on its own):
  - **Open** — follow a link to another Knowledge Space document. It opens **in
    place**, and a **Back** button appears in the controls to step out again.
  - **Open in Reader** — hand an **external file** (a PDF above all) to another
    app. It tries the Reader app first and falls back to the system share sheet.
- **A small blue dot in a card's lower-left corner** marks a node that points at
  an external document — so you can see which nodes carry a file without opening
  them.

### The controls window

A plain window beside the Map holds:

- **Library** — back to choosing documents and folders.
- **Back** — appears once you have drilled into a linked document; steps out to
  where you came from.
- The current map's title, sorting, and node commands.

### Settings

*Settings ▸ Library* holds the Reader handoff:

- **Reader Library** — choose the folder where Reader keeps its files. A node's
  external file (a PDF, above all) is found here when it is not beside the
  document in the community folder.
- **Open in Reader** — the URL scheme used to hand a file to Reader
  (`reader://open?path=<file>` by default, where `<file>` becomes the file's
  path). If no app answers the scheme, the system share sheet opens instead.

*Settings ▸ Appearance* controls how cards look (borders, opacity when open or
selected, how much text a card shows open and closed) and node movement.

> **Note on external files:** to keep scans fast, a subfolder named **`PDF`** in
> the community folder is skipped by the routine library scan. Files there are
> still opened on demand by the Map's *Open in Reader*.

---

## Views are yours to make

The views are not fixed features — they are **view modules**, each a single Swift
file the app treats exactly as it treats the built-in ones. Anyone in the
community can write a new way of seeing the library and share it as one file. A
module file travels unchanged between Knowledge Space and Origami Text.

- **Install a shared view:** drop its `.swift` file into the Xcode project and add
  one line to the registry (or import a `.origamiview` archive from *Settings ▸
  Edit Views* — it waits on the shelf as "awaiting build" until the code is
  compiled in).
- **Share yours:** *Settings ▸ Edit Views* exports a module as a Swift file (with
  the one registry line to add) or as a `.origamiview` archive.
- **Start one:** *Settings ▸ View Modules ▸ Copy Starter Module.*

See `Knowledge Space/Views/VIEW-MODULES.md` for the full author's guide.

*(Maintainers: the export snapshot is regenerated by
`Tools/generate-module-sources.swift`; see `Tools/README-module-sources.md`.)*

---

## Where things live

- **Documents** — plain `.liquid.json` files in the community folder; each carries
  its own metadata (Visual-Meta), so it stays readable outside the app.
- **Your notes, filings, and reading preferences** — notes are documents in the
  folder; filing and location aliases are this Mac's, kept as preferences, never
  written into anyone's documents.
- **Identity cards and contacts** — ordinary card documents plus `People.json` in
  the shared folder.
