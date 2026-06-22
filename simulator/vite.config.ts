import { defineConfig } from "vite";

// Vanilla TS single-page app. No framework plugins by design — the client is
// dependency-light so it stays close to what the real Swift watch app does.
export default defineConfig({
  server: {
    port: 5273,
    host: true,
  },
  build: {
    target: "esnext",
    sourcemap: true,
  },
});
