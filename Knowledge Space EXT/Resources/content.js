// Content script: reads the conversation on the page and returns it as a
// capture object matching Knowledge Space's AIConversationImporter.Capture
// schema. All site-specific knowledge is DATA (selectors.json), never code
// here — so a vendor's markup change is a config publish, not an app update.
//
// This script only extracts. It never writes, never asks for a name, never
// knows who the user is: the app stamps the user's own name when it files
// the capture. Failures are returned loudly with the selector that missed,
// so a markup change is a two-minute config fix, not a debugging session.

// Injected on demand, and possibly more than once per page — each capture
// gesture re-runs executeScript. Guard the whole script so it defines its
// bindings and registers its listener exactly once; later injections are
// no-ops that reuse the first listener. Without this, re-declaring these
// top-level bindings on a second run would throw.
if (!window.__ksCaptureInstalled) {
  window.__ksCaptureInstalled = true;

const EXTRACTOR_VERSION = "1.0";

// A remote config (fetched by the background worker into storage.local)
// wins over the bundled copy, so broken selectors can be fixed the same day.
async function loadConfig() {
  try {
    const stored = await browser.storage.local.get("selectorConfig");
    if (stored && stored.selectorConfig && stored.selectorConfig.sites) {
      return stored.selectorConfig;
    }
  } catch (_) { /* fall through to bundled */ }
  const url = browser.runtime.getURL("selectors.json");
  const response = await fetch(url);
  return response.json();
}

function siteConfig(config) {
  const host = location.hostname;
  return (config.sites || []).find((s) => host.includes(s.match)) || null;
}

function conversationID(site) {
  if (!site.conversationIDPattern) return null;
  const match = location.pathname.match(new RegExp(site.conversationIDPattern));
  return match ? match[1] : null;
}

// The conversation scrolls inside a nested container, not the window, and
// only a window of turns is ever in the DOM (the rest are virtualised away).
// Find that scroll container by walking up from a turn to the nearest
// scrollable ancestor; fall back to the document scroller.
function findScrollContainer(site) {
  const seed = document.querySelector(site.turnSelector)
    || document.querySelector(site.humanTurnSelector)
    || document.querySelector(site.assistantTurnSelector);
  let el = seed;
  while (el && el !== document.body) {
    const style = getComputedStyle(el);
    if ((style.overflowY === "auto" || style.overflowY === "scroll")
        && el.scrollHeight > el.clientHeight + 50) {
      return el;
    }
    el = el.parentElement;
  }
  return document.scrollingElement || document.documentElement;
}

// Scroll the real container from top to bottom, harvesting each turn as it
// renders. Turns are keyed by their fixed vertical position in the thread
// (stable whatever the current scroll), so the whole conversation is gathered
// once and in order however long it is — virtualisation stops mattering.
// `harvest(el)` turns a turn element into a record, or null to skip it.
async function collectTurns(site, harvest) {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const container = findScrollContainer(site);
  const isDocScroller = container === document.scrollingElement
    || container === document.documentElement;
  const restore = isDocScroller ? (window.scrollY || 0) : container.scrollTop;

  const seen = new Map(); // rounded position -> record
  const harvestVisible = () => {
    const cTop = isDocScroller ? 0 : container.getBoundingClientRect().top;
    const base = isDocScroller ? (window.scrollY || 0) : container.scrollTop;
    for (const el of document.querySelectorAll(site.turnSelector)) {
      const record = harvest(el);
      if (!record) continue;
      const pos = el.getBoundingClientRect().top - cTop + base;
      const key = Math.round(pos);
      if (!seen.has(key)) seen.set(key, { pos, ...record });
    }
  };

  const setScroll = (y) => {
    if (isDocScroller) window.scrollTo({ top: y, behavior: "auto" });
    else container.scrollTop = y;
  };
  const viewport = isDocScroller ? window.innerHeight : container.clientHeight;
  const maxScroll = () => (isDocScroller
    ? Math.max(0, document.documentElement.scrollHeight - window.innerHeight)
    : container.scrollHeight - container.clientHeight);
  const step = Math.max(200, Math.floor(viewport * 0.75));

  setScroll(0);
  await sleep(450);
  harvestVisible();
  let y = 0;
  let guard = 0;
  while (y < maxScroll() && guard < 600) {
    guard += 1;
    y = Math.min(y + step, maxScroll());
    setScroll(y);
    await sleep(300);
    harvestVisible();
  }
  // Settle at the very bottom so the final turns render, then restore.
  setScroll(maxScroll());
  await sleep(400); harvestVisible();
  await sleep(300); harvestVisible();
  setScroll(restore);

  return Array.from(seen.values()).sort((a, b) => a.pos - b.pos);
}

// A turn's DOM becomes plain text with Markdown preserved: code fenced with
// its language when the DOM exposes it, lists as - / 1., blockquotes with >.
// Text inside a fenced block is never re-parsed, so a code sample containing
// "Something: value" is not mistaken for a speaker line downstream.
function blockToMarkdown(node) {
  const blocks = [];
  // Chrome that lives inside a turn but is not the message: action bars
  // (Copy / Retry / Read aloud / Edit), toolbars, buttons, icons, and the
  // screen-reader-only labels ("You said:" / "Claude responded:") that
  // otherwise leak in as headings. Skipped whole, so none of it lands in
  // the captured text.
  const SKIP = "button, svg, [role='toolbar'], [data-testid^='action-bar'], [data-testid='wiggle-controls-actions'], .sr-only, [class*='sr-only']";
  const walk = (el) => {
    for (const child of el.children) {
      if (child.matches && child.matches(SKIP)) continue;
      const tag = child.tagName.toLowerCase();
      if (tag === "pre") {
        const code = child.querySelector("code");
        const lang = code ? guessLang(code.className) : "";
        const text = (code ? code.innerText : child.innerText).replace(/\n$/, "");
        blocks.push("```" + lang + "\n" + text + "\n```");
      } else if (tag === "ul" || tag === "ol") {
        const ordered = tag === "ol";
        let n = 1;
        for (const li of child.querySelectorAll(":scope > li")) {
          const marker = ordered ? `${n++}. ` : "- ";
          blocks.push(marker + li.innerText.trim());
        }
      } else if (tag === "blockquote") {
        blocks.push("> " + child.innerText.trim().replace(/\n/g, "\n> "));
      } else if (/^h[1-6]$/.test(tag)) {
        const level = Math.min(3, parseInt(tag[1], 10));
        blocks.push("#".repeat(level) + " " + child.innerText.trim());
      } else if (tag === "p") {
        const text = child.innerText.trim();
        if (text) blocks.push(text);
      } else if (child.children.length) {
        walk(child);
      } else {
        const text = child.innerText.trim();
        if (text) blocks.push(text);
      }
    }
  };
  walk(node);
  if (blocks.length === 0) {
    const text = node.innerText.trim();
    if (text) blocks.push(text);
  }
  return blocks;
}

function guessLang(className) {
  const match = (className || "").match(/language-([a-z0-9+#-]+)/i);
  return match ? match[1] : "";
}

function readModel(site) {
  if (!site.modelLabelSelector) return null;
  const el = document.querySelector(site.modelLabelSelector);
  if (!el) return null;
  // The dropdown carries an icon glyph and sometimes a second line; keep
  // only the first line and strip zero-width and private-use characters,
  // so "Opus 5 High\n" reads as "Opus 5 High".
  const clean = (el.innerText || "")
    .split("\n")[0]
    .replace(/[\u200B-\u200F\u2028\u2029\uE000-\uF8FF]/g, "")
    .trim();
  return clean || null;
}

// "Claude Opus 5" -> family "Claude Opus", version "5". Never inferred from
// anything but the displayed string; if it cannot be split, family is the
// whole string and version is absent.
function parseModel(raw) {
  if (!raw) return { modelFamily: null, modelVersion: null };
  const match = raw.match(/^(.*?)[\s-]*([\d.]+[a-z]?)\s*$/i);
  if (match) return { modelFamily: match[1].trim(), modelVersion: match[2] };
  return { modelFamily: raw, modelVersion: null };
}

function attachmentsPresent() {
  return !!document.querySelector(
    "img[alt]:not([alt='']), [data-testid*='attachment'], [aria-label*='attachment' i]"
  );
}

async function capture() {
  const config = await loadConfig();
  const site = siteConfig(config);
  if (!site) {
    return { error: `No selector config matches ${location.hostname}.` };
  }

  // A conversation list, not a conversation: say so rather than capture junk.
  const allTurns = Array.from(document.querySelectorAll(site.turnSelector));
  if (allTurns.length === 0) {
    if (site.conversationListSelector &&
        document.querySelector(site.conversationListSelector)) {
      return { error: "This looks like a conversation list, not an open conversation. Open a conversation first." };
    }
    return { error: `Found no turns — the turnSelector matched nothing (selector: ${site.turnSelector}). The page's markup may have changed.` };
  }

  const modelRaw = readModel(site);
  const { modelFamily, modelVersion } = parseModel(modelRaw);
  const agentSpeaker = {
    id: "spk-agent-1",
    kind: "agent",
    name: modelRaw || `${site.vendor} assistant`,
    vendor: site.vendor,
    modelFamily,
    modelVersion,
    modelRaw,
    modelConfidence: modelRaw ? "readFromUI" : "unknown"
  };
  const humanSpeaker = { id: "spk-human", kind: "person", name: "You" };

  // A turn is classified by its role marker, which may be the turn element
  // itself, an ancestor, or — commonly — a descendant inside the turn (e.g.
  // Claude's user-message / action-bar live within the turn block). Checking
  // all three directions is what lets a container-level turnSelector still be
  // told apart into human and assistant.
  const matchesRole = (el, selector) =>
    el.matches(selector) ||
    el.closest(selector) !== null ||
    el.querySelector(selector) !== null;

  // Harvest one turn element into { human, paragraphs }, or null when it is
  // scaffolding or empty. Called for every turn that renders during the walk.
  const harvest = (el) => {
    const human = matchesRole(el, site.humanTurnSelector);
    const assistant = matchesRole(el, site.assistantTurnSelector);
    if (!human && !assistant) return null;
    const paragraphs = blockToMarkdown(el);
    if (paragraphs.length === 0) return null;
    return { human, paragraphs };
  };

  // Walk the whole thread, gathering turns in order however long it is.
  const collected = await collectTurns(site, harvest);

  const body = [];
  let lastHumanTurnID = null;
  let index = 0;
  for (const record of collected) {
    index += 1;
    const turnID = "t" + String(index).padStart(2, "0");
    const paragraphs = record.paragraphs.map((text, i) => ({
      id: "p" + (i + 1),
      text
    }));
    if (record.human) {
      body.push({ id: turnID, speaker: "spk-human", provenance: "human", paragraphs });
      lastHumanTurnID = turnID;
    } else {
      body.push({
        id: turnID,
        speaker: "spk-agent-1",
        provenance: "generated",
        verification: "unverified",
        elicitedBy: lastHumanTurnID,
        paragraphs
      });
    }
  }

  if (body.length === 0) {
    return { error: `Turns were found but none classified as a speaker — the human/assistant selectors may be wrong (human: ${site.humanTurnSelector}). Importing would misattribute the whole document.` };
  }
  const speakerKinds = new Set(body.map((t) => t.speaker));
  if (speakerKinds.size < 2) {
    return { error: "Every turn classified as one speaker — the human/assistant discriminator is wrong. Not capturing, to avoid a badly attributed document." };
  }

  const now = new Date().toISOString();
  const title = (document.querySelector(site.titleSelector || "title")?.innerText || document.title || "").trim();

  return {
    capture: {
      title: title || null,
      capturedAt: now,
      conversationCompletedAt: now,
      timeConfidence: "captureTime",
      fidelity: "verbatim",
      source: {
        surface: site.surface || site.match,
        sourceURL: location.href,
        conversationID: conversationID(site),
        captureMethod: "domExtraction",
        extractorVersion: EXTRACTOR_VERSION,
        selectorConfigVersion: config.version || null
      },
      speakers: [humanSpeaker, agentSpeaker],
      body,
      attachmentsPresent: attachmentsPresent()
    }
  };
}

browser.runtime.onMessage.addListener((message) => {
  if (message && message.type === "capture") {
    return capture().catch((error) => ({ error: String(error && error.message || error) }));
  }
  return undefined;
});

} // end run-once guard (window.__ksCaptureInstalled)
