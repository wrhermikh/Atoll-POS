-- Atoll POS: Supabase (Postgres) schema.
-- Run once in the Supabase SQL editor on a fresh project.
--
-- Model: shops, members (staff accounts) and plan requests are real tables.
-- Everything a till works with (products, customers, invoices, cashbook, registers,
-- suppliers, purchase orders, devices, categories, activity log) lives in one `records`
-- table as JSON documents. Clients cannot write to `records` directly: every write goes
-- through put_records / delete_records, which check the member's permissions, the shop's
-- plan and subscription status.

create extension if not exists pgcrypto;

create type plan_tier   as enum ('basic','pro');
create type member_role as enum ('owner','full','cashier');

-- ---------- Tables ----------
create table shops (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  address     text,
  gst_tin     text,
  gst_rate    numeric(5,2) not null default 8,
  plan        plan_tier not null default 'basic',
  status      text not null default 'active' check (status in ('active','suspended')),
  renews_at   timestamptz not null default now() + interval '30 days',
  settings    jsonb not null default '{}'::jsonb,   -- printing defaults, footer, default payment, ...
  invoice_seq bigint not null default 1001,         -- next invoice number to hand out
  created_at  timestamptz not null default now()
);

create table members (
  id         uuid primary key default gen_random_uuid(),
  shop_id    uuid not null references shops on delete cascade,
  user_id    uuid references auth.users on delete set null,
  name       text not null,
  email      text,
  role       member_role not null default 'cashier',
  perms      text[] not null default '{sell,prodview,register}',
  created_at timestamptz not null default now(),
  unique (shop_id, user_id)
);
create unique index one_owner_per_shop on members(shop_id) where role = 'owner';
create index members_user on members(user_id);

create table platform_admins (user_id uuid primary key references auth.users on delete cascade);

create table plan_requests (
  id         uuid primary key default gen_random_uuid(),
  shop_id    uuid not null references shops on delete cascade,
  plan       plan_tier not null,
  ref        text not null,
  status     text not null default 'pending' check (status in ('pending','approved','declined','cancelled')),
  created_at timestamptz not null default now()
);

create table records (
  shop_id    uuid not null references shops on delete cascade,
  kind       text not null check (kind in ('products','cats','customers','inv','cash','regs','sups','pord','devs','log','quot')),
  rid        text not null,
  data       jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (shop_id, kind, rid)
);

-- ---------- Access helpers ----------
create or replace function is_member(s uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from members where shop_id = s and user_id = auth.uid()) $$;

create or replace function is_manager(s uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from members where shop_id = s and user_id = auth.uid() and role in ('owner','full')) $$;

create or replace function is_owner(s uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from members where shop_id = s and user_id = auth.uid() and role = 'owner') $$;

-- Owner and full-access members have every permission; cashiers have the ones listed in members.perms.
create or replace function has_perm(s uuid, p text) returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from members where shop_id = s and user_id = auth.uid()
                  and (role <> 'cashier' or p = any(perms))) $$;

create or replace function is_platform_admin() returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from platform_admins where user_id = auth.uid()) $$;

create or replace function am_i_admin() returns boolean language sql stable security definer set search_path = public as
$$ select is_platform_admin() $$;

-- Which kinds a member may read / write (the in-app permission switches).
create or replace function can_read_kind(s uuid, k text) returns boolean language sql stable security definer set search_path = public as $$
  select case k
    when 'products'  then is_member(s)
    when 'cats'      then is_member(s)
    when 'customers' then is_member(s)
    when 'devs'      then is_member(s)
    when 'inv'       then has_perm(s,'invview') or has_perm(s,'sell') or has_perm(s,'recv') or has_perm(s,'refund')
    when 'quot'      then has_perm(s,'invview') or has_perm(s,'sell')
    when 'cash'      then has_perm(s,'cbview') or has_perm(s,'sell') or has_perm(s,'expense') or has_perm(s,'recv')
    when 'regs'      then has_perm(s,'register') or has_perm(s,'reports')
    when 'sups'      then has_perm(s,'purchase')
    when 'pord'      then has_perm(s,'purchase')
    when 'log'       then is_manager(s)
    else false end
