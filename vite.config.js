import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import fs from "node:fs";
import path from "node:path";
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

export default defineConfig(({ command }) => ({
  root: "app/frontend",
  envDir: "../..",
  // Only serve public/ files during dev; in build/preview, outDir IS public/
  publicDir: command === "serve" ? "../../public" : false,
  plugins: [react(), perfLogPlugin()],
  server: {
    port: 3036,
    proxy: {
      "/api": "http://localhost:3000",
    },
  },
  build: {
    outDir: "../../public",
    emptyOutDir: false,
    manifest: true,
    chunkSizeWarningLimit: 700,
  },
}));
