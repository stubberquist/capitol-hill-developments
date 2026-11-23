// Minimal service worker: network-first for pages so data stays live,
// with a cached fallback so the shell still opens offline.
const CACHE = "chd-shell-v2";   // v2: v1 kept a full page copy per distinct URL (see fetch below)
const SHELL = ["./index.html", "./manifest.webmanifest"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", e => {
  if (e.request.mode !== "navigate") return;  // let API/tile/CDN requests pass through untouched
  e.respondWith(
    fetch(e.request)
      .then(res => {
        // One copy, under one key. Keyed by the request, every shared link and filter change
        // (?nb=…, ?search=…) stored another ~460 KB page forever; and an error page must not
        // replace the good copy the offline fallback depends on.
        // Only the app page itself: whats-new.html is a navigation too.
        if (res.ok && !res.redirected && /\/(index\.html)?$/.test(new URL(e.request.url).pathname)) {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put("./index.html", copy));
        }
        return res;
      })
      .catch(() => caches.match("./index.html"))
  );
});
