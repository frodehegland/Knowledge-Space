# Knowledge Space — Safari extension for AI conversation capture

The Safari Web Extension is now a real target in the project:
**`Knowledge Space EXT`**, embedded in the Knowledge Space app. Its shipping
files live under `Knowledge Space EXT/` (a synchronized folder group, so
files on disk are automatically part of the target — no `.pbxproj` edit).

This folder keeps the developer tooling and notes that are **not** shipped:

```
Safari Extension/
  README.md      this wiring/verification guide
  discover.js    console tool to find selectors on a live page (not shipped)
```

The shipping files (promoted into the `Knowledge Space EXT` target):

```
Knowledge Space EXT/
  SafariWebExtensionHandler.swift   native receipt: reassembles chunks, writes to App Group inbox
  Resources/
    manifest.json                   MV3 manifest, scoped host permissions, one-click action
    background.js                   toolbar click → extract → chunked native send
    content.js                      DOM extraction → capture JSON
    selectors.json                  site config (DATA, not code) — VERIFY before shipping
    images/…                        icons
```

The app side is already wired and building:

- `LiquidDoc` carries `aiSource`, `agents`, and per-paragraph `provenance` /
  `verification` / `elicitedBy` (`OrigamiText/LiquidDoc.swift`,
  `LiquidDocWriting.swift`), plus the `aiConversation` document type.
- `AIConversation.swift` parses the capture JSON these files emit.
- `AIConversationInbox.swift` watches the App Group inbox and files captures
  as **drafts** in the Inbox; `ContentView` starts the watch at launch
  (`ContentView.swift` `.task { state.startWatchingAIInbox() }`).
- Lifting a statement (`Transcripts.swift`) carries the provenance and the
  model's identity into the new note.

## What still needs a human (Xcode UI only)

The code is in place. The remaining steps can only be done in Xcode's UI:

1. **App Group entitlement on BOTH targets** — the `Knowledge Space` app and
   the `Knowledge Space EXT` extension — set to the same id:

   ```
   group.info.augmentedtext.knowledgespace
   ```

   This string appears in three places that must agree and already do in
   code: `AppState.aiInboxAppGroupID`, `SafariWebExtensionHandler.appGroupID`,
   and the entitlement. Add the *App Groups* capability to each target under
   **Signing & Capabilities** and enter the id above.

2. Build and run the app; enable the extension in **Safari ▸ Settings ▸
   Extensions**, and **Allow** it on the three supported sites.

> ⚠️ **Shared bundle id note.** This project's desktop target must never be
> built for iphoneos (it shares a bundle id with the iOS notes app). When you
> later add iOS/iPadOS support for the extension, give it its own bundle id
> and do not flip the Mac app's supported destinations.

## Data contract (extension → app)

The content script emits, and `AIConversationImporter.Capture` reads:

```json
{
  "title": "…", "capturedAt": "ISO8601", "conversationCompletedAt": "ISO8601",
  "timeConfidence": "captureTime", "fidelity": "verbatim",
  "source": { "surface": "claude.ai", "sourceURL": "…", "conversationID": "…",
              "captureMethod": "domExtraction", "extractorVersion": "1.0" },
  "speakers": [ { "id": "spk-human", "kind": "person", "name": "You" },
                { "id": "spk-agent-1", "kind": "agent", "name": "Claude Opus 5",
                  "vendor": "Anthropic", "modelRaw": "…", "modelConfidence": "readFromUI" } ],
  "body": [ { "id": "t01", "speaker": "spk-human", "provenance": "human",
              "paragraphs": [ { "id": "p1", "text": "…" } ] },
            { "id": "t02", "speaker": "spk-agent-1", "provenance": "generated",
              "verification": "unverified", "elicitedBy": "t01",
              "paragraphs": [ { "id": "p1", "text": "…" } ] } ]
}
```

The app flattens turns into addressable paragraphs (`t02.p1`), mints a proper
document id, stamps the **user's own name** over the `"You"` placeholder at
ingest (so the extension never needs it), and files as a draft. Re-importing
the same `conversationID` updates in place and preserves any verification the
reader has set.

## Divergences from the brief (deliberate)

- **Name stamping happens at app ingest, not in the handler.** The app owns
  the user record and overwrites the placeholder when it files the capture,
  so the handler stays dumb and there is nothing to configure.
- **`attachmentsPresent`** is detected in `content.js` and sent, but not yet
  mapped into `aiSource.attachmentsPresent` on the app side — wire it in
  `AIConversationImporter` if you want the reader warning in v1.

## Before shipping

- **Verify every selector in `selectors.json` with `discover.js` on a live
  page.** The values shipped here are starting points and will drift.
- **Test a very long conversation.** Lazy-rendered history is the most likely
  cause of quiet data loss; `content.js` scrolls to top and waits for the
  turn count to stabilise, but confirm it catches the beginning.
- Confirm the native-message chunking round-trips (`background.js` splits at
  48 KB; the handler reassembles on disk).
