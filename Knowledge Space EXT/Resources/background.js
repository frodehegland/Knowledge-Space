// Background service worker: orchestration only. One toolbar click asks the
// content script to extract, then hands the result to the native app over
// native messaging — chunked, because a long conversation serialises to
// hundreds of kilobytes and native messages have a size ceiling. Success is
// a brief green check; failure is a loud red badge with a one-line reason,
// because a silent partial capture is worse than no capture.

// Safari ignores this identifier, but the API takes one; it routes to this
// extension's SafariWebExtensionHandler regardless.
const NATIVE_APP = "knowledge-space";

// Stay well inside the native-message ceiling. Chunking from the start is
// far cheaper than discovering the limit in the field.
const CHUNK_SIZE = 48 * 1024;

// Optional: where a fresh selector config is published. Left null until a
// server exists; the bundled selectors.json is the fallback and the default.
const SELECTOR_CONFIG_URL = null;

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

browser.action.onClicked.addListener(async (tab) => {
  await badge("…", "#8E8E93", "Capturing…");
  try {
    const result = await browser.tabs.sendMessage(tab.id, { type: "capture" });
    if (!result || result.error) {
      throw new Error((result && result.error) || "No response from the page.");
    }
    await sendToApp(result.capture);
    await badge("✓", "#34C759", "Sent to Knowledge Space");
  } catch (error) {
    // Loud and specific: the reason rides on the toolbar title.
    await badge("!", "#FF3B30", "Not captured — " + (error.message || error));
    console.error("Knowledge Space capture failed:", error);
  } finally {
    clearBadgeSoon();
  }
});

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

browser.runtime.onInstalled.addListener(refreshSelectorConfig);
browser.runtime.onStartup.addListener(refreshSelectorConfig);
