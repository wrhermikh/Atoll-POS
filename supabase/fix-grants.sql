-- ---------- Table access (explicit, so it does not depend on Supabase's default grants) ----------
-- Row level security still decides which rows each person can touch. These grants only let the
-- signed-in role reach the tables at all. Nothing is granted to the anonymous role.
grant usage on schema public to anon, authenticated;
grant select on shops, members, plan_requests, records to authenticated;
grant delete on members to authenticated;
grant insert on plan_requests to authenticated;
revoke all on shops, members, plan_requests, records from anon;
-- Lets the Edge Functions (create-staff, set-staff-password) read and write the shop tables.
-- Safe to run more than once.
grant usage on schema public to service_role;
grant select, insert, update, delete on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;
