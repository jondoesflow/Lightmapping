// Offline support: cache the app shell, serve it network-first so updates arrive promptly.
const CACHE = 'lightmapping-v1';
const SHELL = [
  '/', '/index.html', '/receive.html', '/about.html', '/styles.css', '/manifest.json', '/icon-192.png', '/icon-512.png',
  '/js/app.js', '/js/ui.js', '/js/engine.js', '/js/renderer.js', '/js/shaders.js', '/js/geometry.js', '/js/model.js',
  '/js/presets.js', '/js/media.js', '/js/storage.js', '/js/audio.js', '/js/vision.js', '/js/stage.js', '/js/panels.js',
  '/js/export.js', '/js/link.js', '/js/receive.js',
];

self.addEventListener('install', (e) => { e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL))); self.skipWaiting(); });
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))));
  self.clients.claim();
});
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;
  e.respondWith(fetch(e.request).then((res) => {
    const copy = res.clone();
    caches.open(CACHE).then((c) => c.put(e.request, copy));
    return res;
  }).catch(() => caches.match(e.request).then((r) => r || caches.match('/index.html'))));
});
