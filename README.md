# Atoll POS

A point-of-sale system for Maldivian retailers, with Basic and Pro subscription tiers.
Frontend: static site on **Vercel**. Database and auth: **Supabase**.

## What is in this repo

| Path | What it is |
| --- | --- |
| `index.html` | The whole app (HTML, CSS, JS in one file). No build step. |
| `supabase/schema.sql` | Multi-tenant Postgres schema, Row Level Security, plan rules |
| `templates/Atoll-POS-product-template.xlsx` | Excel template for bulk product import |
| `vercel.json` | Static hosting and security headers |

## Current status (read this first)

The app currently keeps its data in the browser (`localStorage`). That is fine for a demo, but it means:

- No sync between devices, no real multi-user sign-in, no backup.
- PINs and the demo admin passcode are checked in the page. **Do not use this for real shops yet.**
- Subscription billing is simulated (no payment gateway).

`supabase/schema.sql` is the target data model. Connecting the frontend to it is the next step (below).

## Features

- Sales: barcode scanner (USB, Bluetooth, camera), variants and sub-variants (Pro), weight-based items (per kg), categories, customer credit, split payments, discounts
- Receipts: thermal 80/58 mm, A5, A4, PDF via print dialog, GST breakdown (total excl. GST, GST, total incl. GST)
- Stock: Excel bulk import, low-stock reorder, purchase orders and suppliers (Pro)
- Money: cashbook, refunds and credit notes (Pro), cash registers with shift counts (Pro)
- Reports: basic sales reports (Basic), profit and GST summary (Pro)
- Team: owner / full access / cashier roles with per-user permissions
- Plans: Basic MVR 129/month (2 users, +MVR 29 per extra user, 3,000 products). Pro MVR 319/month (5 users, +MVR 79 per extra user, unlimited products)
- Platform admin console to change a shop's plan on its behalf

## Deploy

### 1. GitHub

```bash
cd atoll-pos
git init -b main            # skip if this folder already has .git
git add .
git commit -m "Initial commit"
git remote add origin https://github.com/YOUR-USER/atoll-pos.git
git push -u origin main
```

### 2. Vercel

1. Vercel dashboard, **Add New, Project**, import the GitHub repo.
2. Framework preset: **Other**. Build command: none. Output directory: leave empty (root).
3. Deploy. Every push to `main` redeploys.

### 3. Supabase

1. Create a project at supabase.com.
2. **SQL Editor**, paste `supabase/schema.sql`, run.
3. **Authentication, Providers**: enable Email. Turn on **Confirm email** so owners verify their address.
4. Make yourself a platform admin (run once, using your own user id from Authentication, Users):
   ```sql
   insert into platform_admins(user_id) values ('YOUR-AUTH-USER-ID');
   ```
5. Copy the project URL and **anon** key (Project Settings, API) into `.env.example` as a reference. The **service role** key must never go in the frontend or in Git.

## Next step: wire the frontend to Supabase

1. Add `@supabase/supabase-js` (CDN script or bundler) and read `SUPABASE_URL` / `SUPABASE_ANON_KEY`.
2. Replace the owner sign-up screen with Supabase email sign-up, then call `rpc('create_shop', {...})`.
3. Replace `S`/`save()` (localStorage) with queries to `products`, `invoices`, `cashbook` and the other tables.
4. Add a `record_sale` SQL function (security definer) that, in one transaction, inserts the invoice, cashbook rows and customer balance and decrements stock. Cashiers have no direct write access to `products`.
5. Staff accounts: create them with a Supabase Edge Function (service role). Use email and password or magic links for sign-in. Keep the 4-digit PIN only as a quick switch on an already signed-in till, hashed with `crypt()`, never as the only credential.
6. Payments: add a gateway (for example BML or MIB) with a webhook (Edge Function, service role) that sets `shops.plan` and `renews_at`. The `protect_plan_fields` trigger blocks everyone else from changing them.
7. Move the platform admin console behind `is_platform_admin()`; remove the demo passcode.

## Plan rules already enforced in the database

- Basic shops cannot hold more than 3,000 products or create variants.
- Only platform admins or the service role can change `plan`, `status` or `renews_at`.
- Cashiers only see and change what their permissions allow (`has_perm`).

## Local use

Open `index.html` in a browser, or run `npx serve .`. Camera scanning and device pairing need HTTPS (Vercel provides it).
