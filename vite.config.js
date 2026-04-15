import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig(({ command }) => ({
  root: "app/frontend",
  envDir: "../..",
  // Only serve public/ files during dev; in build/preview, outDir IS public/
  publicDir: command === "serve" ? "../../public" : false,
  plugins: [react()],
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
