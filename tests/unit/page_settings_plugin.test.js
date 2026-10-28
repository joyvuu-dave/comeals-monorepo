import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import {
  PAGE_SETTINGS,
  pageSettingTags,
} from "../../app/frontend/page_settings.mjs";

// Vite writes the tags for the pages it sends (vite dev, vite preview),
// and Rails writes them for the pages it sends. Both must use the same
// names, or one of them writes a key the app never reads.
describe("the page settings Vite writes", () => {
  it("writes one tag for each VITE_ variable, empty when it is not set", () => {
    const tags = pageSettingTags({ VITE_PUSHER_KEY: "dev-key" });

    expect(tags).toEqual([
      {
        tag: "meta",
        attrs: { name: "comeals-pusher-key", content: "dev-key" },
        injectTo: "head",
      },
      {
        tag: "meta",
        attrs: { name: "comeals-pusher-cluster", content: "" },
        injectTo: "head",
      },
      {
        tag: "meta",
        attrs: { name: "comeals-bugsnag-api-key", content: "" },
        injectTo: "head",
      },
    ]);
  });

  it("uses the names Rails writes", () => {
    const rails = fs.readFileSync(
      path.resolve(__dirname, "../../app/services/page_settings.rb"),
      "utf8",
    );
    const railsNames = [...rails.matchAll(/'(comeals-[a-z-]+)' =>/g)].map(
      (match) => match[1],
    );

    expect(railsNames).toEqual(Object.keys(PAGE_SETTINGS));
  });
});
