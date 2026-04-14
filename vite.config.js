import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  root: "app/frontend",
  plugins: [react()],
  server: {
    port: 3036,
    proxy: {
      "/api": { target: "http://localhost:3000", changeOrigin: true },
      "/admin": { target: "http://localhost:3000", changeOrigin: true },
    },
  },
  build: {
    outDir: "../../public",
    emptyOutDir: false,
    manifest: true,
    chunkSizeWarningLimit: 700,
  },
});
