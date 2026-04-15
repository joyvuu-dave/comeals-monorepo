import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  root: "app/frontend",
  plugins: [react()],
  server: {
    port: 3036,
    proxy: {
      "/api": "http://localhost:3000",
      "/admin": "http://localhost:3000",
      "/assets": "http://localhost:3000",
      "/letter_opener": "http://localhost:3000",
    },
  },
  build: {
    outDir: "../../public",
    emptyOutDir: false,
    manifest: true,
    chunkSizeWarningLimit: 700,
  },
});
