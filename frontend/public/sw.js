/*
 * The service worker: installable, and honest when the server is down.
 *
 * It caches nothing of the game. Every request goes to the network as if
 * there were no worker, because the page is tested against a server that is
 * rebuilt all day and a cached bundle is exactly the stale screen the
 * server's `no-cache` policy exists to prevent. The one thing kept is the
 * offline page: a navigation that cannot reach the server gets it instead
 * of the browser's own error, since the game cannot run without its server.
 */
const CACHE = "cwb-offline-v1";
const OFFLINE = ["/offline.html", "/icons/icon-192.png"];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      .then((c) => c.addAll(OFFLINE))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  if (req.mode === "navigate") {
    event.respondWith(fetch(req).catch(() => caches.match("/offline.html")));
    return;
  }
  // The offline page's own icon, when the network is gone; otherwise the
  // browser does what it would have done without a worker.
  const url = new URL(req.url);
  if (url.origin === location.origin && OFFLINE.includes(url.pathname)) {
    event.respondWith(fetch(req).catch(() => caches.match(url.pathname)));
  }
});
