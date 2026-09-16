import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";

const rolldownRuntimeModuleId = "\0rolldown/runtime.js";

export default defineConfig({
  base: "/assets/",
  plugins: [react()],
  define: {
    "process.env.NODE_ENV": JSON.stringify("production"),
  },
  build: {
    emptyOutDir: true,
    assetsDir: ".",
    outDir: "../assets",
    manifest: true,
    rollupOptions: {
      input: {
        app_styles: resolve(__dirname, "src/app.css"),
        "app-shell": resolve(__dirname, "src/app-shell.ts"),
        "repo-clone": resolve(__dirname, "src/repo-clone.ts"),
        "custom-elements": resolve(__dirname, "src/custom-elements.tsx"),
      },
      output: {
        entryFileNames: "[name]-[hash].mjs",
        chunkFileNames: "[name]-[hash].mjs",
        assetFileNames: "[name]-[hash][extname]",
        manualChunks(id) {
          // Keep Rolldown's CommonJS helpers out of the app entry. Shiki
          // language chunks import those helpers, so placing them in the entry
          // makes language filenames change whenever custom-elements changes.
          if (id === rolldownRuntimeModuleId) {
            return "rolldown-runtime";
          }
        },
      },
    },
  },
});
