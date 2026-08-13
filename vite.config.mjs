import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import fs from "node:fs";
import path from "node:path";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Dev-only perf logger. The frontend POSTs timing entries to /__perf/log
// and this middleware appends them (one JSON object per line) to
// log/perf.log so they can be read after the fact without copying from
// the browser console. Only registered during `vite dev`.
function perfLogPlugin() {
  const logPath = path.resolve(__dirname, "log/perf.log");
  return {
    name: "perf-log",
    configureServer(server) {
      server.middlewares.use("/__perf/log", (req, res) => {
        if (req.method !== "POST") {
          res.statusCode = 405;
          res.end();
          return;
        }
        let body = "";
        req.on("data", (chunk) => {
          body += chunk;
        });
        req.on("end", () => {
          try {
            fs.appendFileSync(logPath, body + "\n");
            res.statusCode = 204;
          } catch {
            res.statusCode = 500;
          }
          res.end();
        });
      });
    },
  };
}

// Adds <link rel="modulepreload"> for the calendar chunk to the built
// index.html. The calendar is lazy-loaded (React.lazy), so without this
// its download only starts after the main bundle has run — a serial
// chain that delays the month heading, the page's largest paint. The
// preload lets the browser fetch it in parallel with the main bundle.
// Only the calendar chunk: it is the page almost every visit lands on.
// Its own imports are chunks the entry already loads.
function preloadCalendarPlugin() {
  return {
    name: "preload-calendar",
    transformIndexHtml: {
      order: "post",
      handler(html, ctx) {
        if (!ctx.bundle) return; // dev server: nothing to preload
        const chunk = Object.values(ctx.bundle).find(
          (c) =>
            c.facadeModuleId && c.facadeModuleId.endsWith("calendar/show.jsx"),
        );
        if (!chunk) return;
        // The chunk cannot execute until its static imports are also
        // loaded, so preload those too — minus the ones the entry
        // already loads (Vite emits its own modulepreloads for them).
        const entry = Object.values(ctx.bundle).find((c) => c.isEntry);
        const covered = new Set([entry.fileName, ...(entry.imports || [])]);
        const files = [chunk.fileName, ...(chunk.imports || [])].filter(
          (f) => !covered.has(f),
        );
        return files.map((f) => ({
          tag: "link",
          attrs: { rel: "modulepreload", href: "/" + f },
          injectTo: "head",
        }));
      },
    },
  };
}

// One id per production build, baked into the bundle as __BUILD_ID__.
// index.jsx compares it to localStorage and clears the IndexedDB
// caches when it changes, so cached payloads never outlive the deploy
// that wrote them (the same policy bin/deploy applies to the server
// cache). Heroku builds have no .git directory but set SOURCE_VERSION
// to the commit SHA; local builds ask git. The dev server uses a
// fixed id so restarts don't clear the caches for nothing.
function buildId(command) {
  if (command === "serve") return "dev";
  if (process.env.SOURCE_VERSION) return process.env.SOURCE_VERSION;
  try {
    return execSync("git rev-parse HEAD", { cwd: __dirname })
      .toString()
      .trim();
  } catch {
    // No git and no SOURCE_VERSION: fall back to the build time, so
    // the id still changes with every build instead of sticking.
    return `t${Date.now()}`;
  }
}

export default defineConfig(({ command }) => ({
  root: "app/frontend",
  define: {
    __BUILD_ID__: JSON.stringify(buildId(command)),
  },
  envDir: "../..",
  // Only serve public/ files during dev; in build/preview, outDir IS public/
  publicDir: command === "serve" ? "../../public" : false,
  plugins: [react(), perfLogPlugin(), preloadCalendarPlugin()],
  server: {
    port: 3036,
    proxy: {
      "/api": "http://localhost:3000",
    },
  },
  build: {
    outDir: "../../public",
    emptyOutDir: false,
    // NOT the default "assets": Sprockets writes ActiveAdmin's files to
    // public/assets, and Vite deletes everything inside its own assets
    // directory on each build even with emptyOutDir false. Sharing the
    // directory meant every Vite build silently broke the admin styles
    // until the next `rake assets:precompile`. Separate directories,
    // no collision. AssetCacheControl covers both.
    assetsDir: "vite-assets",
    // Ship source maps: production stack traces then point at real
    // source lines instead of minified positions. Browsers fetch .map
    // files only when DevTools is open, so users never download them,
    // and the repo is public so there is nothing to hide.
    sourcemap: true,
    manifest: true,
    chunkSizeWarningLimit: 700,
  },
}));
