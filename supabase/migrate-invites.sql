-- Invite staff by email (no Edge Function needed). Safe to run more than once.
-- The owner adds a name, email and role. When that person signs in (with Google or with a
-- confirmed email and password) using the same email, they join the shop automatically.
begin;

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
commit;
