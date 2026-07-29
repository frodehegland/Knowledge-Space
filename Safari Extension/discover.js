// discover.js — run this in Safari's Web Inspector console on a live
// conversation page to find the selectors selectors.json needs. It reports
// the repeated data attributes, the DOM depth where turn-like repetition
// lives (with text samples), and likely model-label elements. Selectors
// must be discovered empirically, not guessed; fill the config from what
// this prints, then verify a capture end to end.
//
// Usage: open a conversation, open Web Inspector (⌥⌘I), paste this whole
// file into the Console, and read the tables it logs.

(function discover() {
  const all = Array.from(document.querySelectorAll("*"));

  // 1. Repeated data-* attributes — the sturdiest hooks a frontend offers.
  const attrCounts = {};
  for (const el of all) {
    for (const attr of el.attributes) {
      if (!attr.name.startsWith("data-")) continue;
      // Count by name, and by name=value for low-cardinality values.
      attrCounts[attr.name] = (attrCounts[attr.name] || 0) + 1;
      const pair = `${attr.name}="${attr.value}"`;
      if (attr.value.length < 40) attrCounts[pair] = (attrCounts[pair] || 0) + 1;
    }
  }
  const repeated = Object.entries(attrCounts)
    .filter(([, n]) => n >= 2 && n <= 400)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 40);
  console.log("%cRepeated data-* attributes (candidate turn hooks):", "font-weight:bold");
  console.table(repeated.map(([attr, count]) => ({ attr, count })));

  // 2. Turn-like repetition: siblings that recur with substantial text.
  const groups = {};
  for (const el of all) {
    const text = (el.innerText || "").trim();
    if (text.length < 40 || text.length > 8000) continue;
    if (el.children.length === 0) continue;
    const key = el.tagName.toLowerCase() +
      "." + Array.from(el.classList).slice(0, 2).join(".");
    (groups[key] = groups[key] || []).push(el);
  }
  const turnish = Object.entries(groups)
    .filter(([, els]) => els.length >= 2 && els.length <= 400)
    .sort((a, b) => b[1].length - a[1].length)
    .slice(0, 12);
  console.log("%cTurn-like repeated blocks (selector : count : first sample):", "font-weight:bold");
  console.table(turnish.map(([sel, els]) => ({
    selector: sel,
    count: els.length,
    sample: (els[0].innerText || "").trim().slice(0, 80)
  })));

  // 3. Model-label candidates: short bits of text naming a model.
  const modelWords = /(claude|gpt|gemini|opus|sonnet|haiku|turbo|flash|pro|mini|o[0-9])/i;
  const labels = all
    .filter((el) => el.children.length === 0)
    .map((el) => ({ el, text: (el.innerText || "").trim() }))
    .filter(({ text }) => text && text.length < 40 && modelWords.test(text))
    .slice(0, 20);
  console.log("%cModel-label candidates:", "font-weight:bold");
  console.table(labels.map(({ el, text }) => ({
    text,
    selector: el.tagName.toLowerCase() +
      (el.className ? "." + String(el.className).split(/\s+/).slice(0, 2).join(".") : "")
  })));

  console.log("%cConversation id in the URL:", "font-weight:bold", location.pathname);
})();
