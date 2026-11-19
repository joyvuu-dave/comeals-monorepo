// The iPhone's and iPad's text size setting (Settings → Accessibility →
// Display & Text Size → Larger Text), in iOS Safari (challenge 32).
//
// A page follows that setting only through the system's text styles:
// `font: -apple-system-body` is 17px at the default setting, 14px at the
// smallest and 53px at the largest. Every size in this app is in rem,
// so the root's font size sets them all. The root gets 16px times the
// system size over 17: exactly 16px, as before, at the default setting,
// and larger or smaller with the setting.
//
// CSS alone cannot do this: setting `font: -apple-system-body` on the
// root would make the text 17px for everyone, and CSS cannot divide one
// length by another to scale it back.
//
// The root stops at 200% (32px), the size WCAG 1.4.4 asks for and the
// size bin/test-ios checks every screen at.
//
// Only iOS WebKit (Safari, and every other browser on an iPhone) has
// -webkit-touch-callout. In desktop Safari, -apple-system-body is the
// Mac's 13px, which says nothing about a text size setting, so nothing
// changes there.

export const BASE_PX = 16;
export const APPLE_DEFAULT_BODY_PX = 17;
export const LARGEST_PX = 2 * BASE_PX;

export function rootFontSize(systemBodyPx: number): number {
  return Math.min((BASE_PX * systemBodyPx) / APPLE_DEFAULT_BODY_PX, LARGEST_PX);
}

function isIOSWebKit(): boolean {
  return (
    typeof CSS !== "undefined" &&
    typeof CSS.supports === "function" &&
    CSS.supports("-webkit-touch-callout", "none")
  );
}

// Sets the root's font size from the setting now, and again each time
// the page shows after being hidden: a person changes the setting in
// the Settings app and comes back. Returns a function that stops it.
export function followSystemTextSize(doc: Document = document): () => void {
  if (!isIOSWebKit()) return () => {};

  const probe = doc.createElement("span");
  probe.className = "system-text-size-probe";
  probe.setAttribute("aria-hidden", "true");
  probe.style.cssText =
    "font: -apple-system-body; position: absolute; visibility: hidden;";
  doc.body.appendChild(probe);

  function apply() {
    const systemPx = parseFloat(getComputedStyle(probe).fontSize);
    // No size (the probe was removed, or the style did not apply):
    // keep the stylesheet's 16px.
    if (!(systemPx > 0)) return;
    doc.documentElement.style.fontSize = `${rootFontSize(systemPx)}px`;
  }

  apply();
  doc.addEventListener("visibilitychange", apply);
  return function stop() {
    doc.removeEventListener("visibilitychange", apply);
    probe.remove();
    doc.documentElement.style.removeProperty("font-size");
  };
}
