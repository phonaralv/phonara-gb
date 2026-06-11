/// <reference lib="webworker" />

export {};

type PrecacheEntry = { url: string; revision: string | null };
type PushPayload = {
  title?: string;
  body?: string;
  url?: string;
  tag?: string;
};

declare global {
  interface Window {
    __WB_MANIFEST: PrecacheEntry[];
  }
}

const sw = globalThis as unknown as ServiceWorkerGlobalScope & {
  __WB_MANIFEST: PrecacheEntry[];
};

const PRECACHE = 'phonara-precache-v1';
const RUNTIME_PAGES = 'phonara-pages-v1';
const OFFLINE_URL = '/offline.html';
const API_PATHS = ['/rest/v1', '/auth/v1', '/realtime/v1', '/storage/v1'];

function isSupabaseApi(url: URL): boolean {
  return API_PATHS.some((path) => url.pathname.startsWith(path));
}

function precacheUrls(): string[] {
  const urls = new Set(self.__WB_MANIFEST.map((entry) => entry.url));
  urls.add(OFFLINE_URL);
  return [...urls];
}

sw.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(PRECACHE)
      .then((cache) => cache.addAll(precacheUrls()))
      .then(() => sw.skipWaiting()),
  );
});

sw.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys
          .filter((key) => key !== PRECACHE && key !== RUNTIME_PAGES)
          .map((key) => caches.delete(key)),
      ))
      .then(() => sw.clients.claim()),
  );
});

sw.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (event.request.mode !== 'navigate' || isSupabaseApi(url)) return;

  event.respondWith(
    fetch(event.request)
      .then((response) => {
        const copy = response.clone();
        void caches.open(RUNTIME_PAGES).then((cache) => cache.put(event.request, copy));
        return response;
      })
      .catch(async () => {
        const cached = await caches.match(event.request);
        return cached ?? await caches.match(OFFLINE_URL) ?? Response.error();
      }),
  );
});

sw.addEventListener('push', (event) => {
  let payload: PushPayload;
  try {
    payload = event.data?.json() as PushPayload ?? {};
  } catch {
    payload = { body: event.data?.text() };
  }

  const title = payload.title ?? 'PHONARA';
  const url = payload.url ?? '/trade';
  event.waitUntil(
    sw.registration.showNotification(title, {
      body: payload.body,
      tag: payload.tag ?? url,
      icon: '/pwa-192x192.png',
      badge: '/pwa-64x64.png',
      data: { url },
    }),
  );
});

sw.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const targetUrl = new URL(String((event.notification.data as { url?: string } | undefined)?.url ?? '/'), sw.location.origin);

  event.waitUntil(
    sw.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(async (clients) => {
      for (const client of clients) {
        if ('focus' in client && new URL(client.url).pathname === targetUrl.pathname) {
          return client.focus();
        }
      }
      return sw.clients.openWindow(targetUrl.href);
    }),
  );
});
