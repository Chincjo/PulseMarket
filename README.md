# PulseMarket

Buy and sell safely with verified students at universities across Nigeria.

Your money stays on hold until you meet, inspect and approve. Cash face-to-face
deals have no fees. Held payments carry a small buyer fee and release only
after the buyer confirms with photo and video.

## Stack

- React + Vite + Tailwind CSS, mobile-first
- Supabase (free tier) for accounts (email + Google), database and storage
- Paystack (test mode until live keys are added after activation)

## Accounts (Milestone 2)

The app is login-first: a signed-out visitor sees only the welcome page, then
the separate sign-up / sign-in pages. The home page, Sell and the rest unlock
only after the account is created AND student verification is submitted.
Set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` (see `.env.example`) in
Vercel → Project → Settings → Environment Variables, and set the Supabase
Site URL to the Vercel URL. Until the keys are set, the welcome page says
accounts are being switched on.

## Verification + real listings (Milestones 3 + 4)

Verification is saved to the server (`verifications` table) as well as on the
device, so it follows a student to any phone they sign in on. Selling
publishes a real listing to Supabase (`listings` table, photos in the
`listing-photos` bucket) — no sample or fake listings anywhere. A listing is
visible to students in the seller's state, and to students in other states
only when the seller ships nationwide. Boost has two tiers (₦500 / 24h,
₦1,000 / 3 days); boost payment is demo until real payments go live.

**Before first use, the owner must run the SQL once:** see
`supabase/README-milestone-3-4.md` — open Supabase → SQL Editor → paste
`supabase/milestone-3-4.sql` → Run. No new environment variables are needed.

## Develop

```sh
npm install
npm run dev
```

## Deploy

Pushes to `main` auto-deploy on Vercel. The live site is
https://pulse-market-nine.vercel.app (also https://pulse-market-yqz8.vercel.app).

## Fees

- Cash face-to-face: **no fees**
- Held / in-app payment: service fee 5% capped at ₦2,000 (flat ₦150 under
  ₦5,000) + secure payment fee 1.5% + ₦100. Seller keeps the full price.
- Money is held until the buyer confirms, with 48-hour auto-release.
