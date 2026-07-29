// Background service worker: orchestration only. The user triggers a capture
// either from the toolbar button or — more reliably in current Safari, where
// the toolbar button can be hidden — from the right-click "Send to Knowledge
// Space" menu. Both grant activeTab on the user's gesture, so the extractor
// can be injected into the current tab without any pre-granted site access.
// The extracted conversation is then handed to the native app over native
// messaging, chunked, because a long conversation serialises to hundreds of
// kilobytes and native messages have a size ceiling. Success is a brief green
// check; failure is a loud red badge with a one-line reason, because a silent
// partial capture is worse than no capture.

// Safari ignores this identifier, but the API takes one; it routes to this
// extension's SafariWebExtensionHandler regardless.
const NATIVE_APP = "knowledge-space";

// Stay well inside the native-message ceiling. Chunking from the start is
// far cheaper than discovering the limit in the field.
const CHUNK_SIZE = 48 * 1024;

// Optional: where a fresh selector config is published. Left null until a
// server exists; the bundled selectors.json is the fallback and the default.
const SELECTOR_CONFIG_URL = null;

// The sites the capture menu offers itself on. Kept in step with the
// surfaces selectors.json knows how to read.
const CAPTURE_SITES = [
  "https://claude.ai/*",
  "https://chatgpt.com/*",
  "https://gemini.google.com/*"
];

const MENU_ID = "ks-capture";

function newID() {
  return "cap-" + Date.now() + "-" + Math.random().toString(36).slice(2, 8);
}

function chunk(str) {
  const parts = [];
  for (let i = 0; i < str.length; i += CHUNK_SIZE) {
    parts.push(str.slice(i, i + CHUNK_SIZE));
  }
  return parts.length ? parts : [""];
}

async function sendToApp(captureObject) {
  const json = JSON.stringify(captureObject);
  const id = newID();
  const parts = chunk(json);
  for (let seq = 0; seq < parts.length; seq++) {
    const reply = await browser.runtime.sendNativeMessage(NATIVE_APP, {
      id,
      seq,
      total: parts.length,
      chunk: parts[seq]
    });
    // The handler acknowledges the final chunk with { ok } or { error }.
    if (reply && reply.error) throw new Error(reply.error);
    if (seq === parts.length - 1 && reply && reply.ok === false) {
      throw new Error(reply.reason || "The app could not file the capture.");
    }
  }
}

async function badge(text, color, title) {
  try {
    await browser.action.setBadgeText({ text });
    if (color) await browser.action.setBadgeBackgroundColor({ color });
    if (title) await browser.action.setTitle({ title });
  } catch (_) { /* badge is best-effort */ }
}

async function clearBadgeSoon() {
  setTimeout(() => badge("", null, "Send to Knowledge Space"), 4000);
}

// On-page feedback: current Safari often hides the toolbar button, so the
// badge is invisible. A brief corner toast tells the user — and us, while
// debugging — exactly what happened, including the failure reason.
// kind: "ok" (green), "err" (red), or "info" (grey, and it stays until the
// next toast replaces it — used for the "Capturing…" progress note while the
// content script walks a long thread).
async function showToast(tabId, text, kind) {
  try {
    await browser.scripting.executeScript({
      target: { tabId },
      func: (message, k) => {
        const id = "ks-capture-toast";
        document.getElementById(id)?.remove();
        const el = document.createElement("div");
        el.id = id;
        el.textContent = message;
        const bg = k === "err" ? "#FF3B30" : k === "info" ? "#3A3A3C" : "#34C759";
        Object.assign(el.style, {
          position: "fixed", zIndex: "2147483647", top: "16px", right: "16px",
          maxWidth: "360px", padding: "12px 16px", borderRadius: "10px",
          font: "600 13px -apple-system, system-ui, sans-serif", color: "#fff",
          background: bg,
          boxShadow: "0 4px 16px rgba(0,0,0,0.25)", whiteSpace: "pre-wrap"
        });
        document.documentElement.appendChild(el);
        // Info stays (progress); ok/err clear themselves.
        if (k !== "info") setTimeout(() => el.remove(), k === "err" ? 9000 : 3500);
      },
      args: [text, kind]
    });
  } catch (_) { /* toast is best-effort */ }
}

// The one capture path, shared by the toolbar button and the context menu.
// The triggering gesture grants activeTab, so we can inject the extractor on
// demand — no declared content script, no pre-granted host permission.
async function runCapture(tab) {
  if (!tab || tab.id == null) return;
  await badge("…", "#8E8E93", "Capturing…");
  try {
    // Put the extractor in the page (idempotent — it guards against a second
    // listener), then ask it for the conversation.
    await browser.scripting.executeScript({
      target: { tabId: tab.id },
      files: ["content.js"]
    });
    // A long thread is walked top to bottom; say so, since it takes a moment.
    await showToast(tab.id, "Capturing the whole conversation…", "info");
    const result = await browser.tabs.sendMessage(tab.id, { type: "capture" });
    if (!result || result.error) {
      throw new Error((result && result.error) || "No response from the page.");
    }
    await sendToApp(result.capture);
    await badge("✓", "#34C759", "Sent to Knowledge Space");
    await showToast(tab.id, "Sent to Knowledge Space ✓", "ok");
  } catch (error) {
    // Loud and specific: the reason rides on the toolbar title and a toast.
    const reason = String(error && error.message || error);
    await badge("!", "#FF3B30", "Not captured — " + reason);
    await showToast(tab.id, "Not captured — " + reason, "err");
    console.error("Knowledge Space capture failed:", error);
  } finally {
    clearBadgeSoon();
  }
}

browser.action.onClicked.addListener((tab) => runCapture(tab));

// The reliable entry point: a right-click item on the supported sites. In
// current Safari the toolbar button is often hidden, so this is how the user
// actually reaches the capture — and the click grants activeTab.
function createMenu() {
  if (!browser.contextMenus) return;
  browser.contextMenus.removeAll(() => {
    browser.contextMenus.create({
      id: MENU_ID,
      title: "Send to Knowledge Space",
      contexts: ["page", "selection"],
      documentUrlPatterns: CAPTURE_SITES
    });
  });
}

if (browser.contextMenus) {
  browser.contextMenus.onClicked.addListener((info, tab) => {
    if (info.menuItemId === MENU_ID) runCapture(tab);
  });
}

// Best-effort remote selector refresh: content.js prefers this over the
// bundled copy, so broken selectors are fixed the same day, no app update.
async function refreshSelectorConfig() {
  if (!SELECTOR_CONFIG_URL) return;
  try {
    const response = await fetch(SELECTOR_CONFIG_URL, { cache: "no-cache" });
    const config = await response.json();
    if (config && config.sites) {
      await browser.storage.local.set({ selectorConfig: config });
    }
  } catch (error) {
    console.warn("Selector config refresh failed; using bundled copy.", error);
  }
}

browser.runtime.onInstalled.addListener(() => { createMenu(); refreshSelectorConfig(); });
browser.runtime.onStartup.addListener(() => { createMenu(); refreshSelectorConfig(); });
