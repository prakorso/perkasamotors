const CACHE = 'pm-v4';

// Gunakan scope SW sebagai base agar bekerja di Netlify (/) maupun GitHub Pages (/perkasamotors/)
function baseURL() {
  return self.registration.scope;
}

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE).then(c =>
      c.addAll([
        baseURL() + 'logo.png',
        baseURL() + 'icon-192.png',
        baseURL() + 'manifest.json',
      ])
    )
  );
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys =>
    Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
  ));
  self.clients.claim();
});

self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  if (url.hostname.indexOf('google.com') >= 0) return;
  if (url.origin !== self.location.origin) return;

  const scope = new URL(baseURL()).pathname; // /perkasamotors/ atau /
  const isIndex = url.pathname === scope || url.pathname === scope + 'index.html';

  // index.html: network-first agar deploy baru langsung terasa di semua device
  if (isIndex) {
    e.respondWith(
      fetch(e.request).then(res => {
        const clone = res.clone();
        caches.open(CACHE).then(c => c.put(e.request, clone));
        return res;
      }).catch(() => caches.match(e.request))
    );
    return;
  }

  // Aset statis: cache-first
  e.respondWith(
    caches.match(e.request).then(cached => cached || fetch(e.request).then(res => {
      if (res.ok) {
        const clone = res.clone();
        caches.open(CACHE).then(c => c.put(e.request, clone));
      }
      return res;
    }))
  );
});
