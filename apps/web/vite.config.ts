import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import { VitePWA } from 'vite-plugin-pwa';

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    VitePWA({
      strategies: 'injectManifest',
      srcDir: 'src',
      filename: 'sw.ts',
      registerType: 'autoUpdate',
      includeAssets: ['favicon.ico', 'phonara-icon.svg', 'apple-touch-icon-180x180.png'],
      manifest: {
        name: 'PHONARA',
        short_name: 'PHONARA',
        description: 'PHON-powered crypto trading & rewards platform',
        theme_color: '#0b0b0f',
        background_color: '#0b0b0f',
        display: 'standalone',
        orientation: 'portrait',
        start_url: '/',
        scope: '/',
        lang: 'ko',
        icons: [
          { src: 'pwa-64x64.png', sizes: '64x64', type: 'image/png' },
          { src: 'pwa-192x192.png', sizes: '192x192', type: 'image/png' },
          { src: 'pwa-512x512.png', sizes: '512x512', type: 'image/png' },
          { src: 'maskable-icon-512x512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
        ],
      },
      injectManifest: {
        // App shell assets: cache-first, long TTL. The custom service worker
        // keeps the /offline.html navigateFallback and Supabase API denylist.
        globPatterns: ['**/*.{js,css,html,ico,png,svg,woff2}'],
      },
      devOptions: {
        enabled: false,
      },
    }),
  ],
  // Env files live at the monorepo root (.env.local etc.), not in apps/web.
  // `envDir` is resolved relative to the project root (this directory), so '../..'
  // points at the repo root. Without this, vite loads no env and the app boots
  // with an undefined Supabase config. Kept as a relative string (no node: imports)
  // so the web typecheck project doesn't need @types/node.
  envDir: '../..',
  server: {
    port: 3000,
  },
});
