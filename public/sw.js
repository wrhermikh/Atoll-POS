/* Atoll POS service worker: keeps the app and its libraries on the device so it opens with no internet.
   Shop data is stored separately by the app (IndexedDB) and never passes through here. */
const V = 'atoll-sw-3'
const SHELL = ['/', '/index.html', '/config.js']

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
    if (req.mode === 'navigate') return e.respondWith(networkFirst(req, '/index.html'))
    return e.respondWith(networkFirst(req))
  }
  if (/cdn\.jsdelivr\.net|unpkg\.com|cdnjs\.cloudflare\.com|fonts\.googleapis\.com|fonts\.gstatic\.com/.test(u.hostname)) return e.respondWith(cacheFirst(req))
})
