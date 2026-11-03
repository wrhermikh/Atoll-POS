// Runs on Vercel at build time: writes public/config.js from environment variables.
// Set SUPABASE_URL and SUPABASE_ANON_KEY in Vercel > Project > Settings > Environment Variables.
// The anon key is meant to be public; row level security protects the data. Never use the service-role key here.
const fs = require('fs')
const clean = s => String(s || '').trim().replace(/^["']+|["']+$/g, '').trim()
let url = clean(process.env.SUPABASE_URL)
const key = clean(process.env.SUPABASE_ANON_KEY)
try { if (url) { if (!/^https?:\/\//.test(url)) url = 'https://' + url; url = new URL(url).origin } } catch (e) { console.warn('SUPABASE_URL is not a valid address: ' + url) }
if (url && !/^https:\/\/[a-z0-9]+\.supabase\.co$/.test(url)) console.warn('SUPABASE_URL does not look like https://YOUR-REF.supabase.co')
if (!url || !key) console.warn('SUPABASE_URL / SUPABASE_ANON_KEY not set: the app will run in local demo mode.')
if (/service_role|sb_secret_/i.test(key)) { console.error('SUPABASE_ANON_KEY holds a SECRET key (service_role or sb_secret_). Config.js is public. Use the anon key (starts eyJ) or the sb_publishable_ key, and rotate the secret key in Supabase.'); process.exit(1) }
if (/sb_(publishable|secret)_|service_role|eyJ/i.test(url)) { console.error('SUPABASE_URL holds a key, not an address. It must look like https://YOUR-REF.supabase.co (Supabase > Project Settings > API > Project URL).'); process.exit(1) }
if (url && !/^https:\/\/[a-z0-9-]+(\.[a-z0-9-]+)+$/i.test(url)) { console.error('SUPABASE_URL is not a valid web address: ' + url); process.exit(1) }
if (/^sb_publishable_|^eyJ/.test(url)) { console.error('SUPABASE_URL holds a key.'); process.exit(1) }
fs.writeFileSync('public/config.js', 'window.ATOLL_CONFIG=' + JSON.stringify({ supabaseUrl: url, supabaseAnonKey: key }) + ';\n')
console.log('Wrote public/config.js (' + (url ? 'cloud mode' : 'demo mode') + ')')
