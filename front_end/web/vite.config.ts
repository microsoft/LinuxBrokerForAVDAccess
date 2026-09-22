/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

// The bundle is served by Flask out of front_end/static/dist, so `base` has to match
// the URL Flask exposes that folder under. Nothing is fetched from a CDN: every asset
// ships inside the container, which is what keeps the portal usable in Azure
// Government, sovereign and air-gapped environments.
export default defineConfig({
  base: '/static/dist/',
  plugins: [react(), tailwindcss()],
  build: {
    outDir: '../static/dist',
    emptyOutDir: true,
    sourcemap: false,
  },
  server: {
    port: 5173,
    // `npm run dev` serves the SPA while Flask keeps handling the auth redirects and
    // the BFF, so the sign-in flow behaves the same way it does in production.
    proxy: Object.fromEntries(
      ['/api/ui', '/login', '/getAToken', '/logout', '/health'].map((path) => [
        path,
        { target: 'http://127.0.0.1:5000', changeOrigin: false },
      ]),
    ),
  },
  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    css: false,
    include: ['src/**/*.test.{ts,tsx}'],
  },
});
