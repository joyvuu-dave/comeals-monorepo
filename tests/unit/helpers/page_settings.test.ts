import { describe, expect, it } from "vitest";
import { pageSetting } from "../../../app/frontend/src/helpers/page_settings";
import { setPageSetting } from "./page_settings_for_tests.js";

describe("pageSetting", () => {
  it("reads the key the page carries", () => {
    setPageSetting("comeals-pusher-key", "the-key");

    expect(pageSetting("comeals-pusher-key")).toBe("the-key");
  });

  // A page Rails sent where the server sends nothing on Pusher, or a
  // page with no tag at all: no key either way.
  it("reads an empty tag and a missing tag as no key", () => {
    setPageSetting("comeals-pusher-key", "");

    expect(pageSetting("comeals-pusher-key")).toBe("");
    expect(pageSetting("comeals-bugsnag-api-key")).toBe("");
  });
});
