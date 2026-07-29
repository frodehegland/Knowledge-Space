// Content script: reads the conversation on the page and returns it as a
// capture object matching Knowledge Space's AIConversationImporter.Capture
// schema. All site-specific knowledge is DATA (selectors.json), never code
// here — so a vendor's markup change is a config publish, not an app update.
//
// This script only extracts. It never writes, never asks for a name, never
// knows who the user is: the app stamps the user's own name when it files
// the capture. Failures are returned loudly with the selector that missed,
// so a markup change is a two-minute config fix, not a debugging session.

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

// Long threads virtualise off-screen turns; scroll to the top and wait for
// the turn count to stop growing, or the capture silently misses the start.
async function stabiliseTurns(site) {
  const countTurns = () =>
    document.querySelectorAll(site.turnSelector).length;
  window.scrollTo({ top: 0, behavior: "auto" });
  let last = -1;
  let stableFor = 0;
  for (let i = 0; i < 40 && stableFor < 3; i++) {
    await new Promise((r) => setTimeout(r, 250));
    window.scrollTo({ top: 0, behavior: "auto" });
    const now = countTurns();
    stableFor = now === last ? stableFor + 1 : 0;
    last = now;
  }
  return last;
}

// A turn's DOM becomes plain text with Markdown preserved: code fenced with
// its language when the DOM exposes it, lists as - / 1., blockquotes with >.
// Text inside a fenced block is never re-parsed, so a code sample containing
// "Something: value" is not mistaken for a speaker line downstream.
function blockToMarkdown(node) {
  const blocks = [];
  const walk = (el) => {
    for (const child of el.children) {
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
  const raw = el ? el.innerText.trim() : "";
  return raw || null;
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

  await stabiliseTurns(site);
  const turns = Array.from(document.querySelectorAll(site.turnSelector));

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

  const isHuman = (el) =>
    el.matches(site.humanTurnSelector) || el.closest(site.humanTurnSelector) !== null;
  const isAssistant = (el) =>
    el.matches(site.assistantTurnSelector) || el.closest(site.assistantTurnSelector) !== null;

  const body = [];
  let lastHumanTurnID = null;
  let index = 0;
  for (const turn of turns) {
    const human = isHuman(turn);
    const assistant = isAssistant(turn);
    if (!human && !assistant) continue; // scaffolding between turns
    index += 1;
    const turnID = "t" + String(index).padStart(2, "0");
    const paragraphs = blockToMarkdown(turn).map((text, i) => ({
      id: "p" + (i + 1),
      text
    }));
    if (paragraphs.length === 0) { index -= 1; continue; }
    if (human) {
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
