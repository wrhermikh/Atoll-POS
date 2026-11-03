// Runs on Vercel at build time: writes public/config.js from environment variables.
// Set SUPABASE_URL and SUPABASE_ANON_KEY in Vercel > Project > Settings > Environment Variables.
// The anon key is meant to be public; row level security protects the data. Never use the service-role key here.
const fs = require('fs')
const url = (process.env.SUPABASE_URL || '').trim()
const key = (process.env.SUPABASE_ANON_KEY || '').trim()
if (!url || !key) console.warn('SUPABASE_URL / SUPABASE_ANON_KEY not set: the app will run in local demo mode.')
if (/service_role/i.test(key)) { console.error('That looks like a service-role key. Use the anon (public) key.'); process.exit(1) }
fs.writeFileSync('public/config.js', 'window.ATOLL_CONFIG=' + JSON.stringify({ supabaseUrl: url, supabaseAnonKey: key }) + ';\n')
console.log('Wrote public/config.js (' + (url ? 'cloud mode' : 'demo mode') + ')')
