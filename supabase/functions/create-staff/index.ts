// Creates a staff sign-in (cashier or full access) for a shop. Only the shop's owner or a
// full-access member may call it. Needs the service-role key, which Supabase injects into
// Edge Functions as SUPABASE_SERVICE_ROLE_KEY; it never reaches the browser.
//
// Deploy:  supabase functions deploy create-staff
import { createClient } from 'npm:@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return reply({ error: 'Use POST' }, 405)

  const url = Deno.env.get('SUPABASE_URL')!
  const authHeader = req.headers.get('Authorization') ?? ''
  const caller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: authHeader } } })
  const { data: { user } } = await caller.auth.getUser()
  if (!user) return reply({ error: 'Sign in first' }, 401)

  let b: Record<string, unknown>
  try { b = await req.json() } catch { return reply({ error: 'Bad request' }, 400) }
  const shop_id = String(b.shop_id ?? '')
  const email = String(b.email ?? '').trim().toLowerCase()
  const password = String(b.password ?? '')
  const name = String(b.name ?? '').trim()
  const role = String(b.role ?? 'cashier')
  const allowed = ['sell','discount','credit','prodview','prodedit','invview','recv','cbview','expense','reports','purchase','register','refund']
  const perms = (Array.isArray(b.perms) ? b.perms : []).map(String).filter((p) => allowed.includes(p))

  if (!shop_id || !name) return reply({ error: 'Enter a name' }, 400)
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return reply({ error: 'Enter a valid email address' }, 400)
  if (password.length < 8) return reply({ error: 'The password needs at least 8 characters' }, 400)
  if (!['cashier', 'full'].includes(role)) return reply({ error: 'Role must be cashier or full' }, 400)

  // The caller must manage this shop (checked with the caller's own token, so RLS helpers apply).
  const { data: ok, error: e1 } = await caller.rpc('is_manager', { s: shop_id })
  if (e1 || !ok) return reply({ error: 'Only the owner or full-access staff can add users' }, 403)

  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const { data: shop } = await admin.from('shops').select('status').eq('id', shop_id).single()
  if (!shop || shop.status !== 'active') return reply({ error: 'This shop subscription is suspended' }, 403)

  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true })
  if (e2 || !created.user) {
    // Do not reveal whether the address belongs to someone else's account.
    const taken = /already|registered|exists/i.test(e2?.message ?? '')
    return reply({ error: taken ? 'That email address cannot be used. Try a different one.' : (e2?.message ?? 'Could not create the user') }, 400)
  }
  const { data: member, error: e3 } = await admin.from('members').insert({
    shop_id, user_id: created.user.id, name, email, role,
    perms: role === 'cashier' ? perms : [],
  }).select('id').single()
  if (e3) {
    await admin.auth.admin.deleteUser(created.user.id)
    return reply({ error: e3.message }, 400)
  }
  return reply({ ok: true, member_id: member.id })
})