$$;

create or replace function can_write_kind(s uuid, k text) returns boolean language sql stable security definer set search_path = public as $$
  select case k
    when 'products'  then has_perm(s,'prodedit') or has_perm(s,'sell') or has_perm(s,'purchase') or has_perm(s,'refund')
    when 'cats'      then has_perm(s,'prodedit')
    when 'customers' then has_perm(s,'sell') or has_perm(s,'recv') or has_perm(s,'credit')
    when 'inv'       then has_perm(s,'sell') or has_perm(s,'recv') or has_perm(s,'refund')
    when 'quot'      then has_perm(s,'sell')
    when 'cash'      then has_perm(s,'sell') or has_perm(s,'expense') or has_perm(s,'recv') or has_perm(s,'refund')
    when 'regs'      then has_perm(s,'register')
    when 'sups'      then has_perm(s,'purchase')
    when 'pord'      then has_perm(s,'purchase')
    when 'devs'      then is_manager(s)
    when 'log'       then is_member(s)
    else false end
$$;

-- A product with every stock figure removed (product, variants, sub-variants).
create or replace function strip_stock(j jsonb) returns jsonb language sql immutable as $$
  select (j - 'stock') || jsonb_build_object('variants', coalesce((
    select jsonb_agg((v - 'stock') || jsonb_build_object('subs', coalesce((
      select jsonb_agg(sv - 'stock') from jsonb_array_elements(case when jsonb_typeof(v->'subs') = 'array' then v->'subs' else '[]'::jsonb end) sv), '[]'::jsonb)))
    from jsonb_array_elements(case when jsonb_typeof(j->'variants') = 'array' then j->'variants' else '[]'::jsonb end) v), '[]'::jsonb))
$$;

