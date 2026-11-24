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
