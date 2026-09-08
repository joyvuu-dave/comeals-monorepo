// A Vite plugin that puts istanbul counters into the SPA's own source,
// for the screen-state measure (bin/visual-coverage). It runs before
// every other transform, on the original .js/.jsx/.ts/.tsx text, so the
// positions in the counters are the lines a person reads in the editor.
// (vite-plugin-istanbul instruments the compiled output instead, and
// its line numbers came out shifted.) The counters live in
// window.__coverage__, where tests/helpers/test.js reads them.
import path from "node:path";
import { createInstrumenter } from "istanbul-lib-instrument";

export default function istanbulSource({ include }) {
  const root = path.resolve(include) + path.sep;
  const instrumenter = createInstrumenter({
    esModules: true,
    coverageGlobalScope: "window",
    coverageGlobalScopeFunc: false,
    produceSourceMap: true,
    parserPlugins: ["jsx", "typescript", "importAttributes"],
  });
  return {
    name: "comeals:istanbul-source",
    enforce: "pre",
    transform(code, id) {
      const file = id.split("?")[0];
      if (!file.startsWith(root)) return null;
      if (!/\.(js|jsx|ts|tsx)$/.test(file)) return null;
      return {
        code: instrumenter.instrumentSync(code, file),
        map: instrumenter.lastSourceMap(),
      };
    },
  };
}