-- ---------- Create a shop (owner signs up with email, then calls this) ----------
create or replace function create_shop(p_name text, p_owner_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare s uuid; e text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select email into e from auth.users where id = auth.uid();
  if e is null then raise exception 'Owners must sign up with an email address'; end if;
  -- One account can own several shops (each is billed and isolated separately).
  if (select count(*) from members where user_id = auth.uid() and role = 'owner') >= 5 then raise exception 'An account can own up to 5 shops'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'Enter a shop name'; end if;
  insert into shops(name) values (trim(p_name)) returning id into s;
  insert into members(shop_id, user_id, name, email, role, perms)
    values (s, auth.uid(), coalesce(nullif(trim(p_owner_name),''), 'Owner'), e, 'owner', '{}');
  return s;
end $$;

-- ---------- Invoice numbers: each till leases a block so numbers never collide ----------
create or replace function claim_invoice_numbers(p_shop uuid, p_n int) returns bigint
language plpgsql security definer set search_path = public as $$
declare nv bigint;
begin
  if not (has_perm(p_shop,'sell') or has_perm(p_shop,'refund')) then raise exception 'Not allowed'; end if;
  if p_n < 1 or p_n > 200 then raise exception 'Bad block size'; end if;
  update shops set invoice_seq = invoice_seq + p_n where id = p_shop returning invoice_seq into nv;
  return nv - p_n;
end $$;

-- ---------- Writes to records ----------
create or replace function put_records(p_shop uuid, p_kind text, p_rows jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare r jsonb; old jsonb; sh shops; n int := 0; newcnt int := 0; cur int; editor boolean;
begin
  if auth.uid() is null or not is_member(p_shop) then raise exception 'Not allowed'; end if;
  select * into sh from shops where id = p_shop;
  if sh.status <> 'active' then raise exception 'This shop subscription is suspended'; end if;
  if not can_write_kind(p_shop, p_kind) then raise exception 'You do not have permission to change this'; end if;
  if p_kind in ('sups','pord','regs') and sh.plan = 'basic' then raise exception 'This feature needs the Pro plan'; end if;
  editor := has_perm(p_shop, 'prodedit');

  if p_kind = 'products' then
    select count(*) into cur from records where shop_id = p_shop and kind = 'products';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    select data into old from records where shop_id = p_shop and kind = p_kind and rid = r->>'rid';
    if p_kind = 'products' then
      if old is null then
        if not editor then raise exception 'You do not have permission to add products'; end if;
        newcnt := newcnt + 1;
      elsif not editor and strip_stock(old) is distinct from strip_stock(r->'data') then
        raise exception 'You do not have permission to change products or prices';
      end if;
      if sh.plan = 'basic' then
        if jsonb_typeof(r->'data'->'variants') = 'array' and jsonb_array_length(r->'data'->'variants') > 0 then
          raise exception 'Variants and sub-variants need the Pro plan';
        end if;
        if cur + newcnt > 3000 then raise exception 'The Basic plan allows up to 3000 products'; end if;
      end if;
    elsif p_kind = 'inv' and old is not null and not (has_perm(p_shop,'recv') or has_perm(p_shop,'refund') or is_manager(p_shop)) then
      raise exception 'Invoices cannot be changed';
    elsif p_kind = 'log' and old is not null then
      raise exception 'The activity log cannot be changed';
    end if;
    insert into records(shop_id, kind, rid, data, updated_by) values (p_shop, p_kind, r->>'rid', r->'data', auth.uid())
      on conflict (shop_id, kind, rid) do update set data = excluded.data, updated_at = now(), updated_by = auth.uid();
    if p_kind = 'products' and (old is null or (old->>'name') is distinct from (r->'data'->>'name') or (old->>'barcode') is distinct from (r->'data'->>'barcode')) then
      perform master_ingest(p_shop, r->'data');
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function delete_records(p_shop uuid, p_kind text, p_rids text[]) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null or not is_member(p_shop) then raise exception 'Not allowed'; end if;
  if (select status from shops where id = p_shop) <> 'active' then raise exception 'This shop subscription is suspended'; end if;
  if p_kind in ('log','inv') then raise exception 'These records cannot be deleted'; end if;
  if p_kind = 'products' or p_kind = 'cats' then
    if not has_perm(p_shop,'prodedit') then raise exception 'You do not have permission to remove products'; end if;
  elsif p_kind = 'cash' then
    if not is_manager(p_shop) then raise exception 'Only managers can remove cashbook entries'; end if;
  elsif not can_write_kind(p_shop, p_kind) then
    raise exception 'You do not have permission to change this';
  end if;
  delete from records where shop_id = p_shop and kind = p_kind and rid = any(p_rids);
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- Platform team (service operators) ----------




-- ---------- Master product catalogue (platform-owned, de-duplicated) ----------
-- Every product a shop adds is cross-matched against this list by barcode or by name. If it is not
-- there yet it is added; if it is, the master list is left alone (the shop keeps its own copy either
-- way). Only name, barcode, category, unit and GST type are copied. Prices, costs and stock never are.
create table master_products (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  name_key   text not null unique,     -- lower-case letters and digits only, so "Sugar 1 kg" = "sugar 1KG"
  barcode    text unique,
  category   text,
  unit       text not null default '' check (unit in ('','kg')),
  tax        text not null default '' check (tax in ('','zero','exempt')),
  first_shop uuid references shops on delete set null,
  created_at timestamptz not null default now()
);
create table master_sources (
  master_id uuid not null references master_products on delete cascade,
  shop_id   uuid not null references shops on delete cascade,
  primary key (master_id, shop_id)
);

create or replace function master_key(t text) returns text language sql immutable as
$$ select regexp_replace(lower(coalesce(t,'')), '[^a-z0-9\u0780-\u07bf]+', '', 'g') $$;

create or replace function master_ingest(p_shop uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare k text := master_key(p->>'name'); bc text := nullif(trim(coalesce(p->>'barcode','')), ''); mid uuid;
        u text := case when p->>'unit' = 'kg' then 'kg' else '' end;
        tx text := case when p->>'tax' in ('zero','exempt') then p->>'tax' else '' end;
begin
  if k = '' then return; end if;
  select id into mid from master_products where (bc is not null and barcode = bc) or name_key = k order by (barcode = bc) desc nulls last limit 1;
  if mid is null then
    insert into master_products(name, name_key, barcode, category, unit, tax, first_shop)
      values (left(trim(p->>'name'), 200), k, bc, nullif(left(trim(coalesce(p->>'cat','')), 80), ''), u, tx, p_shop)
      on conflict do nothing returning id into mid;
    if mid is null then   -- lost a race with another shop: use the row that won
      select id into mid from master_products where (bc is not null and barcode = bc) or name_key = k limit 1;
    end if;
  else
    -- a duplicate: keep the single master row, but fill in a barcode or category it was missing
    update master_products set barcode = coalesce(barcode, case when bc is not null and not exists (select 1 from master_products m2 where m2.barcode = bc) then bc end),
                               category = coalesce(category, nullif(left(trim(coalesce(p->>'cat','')), 80), ''))
      where id = mid;
  end if;
  if mid is not null and p_shop is not null then insert into master_sources(master_id, shop_id) values (mid, p_shop) on conflict do nothing; end if;
end $$;
revoke all on function master_ingest(uuid, jsonb) from public, anon, authenticated;

-- ---------- Row Level Security ----------
alter table shops           enable row level security;
alter table members         enable row level security;
alter table platform_admins enable row level security;   -- no policies: service role only
alter table plan_requests   enable row level security;
alter table records         enable row level security;

create policy shops_read on shops for select using (is_member(id));
-- Owners and full-access members may edit these columns only (plan, status, renewal and the
-- invoice counter can only change through the functions above).
create policy shops_update on shops for update using (is_manager(id)) with check (is_manager(id));
revoke update on shops from anon, authenticated;
grant update (name, address, gst_tin, gst_rate, settings) on shops to authenticated;

create policy members_read   on members for select using (is_member(shop_id));
create policy members_update on members for update using (is_manager(shop_id) and role <> 'owner')
                                                  with check (is_manager(shop_id) and role <> 'owner');
create policy members_delete on members for delete using (is_manager(shop_id) and role <> 'owner');
-- Staff are created by the create-staff Edge Function (service role), so there is no insert policy.
revoke update on members from anon, authenticated;
grant update (name, role, perms) on members to authenticated;

create policy plan_req_read   on plan_requests for select using (is_manager(shop_id));
create policy plan_req_insert on plan_requests for insert with check (is_owner(shop_id) and status = 'pending');
create policy plan_req_cancel on plan_requests for update using (is_owner(shop_id) and status = 'pending')
                                                          with check (is_owner(shop_id) and status = 'cancelled');
revoke update on plan_requests from anon, authenticated;
grant update (status) on plan_requests to authenticated;

create policy records_read on records for select using (can_read_kind(shop_id, kind));
-- no insert/update/delete policies on records: writes go through put_records / delete_records
revoke insert, update, delete on records from anon, authenticated;


-- ---------- Table access (explicit, so it does not depend on Supabase's default grants) ----------
-- Row level security still decides which rows each person can touch. These grants only let the
-- signed-in role reach the tables at all. Nothing is granted to the anonymous role.
grant usage on schema public to anon, authenticated;
grant select on shops, members, plan_requests, records to authenticated;
grant delete on members to authenticated;
grant insert on plan_requests to authenticated;
revoke all on shops, members, plan_requests, records from anon;

-- ---------- Function access ----------
revoke all on function put_records(uuid,text,jsonb), delete_records(uuid,text,text[]), claim_invoice_numbers(uuid,int),
  create_shop(text,text), am_i_admin() from public, anon;
grant execute on function put_records(uuid,text,jsonb), delete_records(uuid,text,text[]), claim_invoice_numbers(uuid,int),
  create_shop(text,text), am_i_admin() to authenticated;


-- ---------- Platform team: master catalogue ----------



-- Build the master list from products shops added before this feature existed (safe to run again).
alter table master_products enable row level security;   -- no policies: reached only through the functions above
alter table master_sources  enable row level security;
revoke all on master_products, master_sources from anon, authenticated;


-- ---------- Platform console ----------
-- Everything below is reachable only by platform_admins. Tables have row level security with no policies.
create table shop_admin (shop_id uuid primary key references shops on delete cascade, note text not null default '', updated_at timestamptz not null default now());
create table admin_log (id bigserial primary key, at timestamptz not null default now(), admin text, action text not null, shop_id uuid references shops on delete set null, detail text);
alter table shop_admin enable row level security;
alter table admin_log  enable row level security;
revoke all on shop_admin, admin_log from anon, authenticated;

create or replace function admin_audit(p_action text, p_shop uuid, p_detail text) returns void
language sql security definer set search_path = public as $$
  insert into admin_log(admin, action, shop_id, detail)
  values (coalesce((select email from auth.users where id = auth.uid()), ''), p_action, p_shop, p_detail) $$;

create or replace function admin_list_shops() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Not allowed'; end if;
  return coalesce((select jsonb_agg(x order by x->>'created_at' desc) from (
    select jsonb_build_object(
      'id', s.id, 'name', s.name, 'plan', s.plan, 'status', s.status, 'renews_at', s.renews_at, 'created_at', s.created_at,
      'owner_name', (select name from members m where m.shop_id = s.id and m.role = 'owner'),
      'owner_email', (select email from members m where m.shop_id = s.id and m.role = 'owner'),
      'users', (select count(*) from members m where m.shop_id = s.id),
      'products', (select count(*) from records r where r.shop_id = s.id and r.kind = 'products'),
      'invoices', (select count(*) from records r where r.shop_id = s.id and r.kind = 'inv'),
      'last_active', (select max(updated_at) from records r where r.shop_id = s.id),
      'note', coalesce((select note from shop_admin a where a.shop_id = s.id), ''),
      'requests', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'plan', p.plan, 'ref', p.ref, 'created_at', p.created_at) order by p.created_at)
                            from plan_requests p where p.shop_id = s.id and p.status = 'pending'), '[]'::jsonb)
    ) as x from shops s) t), '[]'::jsonb);
