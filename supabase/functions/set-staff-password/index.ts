// Lets the owner (or a full-access member) set a new password for a staff member of the same shop.
// The owner's own password is changed from the app with the normal Supabase Auth call.
//
// Deploy:  supabase functions deploy set-staff-password
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
  const caller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } })
  const { data: { user } } = await caller.auth.getUser()
  if (!user) return reply({ error: 'Sign in first' }, 401)

  let b: Record<string, unknown>
  try { b = await req.json() } catch { return reply({ error: 'Bad request' }, 400) }
  const shop_id = String(b.shop_id ?? ''), member_id = String(b.member_id ?? ''), password = String(b.password ?? '')
  if (password.length < 8) return reply({ error: 'The password needs at least 8 characters' }, 400)

  const { data: ok } = await caller.rpc('is_manager', { s: shop_id })
  if (!ok) return reply({ error: 'Only the owner or full-access staff can change a password' }, 403)

  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  // The target must belong to this same shop and must not be the owner.
  const { data: m } = await admin.from('members').select('user_id, role').eq('id', member_id).eq('shop_id', shop_id).single()
  if (!m || !m.user_id) return reply({ error: 'Member not found' }, 404)
  if (m.role === 'owner') return reply({ error: 'The owner changes their own password' }, 403)

  // A login that also belongs to another shop is never changed from here.
  const { count } = await admin.from('members').select('id', { count: 'exact', head: true }).eq('user_id', m.user_id)
  if ((count ?? 0) > 1) return reply({ error: 'This login is shared with another shop. Ask the person to change it themselves.' }, 403)

  const { error } = await admin.auth.admin.updateUserById(m.user_id, { password })
  if (error) return reply({ error: error.message }, 400)
  return reply({ ok: true })
})
