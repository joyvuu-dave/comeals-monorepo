// Accessibility checks for the browser suite (challenge 32).
//
// expectAccessible(page) runs axe on the page as it is now and fails
// on any violation of WCAG 2.2 A and AA, and of axe's best-practice
// rules. The visual suite calls it before every screenshot, so every
// screen state it pictures is checked.
//
// walkWithTab(page) presses Tab from where the focus is until the
// focus comes back to the first stop, and records each stop. The
// keyboard spec (tests/e2e/keyboard.spec.js) uses it to check that
// every stop shows the focus ring and that nothing a mouse can click
// is left out.
const AxeBuilder = require("@axe-core/playwright").default;
const { expect } = require("@playwright/test");

const AXE_TAGS = [
  "wcag2a",
  "wcag2aa",
  "wcag21a",
  "wcag21aa",
  "wcag22aa",
  "best-practice",
];

// One line per element that fails a rule, with axe's reason (for
// color contrast: the ratio and both colors), so the failure says what
// to fix without opening the report.
function describeViolations(violations) {
  return violations.flatMap((violation) =>
    violation.nodes.map((node) => {
      const reason = [...node.any, ...node.all, ...node.none]
        .map((check) => check.message)
        .filter(Boolean)[0];
      return (
        `${violation.id} (${violation.impact}): ${violation.help} — ` +
        `${node.target.join(" ")}` +
        (reason ? ` — ${reason}` : "")
      );
    }),
  );
}

// toHaveScreenshot finishes every running CSS transition and
// animation before it takes the picture, and cancels the ones that
// never end (a spinner). axe must see the same screen: in the middle of
// a fade it would measure a color that is never shown at rest.
function settleAnimations() {
  for (const animation of window.document.getAnimations()) {
    const timing = animation.effect && animation.effect.getComputedTiming();
    if (timing && timing.endTime === Infinity) continue;
    animation.finish();
  }
}

async function expectAccessible(page) {
  await page.evaluate(settleAnimations);
  const result = await new AxeBuilder({ page }).withTags(AXE_TAGS).analyze();
  expect(
    describeViolations(result.violations),
    "axe found accessibility violations on this screen",
  ).toEqual([]);
}

// Animations would make the focus ring's width read as a value between
// 0 and its end value for 0.1s after each Tab.
async function stopTransitions(page) {
  await page.addStyleTag({
    content: "*, *::before, *::after { transition: none !important; }",
  });
}

// Facts about the element that has the focus, read in the page. The
// element is marked with data-tab-stop, so the walk knows when the
// focus comes back to an element it has seen, and missedByTab can tell
// which elements the walk reached.
function readFocus(index) {
  const el = window.document.activeElement;
  if (!el || el === window.document.body) return { none: true };
  if (el.hasAttribute("data-tab-stop")) return { seenBefore: true };
  el.setAttribute("data-tab-stop", String(index));
  // A calendar entry draws its ring around the whole entry, not the
  // link inside it, because the entry's text box cuts off what
  // overflows it (styles.css).
  const ringed = el.closest(".rbc-event") || el;
  const style = window.getComputedStyle(ringed);
  return {
    tag: el.tagName.toLowerCase(),
    name: (
      el.getAttribute("aria-label") ||
      el.textContent ||
      el.getAttribute("placeholder") ||
      el.getAttribute("type") ||
      ""
    )
      .trim()
      .replace(/\s+/g, " ")
      .slice(0, 60),
    ring: style.outlineStyle !== "none" && parseFloat(style.outlineWidth) >= 2,
  };
}

// The key that moves to the next control. Safari, by default, stops
// on text fields only when Tab is pressed, and on every control when
// Option+Tab is (or when "Press Tab to highlight each item" is on in
// its settings). WebKit here works the same way, so under WebKit the
// tests press Option+Tab, as a keyboard user on a Mac does.
function nextKey(page) {
  return page.context().browser().browserType().name() === "webkit"
    ? "Alt+Tab"
    : "Tab";
}

async function walkWithTab(page, { maxPresses = 250 } = {}) {
  const key = nextKey(page);
  const stops = [];
  for (let i = 0; i < maxPresses; i++) {
    await page.keyboard.press(key);
    const stop = await page.evaluate(readFocus, i);
    if (stop.seenBefore) return stops;
    if (!stop.none) stops.push(stop);
  }
  throw new Error(
    `the focus did not come back to the first stop in ${maxPresses} presses of Tab`,
  );
}

