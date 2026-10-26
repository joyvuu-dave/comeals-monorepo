import { describe, it, expect } from "vitest";
import { launchOptions } from "../smoke/browser.js";

// Which browser the post-deploy smoke test starts (tests/smoke/browser.js).
describe("launchOptions", () => {
  // A laptop: Playwright's own Chromium, which bin/deploy installs.
  it("starts Playwright's Chromium when no channel is set", () => {
    expect(launchOptions({})).toEqual({});
    expect(launchOptions({ SMOKE_BROWSER_CHANNEL: "" })).toEqual({});
  });

  // The Deploy and Rollback workflows: the runner's own Google Chrome.
  it("starts the browser of the channel it is given", () => {
    expect(launchOptions({ SMOKE_BROWSER_CHANNEL: "chrome" })).toEqual({
      channel: "chrome",
    });
  });
});
