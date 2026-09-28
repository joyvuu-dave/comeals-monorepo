import { describe, it, expect, afterEach } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  markupRanges,
  isMarkupBranch,
  neverLoaded,
} from "../helpers/visual_coverage_report.js";

// The screen-state measure (bin/visual-coverage) counts only the
// branches that choose what is drawn. These tests pin which branches
// those are, and that a component no visual test loads is not left out
// of the count without a word.

// The place of `marker` in `source`, the way Babel and istanbul give it:
// lines from 1, columns from 0.
function locationOf(source, marker) {
  const before = source.slice(0, source.indexOf(marker));
  if (before.length === source.length) throw new Error(`no ${marker}`);
  const lines = before.split("\n");
  return {
    start: { line: lines.length, column: lines[lines.length - 1].length },
  };
}

function counts(source, marker) {
  return isMarkupBranch(locationOf(source, marker), markupRanges(source));
}

const COMPONENT = `
function Rows({ rows, open, onPick }) {
  if (!rows) return null;
  const label = open ? "Open" : "Closed";
  return (
    <ul className={open ? "open" : "closed"} onClick={() => (open ? onPick(1) : onPick(2))}>
      {open && <li>{label}</li>}
      {rows.map((row) =>
        row.done ? <li key={row.id}><s>{row.name}</s></li> : <li key={row.id}>{row.name}</li>,
      )}
      <li ref={function (el) { return el ? el.focus() : null; }} />
    </ul>
  );
}
`;

describe("which branches are looks", () => {
  it("counts a branch written in the markup", () => {
    expect(counts(COMPONENT, "open && <li>")).toBe(true);
  });

  it("counts a branch in an attribute that is not a function", () => {
    expect(counts(COMPONENT, 'open ? "open"')).toBe(true);
  });

  it("counts a branch inside a function that draws rows for the markup", () => {
    expect(counts(COMPONENT, "row.done ?")).toBe(true);
  });

  it("leaves out a branch inside a handler written as an attribute's value", () => {
    expect(counts(COMPONENT, "open ? onPick(1)")).toBe(false);
    expect(counts(COMPONENT, "el ? el.focus()")).toBe(false);
  });

  it("leaves out a branch outside the markup", () => {
    expect(counts(COMPONENT, "!rows")).toBe(false);
    expect(counts(COMPONENT, 'open ? "Open"')).toBe(false);
  });
});

describe("a component no visual test loads", () => {
  let dir;

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  function write(name, source) {
    const file = path.join(dir, name);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, source);
    return file;
  }

  it("is named when it has markup, and a file with no markup is not", () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "visual-coverage-"));
    const loaded = write("a/loaded.jsx", "export default () => <p>{1}</p>;");
    const unloaded = write(
      "b/unloaded.tsx",
      "export default (p: { x: boolean }) => <p>{p.x && 'x'}</p>;",
    );
    write("b/helper.js", "export const payload = (x) => ({ x });");
    write("b/notes.md", "<p>{not code}</p>");

    expect(neverLoaded([loaded], dir)).toEqual([unloaded]);
    expect(neverLoaded([loaded, unloaded], dir)).toEqual([]);
  });
});