end $$;

create or replace function admin_shop_detail(p_shop uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Not allowed'; end if;
  return jsonb_build_object(
    'staff', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'email', email, 'role', role, 'created_at', created_at) order by created_at) from members where shop_id = p_shop), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('plan', plan, 'ref', ref, 'status', status, 'created_at', created_at) order by created_at desc) from plan_requests where shop_id = p_shop), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('at', at, 'admin', admin, 'action', action, 'detail', detail) order by at desc) from (select * from admin_log where shop_id = p_shop order by at desc limit 20) l), '[]'::jsonb));
end $$;

create or replace function admin_set_shop(p_shop uuid, p_plan plan_tier, p_status text, p_renews_at timestamptz) returns void
language plpgsql security definer set search_path = public as $$
declare o shops; d text := '';
begin
  if not is_platform_admin() then raise exception 'Not allowed'; end if;
  select * into o from shops where id = p_shop;
  if not found then raise exception 'Shop not found'; end if;
  update shops set plan = p_plan, status = p_status, renews_at = p_renews_at where id = p_shop;
  if o.plan <> p_plan then d := d || 'plan ' || o.plan || ' to ' || p_plan || '; '; end if;
  if o.status <> p_status then d := d || 'status ' || o.status || ' to ' || p_status || '; '; end if;
  if o.renews_at <> p_renews_at then d := d || 'renews ' || to_char(p_renews_at, 'YYYY-MM-DD') || '; '; end if;
  if d <> '' then perform admin_audit('shop_update', p_shop, d); end if;
