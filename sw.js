/* =============================================================================
 * Bosithon — service worker
 * Makes repeat visits and back-navigation feel instant by caching assets.
 *
 * Strategy:
 *  - Heavy / version-pinned third-party assets (forest video, Three.js,
 *    Supabase lib, Google Fonts): CACHE-FIRST (served from disk, no re-download).
 *  - Your own HTML / CSS / JS: NETWORK-FIRST (so edits show up immediately),
 *    falling back to cache when offline.
 *  - API calls (Supabase REST, Turnstile) are never cached as the source of truth.
 *
 * Bump CACHE_VERSION whenever you want to force-clear old caches.
 * ========================================================================== */
const CACHE_VERSION = "bosithon-v14-scroll-slower";
const PRECACHE = ["./forest-loop.mp4"]; // big shared asset used on every page

self.addEventListener("install", (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) => cache.addAll(PRECACHE).catch(() => {}))
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(keys.filter((k) => k !== CACHE_VERSION).map((k) => caches.delete(k)))
      )
      .then(() => self.clients.claim())
  );
});

function isHeavyStatic(url) {
  return (
    /forest-loop[^/]*\.mp4(\?|$)/.test(url) ||
    url.indexOf("unpkg.com/three") !== -1 ||
    url.indexOf("fonts.gstatic.com") !== -1 ||
    url.indexOf("fonts.googleapis.com") !== -1 ||
    url.indexOf("cdn.jsdelivr.net/npm/@supabase") !== -1
  );
}

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return; // never touch POSTs (submit, RPC, etc.)
  const url = req.url;

  // Cache-first for heavy, rarely-changing third-party assets.
  if (isHeavyStatic(url)) {
    event.respondWith(
      caches.match(req).then(
        (hit) =>
          hit ||
          fetch(req).then((res) => {
            if (res && (res.ok || res.type === "opaque")) {
              const copy = res.clone();
              caches.open(CACHE_VERSION).then((c) => c.put(req, copy));
            }
            return res;
          })
      )
    );
    return;
  }

  // Network-first for everything else; cache same-origin successes for offline.
  event.respondWith(
    fetch(req)
      .then((res) => {
        try {
          if (res && res.ok && new URL(url).origin === self.location.origin) {
            const copy = res.clone();
            caches.open(CACHE_VERSION).then((c) => c.put(req, copy));
          }
        } catch (e) {}
        return res;
      })
      .catch(() => caches.match(req))
  );
});