// Elements a mouse user can click that the walk did not reach: shown,
// not disabled, with a pointer cursor, inside `scope`, and neither
// marked themselves nor holding or held by a marked element. The
// pointer cursor is how this app shows that something takes a click
// (a name cell, a calendar entry), so it finds a clickable element
// that is not a button or a link, which a list of tag names would not.
async function missedByTab(page, scope = "body") {
  return page.evaluate((scopeSelector) => {
    const root = window.document.querySelector(scopeSelector);
    const missed = [];
    for (const el of root.querySelectorAll("*")) {
      if (!el.checkVisibility({ visibilityProperty: true })) continue;
      if (el.closest("[disabled], [aria-hidden='true'], [inert]")) continue;
      if (window.getComputedStyle(el).cursor !== "pointer") continue;
      if (el.closest("[data-tab-stop]")) continue;
      if (el.querySelector("[data-tab-stop]")) continue;
      // A label works through its control: it is reached when its
      // control is.
      const control = el.tagName === "LABEL" ? el.control : el;
      if (control && control.hasAttribute("data-tab-stop")) continue;
      // Tab stops on one radio button of a group; the arrow keys move
      // to the others. So a radio button is reached when one of its
      // group is.
      if (control && control.type === "radio" && control.name) {
        const group = window.document.querySelectorAll(
          `input[type="radio"][name="${window.CSS.escape(control.name)}"]`,
        );
        if ([...group].some((r) => r.hasAttribute("data-tab-stop"))) {
          continue;
        }
      }
      // Only the outermost of a clickable group is reported.
      const parent = el.parentElement;
      if (parent && window.getComputedStyle(parent).cursor === "pointer")
        continue;
      missed.push(
        el.tagName.toLowerCase() +
          (el.id ? "#" + el.id : "") +
          (el.getAttribute("aria-label")
            ? `[aria-label="${el.getAttribute("aria-label")}"]`
            : "") +
          (el.className && typeof el.className === "string"
            ? "." + el.className.trim().split(/\s+/).join(".")
            : "") +
          ` "${el.textContent.trim().slice(0, 40)}"`,
      );
    }
    return missed;
  }, scope);
}

// Layout faults that large text causes, inside `scope`: two controls
// drawn on top of each other (a tap meant for one hits the other), and
// text that a box with hidden overflow cuts off. A select is left out:
// it shows one option and hides the rest on purpose. So is text hidden
// for everyone but a screen reader (.visually-hidden).
async function layoutProblems(page, scope = "body") {
  return page.evaluate((scopeSelector) => {
    const root = window.document.querySelector(scopeSelector);
    const shown = (el) =>
      el.checkVisibility({ visibilityProperty: true }) &&
      !el.closest(".visually-hidden, [aria-hidden='true'], [inert]");
    const name = (el) =>
      (el.getAttribute("aria-label") || el.textContent || el.tagName)
        .trim()
        .replace(/\s+/g, " ")
        .slice(0, 40);

    const controls = [
      ...root.querySelectorAll(
        "button, a[href], input, select, textarea, [role='button']",
      ),
    ]
      .filter(shown)
      .map((el) => [el, el.getBoundingClientRect()])
      .filter(([, r]) => r.width > 0 && r.height > 0);
    const overlaps = [];
    for (let i = 0; i < controls.length; i++) {
      for (let j = i + 1; j < controls.length; j++) {
        const [a, ra] = controls[i];
        const [b, rb] = controls[j];
        if (a.contains(b) || b.contains(a)) continue;
        // A label's control sits inside or beside it; a switch draws
        // its input under its own button.
        if (a.closest("label") && a.closest("label") === b.closest("label"))
          continue;
        const w = Math.min(ra.right, rb.right) - Math.max(ra.left, rb.left);
        const h = Math.min(ra.bottom, rb.bottom) - Math.max(ra.top, rb.top);
        if (w > 1 && h > 1) {
          overlaps.push(`"${name(a)}" overlaps "${name(b)}"`);
        }
      }
    }

    const cut = [];
    for (const el of root.querySelectorAll("*")) {
      if (el.tagName === "SELECT" || el.closest("select")) continue;
      if (!shown(el) || !el.textContent.trim()) continue;
      const style = window.getComputedStyle(el);
      const hides = (v) => v === "hidden" || v === "clip";
      if (
        (hides(style.overflowX) && el.scrollWidth > el.clientWidth + 1) ||
        (hides(style.overflowY) && el.scrollHeight > el.clientHeight + 1)
      ) {
        cut.push(`text cut off: "${name(el)}"`);
      }
    }
    return [...overlaps, ...cut];
  }, scope);
}

module.exports = {
  layoutProblems,
  expectAccessible,
  nextKey,
  stopTransitions,
  walkWithTab,
  missedByTab,
};
