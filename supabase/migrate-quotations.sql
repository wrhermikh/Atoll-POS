-- Adds quotations. Safe to run on a live project: it only widens what is allowed, nothing is removed or changed.
-- Run it ONCE in the Supabase SQL Editor BEFORE you deploy the new version of the app. Running it again does no harm.
begin;

alter table records drop constraint if exists records_kind_check;
alter table records add constraint records_kind_check
  check (kind in ('products','cats','customers','inv','cash','regs','sups','pord','devs','log','quot'));

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

commit;
