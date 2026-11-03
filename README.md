# Atoll POS

Subscription point-of-sale for Maldivian retailers. Static front end on **Vercel**, database, sign-in and live sync on **Supabase**.
Without Supabase keys the app runs as a local demo (data stays in the browser).

## Set up (about 20 minutes)

### 1. Supabase
1. Create a project at supabase.com.
2. **SQL Editor** > paste `supabase/schema.sql` > Run.
3. **Authentication > Providers > Email**: keep *Confirm email* on (owners must confirm their email).
4. **Google sign-in (optional)**: in Google Cloud Console > APIs & Services > Credentials, create an *OAuth client ID* (Web application). Add `https://YOUR-PROJECT-REF.supabase.co/auth/v1/callback` as an authorised redirect URI. Then in Supabase **Authentication > Providers > Google**, switch it on and paste the client ID and secret. If you skip this, the *Continue with Google* button shows an error and email sign-in still works.
5. **Authentication > URL Configuration**: set *Site URL* to your Vercel address (add `http://localhost:3000` too if you test locally).
6. **Edge Function for staff sign-ins**: install the [Supabase CLI](https://supabase.com/docs/guides/cli), then
   ```
   supabase login
   supabase link --project-ref YOUR-PROJECT-REF
   supabase functions deploy create-staff
   supabase functions deploy set-staff-password
   ```
   The function uses the service-role key that Supabase provides to it automatically. Do not put that key anywhere else.
7. Sign up once in the app with your own email, then in the SQL Editor make yourself the platform admin:
   ```sql
   insert into platform_admins select id from auth.users where email = 'you@example.com';
   ```
   Signing in with that email opens the platform console (all shops, plan changes, approving bank-transfer payments, suspending shops).

### 2. Vercel
1. Push this repo to GitHub and import it in Vercel (no framework preset needed).
2. Add environment variables (Project > Settings > Environment Variables):
   - `SUPABASE_URL` = Project Settings > API > Project URL
   - `SUPABASE_ANON_KEY` = Project Settings > API > `anon` `public` key
3. Deploy. The build step (`scripts/make-config.js`) writes `public/config.js` from those variables.

To run locally: copy `.env.example`, export the two variables, run `node scripts/make-config.js`, then serve `public/` (for example `npx serve public`).

## How it works
- **Accounts:** everyone signs in with email and password, or with Google, through Supabase Auth. There are no PINs. The home page has *Sign up* and *Log in*; a first-time Google user is asked for a shop name and a password. The owner (or a full-access member) adds staff in *Team* with an email and password (`create-staff` function) and can reset a staff password (`set-staff-password` function). Sensitive actions (refunds, removing users, changing permissions) ask for the account password again.
- **Several shops:** one account can own up to 5 shops. After login a picker lists only that account's own shops; *Switch shop* clears everything from memory first. Each shop has its own staff, data and plan. A staff email belongs to one shop; a person working in two shops needs two logins.
- **Shared computers:** tick *This is a shared computer* at login. The session then lives only in that tab and signs out after 20 minutes idle. *Sign out of all devices* revokes every session.
- **Master product catalogue:** when a shop adds or renames a product, its name and barcode are matched (case, spaces and punctuation ignored) against `master_products`. A new entry is added only if neither name nor barcode matches. The shop always keeps its own product either way. Only name, barcode, category, unit and tax type are copied, never price, cost, stock or which shop. Only the platform admin can see it (see *Platform console* below).
- **Shop isolation:** every table has row level security keyed on shop membership and writes go through functions that re-check it. Shops cannot see each other's name, staff, records, plan requests or the master catalogue. Sign-up and staff creation use generic error messages, so they do not reveal whether an email is registered.
- **Data:** shops, staff and plan requests are normal tables. Products, customers, invoices, cashbook, registers, suppliers, purchase orders, devices and the activity log are JSON documents in the `records` table. Browsers cannot write to it directly. All writes go through `put_records` and `delete_records`, which check the member's permissions, the shop's plan (Basic: 3,000 products, no variants, no Pro features) and whether the subscription is active.
- **Cashiers** can sell and change stock, but the database rejects any change to a product's name, price, barcode or other fields unless they have the product-edit permission.
- **Plan, renewal and suspension** can only be changed by the platform admin through `admin_set_shop` / `admin_review_request`. Owners can request a plan change with a bank-transfer reference. You confirm payment in the console.
- **Live sync:** changes appear on other tills within about a second (Supabase Realtime), with a fallback refresh every minute and when the tab regains focus.
- **Invoice numbers:** each till leases a block of 50 numbers from the database (`claim_invoice_numbers`), so two tills never issue the same number. Numbers can have gaps.
- **Row Level Security** is on for every table. Members only see their own shop.

## Platform console
Sign in with the email you added to `platform_admins`. The console has five tabs:
- **Overview:** monthly revenue estimate (plan price plus extra users, active shops only), active/Pro/Basic counts, plan requests waiting, renewals overdue or due within 7 days, staff accounts, products stored, catalogue size, and new shops per week.
- **Shops:** search and filter (active, suspended, Pro, Basic, due). Open a shop to see its owner, staff list, product and invoice counts, last activity, monthly bill and payment history. You can change plan, set the renewal date, extend 30 days, suspend or reactivate, and keep an internal note that shops never see.
- **Requests:** bank-transfer plan requests with the reference and the amount to expect. Approve or decline.
- **Catalogue:** the master product list. Search, filter (no barcode, in 2+ shops, added this week), sort, edit an entry, merge two entries, remove, import a CSV (`name,barcode,category,unit,gst_type`), download CSV, rebuild from shops.
- **Activity:** an audit log of every plan, status, request and catalogue change, with who did it.

## Known limits
- **Needs internet.** Short drops are retried automatically and the corner badge says *Offline* until changes are saved. Do not close the tab while it shows. There is no full offline mode.
- **Stock on the same product from two tills at the same second:** the last write wins, so a count can drift by one sale. Fix with a stock-adjust function if you expect heavy simultaneous selling.
- Not tested against a live Supabase project or real Google OAuth yet. Do a test sign-up, a staff login and a Google login after deploying.
- Card payments are not connected. Subscriptions are paid by bank transfer and confirmed by the platform admin.
- MIRA 205 report: figures laid out in the box order of the return. It is not the official form and cannot be filed from the app.

## Files
```
public/index.html           the whole app
public/config.js            generated at build from Vercel env vars
public/templates/           product import template (Excel)
supabase/schema.sql         tables, row level security, functions
supabase/functions/create-staff/index.ts   staff sign-in creation
supabase/functions/set-staff-password/index.ts   owner resets a staff password
scripts/make-config.js      writes config.js at build
vercel.json
```
