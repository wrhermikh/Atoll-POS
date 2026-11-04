-- Staff sign in with shop name + their name + password. Each shop gets a short unique sign-in name.
-- Safe to run more than once on a live database.
begin;
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
commit;
