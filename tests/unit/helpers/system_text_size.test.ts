import { describe, it, expect, afterEach, vi } from "vitest";
import {
  rootFontSize,
  followSystemTextSize,
} from "../../../app/frontend/src/helpers/system_text_size";

// What -apple-system-body gives in the iPhone simulator, by setting.
const SMALLEST = 14;
const DEFAULT = 17;
const ACCESSIBILITY_MEDIUM = 28;
const LARGEST = 53;

describe("rootFontSize", () => {
  it("is 16px at the iPhone's default setting, the same as with no setting", () => {
    expect(rootFontSize(DEFAULT)).toBe(16);
  });

  it("grows and shrinks with the setting", () => {
    expect(rootFontSize(SMALLEST)).toBeCloseTo(13.18, 2);
    expect(rootFontSize(ACCESSIBILITY_MEDIUM)).toBeCloseTo(26.35, 2);
  });

  it("stops at 200%", () => {
    expect(rootFontSize(LARGEST)).toBe(32);
  });
});

describe("followSystemTextSize", () => {
  let stop = () => {};

  afterEach(() => {
    stop();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  // jsdom knows no -apple-system-body, so the probe's size is what
  // getComputedStyle is made to answer here: the value of systemPx.
  let systemPx = DEFAULT;
  const realGetComputedStyle = window.getComputedStyle;
  function systemSize(px: number) {
    systemPx = px;
    if (vi.isMockFunction(window.getComputedStyle)) return;
    vi.spyOn(window, "getComputedStyle").mockImplementation((el) => {
      const style = realGetComputedStyle(el);
      if (el.classList.contains("system-text-size-probe")) {
        return { ...style, fontSize: `${systemPx}px` } as CSSStyleDeclaration;
      }
      return style;
    });
  }

  function onIOS(yes: boolean) {
    vi.stubGlobal("CSS", {
      supports: (property: string) =>
        yes && property === "-webkit-touch-callout",
    });
  }

  const root = () => document.documentElement.style.fontSize;

  it("does nothing outside iOS", () => {
    onIOS(false);
    systemSize(13);
    stop = followSystemTextSize();
    expect(root()).toBe("");
    expect(document.body.children).toHaveLength(0);
  });

  it("does nothing where CSS.supports is missing", () => {
    vi.stubGlobal("CSS", undefined);
    stop = followSystemTextSize();
    expect(root()).toBe("");
  });

  it("sets the root's size from the setting, and again when the page shows after the setting changed", () => {
    onIOS(true);
    systemSize(DEFAULT);
    stop = followSystemTextSize();
    expect(root()).toBe("16px");

    systemSize(LARGEST);
    document.dispatchEvent(new Event("visibilitychange"));
    expect(root()).toBe("32px");
  });

  it("keeps the stylesheet's size when the probe has no size", () => {
    onIOS(true);
    systemSize(0);
    stop = followSystemTextSize();
    expect(root()).toBe("");
  });

  it("takes everything back when stopped", () => {
    onIOS(true);
    systemSize(LARGEST);
    stop = followSystemTextSize();
    stop();
    stop = () => {};
    expect(root()).toBe("");
    expect(document.body.children).toHaveLength(0);

    systemSize(DEFAULT);
    document.dispatchEvent(new Event("visibilitychange"));
    expect(root()).toBe("");
  });

  it("hides the probe from screen readers", () => {
    onIOS(true);
    systemSize(DEFAULT);
    stop = followSystemTextSize();
    expect(document.body.lastElementChild?.getAttribute("aria-hidden")).toBe(
      "true",
    );
  });
});
