/* Atoll POS service worker: keeps the app and its libraries on the device so it opens with no internet.
   Shop data is stored separately by the app (IndexedDB) and never passes through here. */
const V = 'atoll-sw-8'
const SHELL = ['/', '/index.html', '/config.js', '/manifest.webmanifest', '/icon-192.png', '/icon-512.png', '/favicon.svg']

self.addEventListener('install', (e) => {
  e.waitUntil((async () => {
    const c = await caches.open(V)
    for (const u of SHELL) { try { await c.add(new Request(u, { cache: 'reload' })) } catch (_) {} }
    // Also keep the libraries the page loads from CDNs (spreadsheet, PDF, sign-in, fonts).
    try {
      const html = await (await c.match('/index.html') || await c.match('/')).text()
      const urls = [...html.matchAll(/(?:src|href)=["'](https:\/\/[^"']+)["']/g)].map((m) => m[1])
        .concat([...html.matchAll(/document\.write\('<script src="(https:[^"]+)"/g)].map((m) => m[1]))
      for (const u of new Set(urls)) { try { await c.add(new Request(u, { mode: 'no-cors' })) } catch (_) {} }
    } catch (_) {}
    await self.skipWaiting()
  })())
})

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    for (const k of await caches.keys()) if (k !== V) await caches.delete(k)
    await self.clients.claim()
  })())
})

const store = async (req, res) => {
  if (res && (res.ok || res.type === 'opaque')) { try { (await caches.open(V)).put(req, res.clone()) } catch (_) {} }
  return res
}
const networkFirst = async (req, key) => {
  try {
    const res = await Promise.race([fetch(req), new Promise((_, rej) => setTimeout(() => rej(new Error('slow')), 4000))])
    return await store(key || req, res)
  } catch (_) {
    const hit = await caches.match(key || req, { ignoreSearch: true })
    if (hit) return hit
    return fetch(req)
  }
}
const cacheFirst = async (req) => {
  const hit = await caches.match(req)
  if (hit) { fetch(req).then((r) => store(req, r)).catch(() => {}); return hit }
  return store(req, await fetch(req))
}

self.addEventListener('fetch', (e) => {
  const req = e.request
  if (req.method !== 'GET') return
  const u = new URL(req.url)
  if (u.hostname.endsWith('.supabase.co') || u.hostname.endsWith('.supabase.in')) return // data goes straight to the server
  if (u.origin === self.location.origin) {
    if (req.mode === 'navigate' && (u.pathname === '/' || u.pathname === '/index.html')) return e.respondWith(networkFirst(req, '/index.html'))
    return e.respondWith(networkFirst(req))
  }
  if (/cdn\.jsdelivr\.net|unpkg\.com|cdnjs\.cloudflare\.com|fonts\.googleapis\.com|fonts\.gstatic\.com/.test(u.hostname)) return e.respondWith(cacheFirst(req))
})

/* ---- Push notifications (kitchen tickets, QR orders, ready to serve) ---- */
self.addEventListener('push', (e) => {
  let d = {}
  try { d = e.data ? e.data.json() : {} } catch (_) { d = { title: 'Atoll POS', body: e.data ? e.data.text() : '' } }
  e.waitUntil((async () => {
    // If the app is open and in front, it already plays its own sound and shows its own alert.
    const cs = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    if (cs.some((c) => c.visibilityState === 'visible')) return
    await self.registration.showNotification(d.title || 'Atoll POS', {
      body: d.body || '',
      tag: d.tag || d.topic || 'atoll',
      renotify: true,
      icon: '/icon-192.png',
      badge: '/icon-192.png',
      vibrate: [300, 120, 300, 120, 300],
      requireInteraction: d.topic === 'qr' || d.topic === 'kitchen',
      data: { url: d.url || '/' },
    })
  })())
})
self.addEventListener('notificationclick', (e) => {
  e.notification.close()
  e.waitUntil((async () => {
    const cs = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    for (const c of cs) { if ('focus' in c) { await c.focus(); return } }
    await self.clients.openWindow((e.notification.data && e.notification.data.url) || '/')
  })())
})
