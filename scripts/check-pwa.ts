import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const root = process.cwd();

function assert(condition: unknown, message: string): void {
  if (!condition) {
    throw new Error(message);
  }
}

function read(path: string): string {
  return readFileSync(join(root, path), 'utf8');
}

const publicAssets = [
  'apps/web/public/favicon.ico',
  'apps/web/public/phonara-icon.svg',
  'apps/web/public/apple-touch-icon-180x180.png',
  'apps/web/public/pwa-64x64.png',
  'apps/web/public/pwa-192x192.png',
  'apps/web/public/pwa-512x512.png',
  'apps/web/public/maskable-icon-512x512.png',
  'apps/web/public/offline.html',
];

for (const asset of publicAssets) {
  assert(existsSync(join(root, asset)), `missing PWA asset: ${asset}`);
}

const indexHtml = read('apps/web/index.html');
assert(indexHtml.includes('viewport-fit=cover'), 'index.html must preserve viewport-fit=cover');
assert(indexHtml.includes('mobile-web-app-capable'), 'index.html missing mobile install metadata');
assert(indexHtml.includes('apple-touch-icon'), 'index.html missing Apple touch icon');
assert(indexHtml.includes('rel="manifest"'), 'index.html missing manifest link');

const offlineHtml = read('apps/web/public/offline.html');
assert(offlineHtml.includes('viewport-fit=cover'), 'offline.html must be safe-area aware');
assert(offlineHtml.includes('phonara.locale'), 'offline.html must resolve the stored app locale');
assert(!/\s(?:src|href)=["']https?:\/\//.test(offlineHtml), 'offline.html must not depend on remote assets');

const viteConfig = read('apps/web/vite.config.ts');
assert(viteConfig.includes("strategies: 'injectManifest'"), 'PWA must use injectManifest for the custom service worker');
assert(viteConfig.includes("filename: 'sw.ts'"), 'PWA must build the custom service worker');

const serviceWorker = read('apps/web/src/sw.ts');
assert(serviceWorker.includes("const OFFLINE_URL = '/offline.html'"), 'service worker must preserve offline.html fallback');
assert(serviceWorker.includes('isSupabaseApi'), 'service worker must denylist Supabase API paths from navigation fallback');
assert(serviceWorker.includes("addEventListener('push'"), 'service worker must scaffold push handling');
assert(serviceWorker.includes("addEventListener('notificationclick'"), 'service worker must handle notification clicks');

const manifestPath = join(root, 'apps/web/dist/manifest.webmanifest');
assert(existsSync(manifestPath), 'apps/web/dist/manifest.webmanifest missing; run bun run build first');
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
  name?: string;
  short_name?: string;
  display?: string;
  start_url?: string;
  icons?: Array<{ src?: string; sizes?: string; purpose?: string }>;
};

assert(manifest.name === 'PHONARA', 'manifest name must be PHONARA');
assert(manifest.short_name === 'PHONARA', 'manifest short_name must be PHONARA');
assert(manifest.display === 'standalone', 'manifest display must be standalone');
assert(manifest.start_url === '/', 'manifest start_url must be /');
assert(manifest.icons?.some((icon) => icon.sizes === '192x192'), 'manifest missing 192x192 icon');
assert(manifest.icons?.some((icon) => icon.sizes === '512x512'), 'manifest missing 512x512 icon');
assert(manifest.icons?.some((icon) => icon.purpose === 'maskable'), 'manifest missing maskable icon');

for (const builtAsset of ['apps/web/dist/sw.js', 'apps/web/dist/offline.html', 'apps/web/dist/registerSW.js']) {
  assert(existsSync(join(root, builtAsset)), `missing built PWA asset: ${builtAsset}`);
}

process.stdout.write('check:pwa OK - manifest, offline fallback, safe-area, and service worker assets verified\n');