end $$;

create or replace function admin_review_request(p_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r plan_requests;
begin
  if not is_platform_admin() then raise exception 'Not allowed'; end if;
  select * into r from plan_requests where id = p_id and status = 'pending';
  if not found then raise exception 'Request not found'; end if;
  if p_approve then
    update shops set plan = r.plan, renews_at = greatest(renews_at, now()) + interval '30 days', status = 'active' where id = r.shop_id;
    update plan_requests set status = 'approved' where id = p_id;
  else
    update plan_requests set status = 'declined' where id = p_id;
  end if;
  perform admin_audit(case when p_approve then 'request_approved' else 'request_declined' end, r.shop_id, r.plan || ' plan, ref ' || r.ref);
end $$;

create or replace function admin_set_note(p_shop uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Not allowed'; end if;
  insert into shop_admin(shop_id, note) values (p_shop, left(coalesce(p_note,''), 2000))
    on conflict (shop_id) do update set note = excluded.note, updated_at = now();
end $$;

create or replace function admin_log_list(p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Not allowed'; end if;
  return coalesce((select jsonb_agg(x) from (
    select l.at, l.admin, l.action, l.detail, s.name as shop from admin_log l left join shops s on s.id = l.shop_id
    order by l.at desc limit least(greatest(p_limit,1),500)) x), '[]'::jsonb);
end $$;

create or replace function admin_master_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Not allowed'; end if;
  return jsonb_build_object('products', (select count(*) from master_products),
                            'with_barcode', (select count(*) from master_products where barcode is not null),
                            'shops', (select count(distinct shop_id) from master_sources),
                            'multi', (select count(*) from (select master_id from master_sources group by 1 having count(*) > 1) z),
                            'new7', (select count(*) from master_products where created_at > now() - interval '7 days'));
end $$;

-- p_filter: '' all | 'nobarcode' | 'multi' (used by 2+ shops) | 'new' (last 7 days); p_sort: 'name' | 'shops' | 'new'
create or replace function admin_master_list(p_q text default '', p_limit int default 100, p_offset int default 0, p_filter text default '', p_sort text default 'name') returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q text := '%' || lower(coalesce(p_q,'')) || '%';
begin
  if not is_platform_admin() then raise exception 'Not allowed'; end if;
  return (with base as (
      select m.id, m.name, m.barcode, m.category, m.unit, m.tax, m.created_at,
             (select count(*) from master_sources s where s.master_id = m.id) as shops
      from master_products m
      where (coalesce(p_q,'') = '' or lower(m.name) like q or m.barcode like q or lower(coalesce(m.category,'')) like q)
        and (coalesce(p_filter,'') = ''
             or (p_filter = 'nobarcode' and m.barcode is null)
             or (p_filter = 'new' and m.created_at > now() - interval '7 days')
             or (p_filter = 'multi' and (select count(*) from master_sources s where s.master_id = m.id) > 1))),
    page as (select * from base order by
      case when p_sort = 'shops' then shops end desc nulls last,
      case when p_sort = 'new' then created_at end desc nulls last,
      name limit least(greatest(p_limit,1),1000) offset greatest(p_offset,0))
    select jsonb_build_object('total', (select count(*) from base),
                              'rows', coalesce((select jsonb_agg(to_jsonb(page)) from page), '[]'::jsonb)));
end $$;

create or replace function admin_master_update(p_id uuid, p_name text, p_barcode text, p_category text, p_unit text, p_tax text) returns void
language plpgsql security definer set search_path = public as $$
declare k text := master_key(p_name); bc text := nullif(trim(coalesce(p_barcode,'')), '');
begin
  if not is_platform_admin() then raise exception 'Not allowed'; end if;
  if k = '' then raise exception 'The name cannot be empty'; end if;
  if exists (select 1 from master_products where name_key = k and id <> p_id) then raise exception 'Another entry already has this name. Merge them instead.'; end if;
  if bc is not null and exists (select 1 from master_products where barcode = bc and id <> p_id) then raise exception 'Another entry already has this barcode. Merge them instead.'; end if;
  update master_products set name = left(trim(p_name), 200), name_key = k, barcode = bc, category = nullif(left(trim(coalesce(p_category,'')), 80), ''),
         unit = case when p_unit = 'kg' then 'kg' else '' end, tax = case when p_tax in ('zero','exempt') then p_tax else '' end where id = p_id;
  perform admin_audit('master_edit', null, left(trim(p_name), 200));
end $$;

-- Merge p_drop into p_keep: shops that used p_drop now count under p_keep, missing barcode/category are filled in.
create or replace function admin_master_merge(p_keep uuid, p_drop uuid) returns void
language plpgsql security definer set search_path = public as $$
declare k master_products; d master_products;
begin
  if not is_platform_admin() then raise exception 'Not allowed'; end if;
  if p_keep = p_drop then raise exception 'Choose two different entries'; end if;
  select * into k from master_products where id = p_keep; select * into d from master_products where id = p_drop;
  if k.id is null or d.id is null then raise exception 'Entry not found'; end if;
  insert into master_sources(master_id, shop_id) select p_keep, shop_id from master_sources where master_id = p_drop on conflict do nothing;
  delete from master_products where id = p_drop;
  update master_products set barcode = coalesce(barcode, d.barcode), category = coalesce(category, d.category) where id = p_keep;
  perform admin_audit('master_merge', null, d.name || ' into ' || k.name);
end $$;

create or replace function admin_master_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n text;
begin
  if not is_platform_admin() then raise exception 'Not allowed'; end if;
  select name into n from master_products where id = p_id;
  delete from master_products where id = p_id;
  perform admin_audit('master_delete', null, n);
end $$;

create or replace function admin_master_rebuild() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  if not is_platform_admin() then raise exception 'Not allowed'; end if;
  for r in select shop_id, data from records where kind = 'products' order by updated_at loop
    perform master_ingest(r.shop_id, r.data); n := n + 1;
  end loop;
  perform admin_audit('master_rebuild', null, n || ' shop products checked');
  return n;
end $$;

-- Seed the catalogue from a list you hold (rows: [{name, barcode, cat, unit, tax}]). Duplicates are skipped like any other.
create or replace function admin_master_import(p_rows jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare r jsonb; n int := 0; before int; after int;
begin
  if not is_platform_admin() then raise exception 'Not allowed'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 5000 then raise exception 'Send at most 5,000 rows at a time'; end if;
  select count(*) into before from master_products;
  for r in select * from jsonb_array_elements(p_rows) loop perform master_ingest(null, r); end loop;
  select count(*) into after from master_products;
  perform admin_audit('master_import', null, (after - before) || ' added of ' || jsonb_array_length(p_rows) || ' rows');
  return after - before;
end $$;

revoke all on function admin_audit(text,uuid,text), admin_list_shops(), admin_shop_detail(uuid), admin_set_shop(uuid,plan_tier,text,timestamptz),
  admin_review_request(uuid,boolean), admin_set_note(uuid,text), admin_log_list(int), admin_master_stats(),
  admin_master_list(text,int,int,text,text), admin_master_update(uuid,text,text,text,text,text), admin_master_merge(uuid,uuid),
  admin_master_delete(uuid), admin_master_rebuild(), admin_master_import(jsonb) from public, anon, authenticated;
grant execute on function admin_list_shops(), admin_shop_detail(uuid), admin_set_shop(uuid,plan_tier,text,timestamptz),
  admin_review_request(uuid,boolean), admin_set_note(uuid,text), admin_log_list(int), admin_master_stats(),
  admin_master_list(text,int,int,text,text), admin_master_update(uuid,text,text,text,text,text), admin_master_merge(uuid,uuid),
  admin_master_delete(uuid), admin_master_rebuild(), admin_master_import(jsonb) to authenticated;

-- ---------- Realtime (other tills see changes within a second) ----------
alter publication supabase_realtime add table records, shops, members;

-- ---------- First platform admin ----------
-- After you have signed up in the app with your own email, run (replace the address):
--   insert into platform_admins select id from auth.users where email = 'you@example.com';
-- Lets the Edge Functions (create-staff, set-staff-password) read and write the shop tables.
-- Safe to run more than once.
grant usage on schema public to service_role;
grant select, insert, update, delete on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;
-- Invite staff by email (no Edge Function needed). Safe to run more than once.
-- The owner adds a name, email and role. When that person signs in (with Google or with a
-- confirmed email and password) using the same email, they join the shop automatically.


create table if not exists invites (
  id         uuid primary key default gen_random_uuid(),
  shop_id    uuid not null references shops on delete cascade,
  email      text not null,
  name       text not null,
  role       member_role not null default 'cashier',
  perms      text[] not null default '{sell,prodview,register}',
  created_at timestamptz not null default now(),
  unique (shop_id, email)
);
alter table invites enable row level security;
drop policy if exists invites_read on invites;
create policy invites_read on invites for select using (is_manager(shop_id));
revoke all on invites from anon, authenticated;
grant select on invites to authenticated;
grant all on invites to service_role;

create or replace function invite_member(p_shop uuid, p_email text, p_name text, p_role text, p_perms text[])
returns uuid language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(coalesce(p_email,''))); new_id uuid; allowed text[] := array['sell','discount','credit','prodview','prodedit','invview','recv','cbview','expense','reports','purchase','register','refund'];
begin
  if not is_manager(p_shop) then raise exception 'Only the owner or full-access staff can add users'; end if;
  if (select status from shops where id = p_shop) <> 'active' then raise exception 'This shop subscription is suspended'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'Enter a name'; end if;
  if e !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then raise exception 'Enter a valid email address'; end if;
  if p_role not in ('cashier','full') then raise exception 'Role must be cashier or full'; end if;
  if exists (select 1 from members where shop_id = p_shop and lower(email) = e) then raise exception 'That person is already in this shop'; end if;
  insert into invites(shop_id, email, name, role, perms)
    values (p_shop, e, trim(p_name), p_role::member_role,
            case when p_role = 'cashier' then coalesce((select array_agg(x) from unnest(p_perms) x where x = any(allowed)), '{}') else '{}' end)
    on conflict (shop_id, email) do update set name = excluded.name, role = excluded.role, perms = excluded.perms
    returning invites.id into new_id;
  return new_id;
end $$;

create or replace function revoke_invite(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from invites where id = p_id and is_manager(shop_id);
end $$;

-- Called by the app right after sign-in: turns any invitation for this account's email into membership.
create or replace function claim_invites() returns int
language plpgsql security definer set search_path = public as $$
declare e text; n int := 0; r record;
begin
  if auth.uid() is null then return 0; end if;
  select lower(email) into e from auth.users where id = auth.uid() and email_confirmed_at is not null;
  if e is null then return 0; end if;
  for r in select * from invites where email = e and (select status from shops where id = shop_id) = 'active' loop
    insert into members(shop_id, user_id, name, email, role, perms)
      values (r.shop_id, auth.uid(), r.name, e, r.role, r.perms)
      on conflict (shop_id, user_id) do nothing;
    delete from invites where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

revoke all on function invite_member(uuid,text,text,text,text[]), revoke_invite(uuid), claim_invites() from public, anon;
grant execute on function invite_member(uuid,text,text,text,text[]), revoke_invite(uuid), claim_invites() to authenticated;

-- Staff sign in with shop name + their name + password. Each shop gets a short unique sign-in name.
-- Safe to run more than once on a live database.
alter table shops add column if not exists slug text;

create or replace function make_shop_slug(p_name text, p_id uuid) returns text
language plpgsql as $$
declare base text; cand text; n int := 1;
begin
  base := regexp_replace(lower(coalesce(p_name,'')), '[^a-z0-9]', '', 'g');
  if base = '' then base := 'shop'; end if;
  cand := base;
  while exists (select 1 from shops where slug = cand and id <> p_id) loop
    n := n + 1; cand := base || n;
  end loop;
  return cand;
end $$;

create or replace function shops_set_slug() returns trigger
language plpgsql as $$
begin
  if new.slug is null or new.slug = '' then new.slug := make_shop_slug(new.name, new.id); end if;
  return new;
end $$;
drop trigger if exists shops_slug on shops;
create trigger shops_slug before insert on shops for each row execute function shops_set_slug();

update shops set slug = make_shop_slug(name, id) where slug is null or slug = '';
create unique index if not exists shops_slug_key on shops(slug);
