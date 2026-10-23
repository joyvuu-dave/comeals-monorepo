import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { describe, expect, it } from "vitest";
import stripOldJsxPropsPlugin, {
  UNCONTROLLABLE_FILE,
  UNCONTROLLABLE_VERSION,
  stripOldJsxProps,
} from "../../app/frontend/strip_old_jsx_props.mjs";

const require = createRequire(import.meta.url);
const root = path.dirname(require.resolve("uncontrollable/package.json"));
const installedVersion = JSON.parse(
  fs.readFileSync(path.join(root, "package.json"), "utf8"),
).version;
const esmFile = path.join(root, "lib/esm/uncontrollable.js");

describe("stripOldJsxProps (#28)", () => {
  it("is still needed: the installed uncontrollable is the one with the old JSX transform", () => {
    // When this fails, the upstream fix has shipped. Delete
    // app/frontend/strip_old_jsx_props.mjs, its line in vite.config.mjs,
    // and this test, then check that the dev server prints no
    // "outdated JSX transform" warning.
    expect(installedVersion).toBe(UNCONTROLLABLE_VERSION);
  });

  it("removes __source and __self from the installed file and nothing else", () => {
    const before = fs.readFileSync(esmFile, "utf8");
    expect(before).toContain("__self: this");

    const after = stripOldJsxProps(before);

    expect(after).not.toContain("__self");
    expect(after).not.toContain("__source");
    expect(after).toContain("innerRef: ref");
    expect(before.length - after.length).toBeLessThan(200);
  });

  it("matches only uncontrollable's ESM file", () => {
    expect(UNCONTROLLABLE_FILE.test(esmFile)).toBe(true);
    expect(
      UNCONTROLLABLE_FILE.test(path.join(root, "lib/cjs/uncontrollable.js")),
    ).toBe(false);
    expect(UNCONTROLLABLE_FILE.test("/app/node_modules/react/index.js")).toBe(
      false,
    );
  });

  it("changes the matching file in the plugin and leaves every other file alone", () => {
    const plugin = stripOldJsxPropsPlugin();
    const code = fs.readFileSync(esmFile, "utf8");

    expect(plugin.transform(code, esmFile).code).toBe(stripOldJsxProps(code));
    expect(plugin.transform(code, "/app/src/calendar.jsx")).toBeNull();
  });
});
