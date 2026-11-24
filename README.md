# PulseMarket

Buy and sell safely with verified students at universities across Nigeria.

Your money stays on hold until you meet, inspect and approve. Cash face-to-face
deals have no fees. Held payments carry a small buyer fee and release only
after the buyer confirms with photo and video.

## Stack

- React + Vite + Tailwind CSS, mobile-first
- Netlify Identity for accounts, Netlify Database for data, Netlify Blobs for
  ID documents and evidence media
- Paystack (test mode until live keys are added after activation)

## Develop

```sh
npm install
npm run dev
```

## Deploy

Pushes to `main` deploy on Netlify (15 credits per production deploy on the
free plan). The live site is https://pulsemarket-app-1c9cef.netlify.app

## Fees

- Cash face-to-face: **no fees**
- Held / in-app payment: service fee 5% capped at ₦2,000 (flat ₦150 under
  ₦5,000) + secure payment fee 1.5% + ₦100. Seller keeps the full price.
- Money is held until the buyer confirms, with 48-hour auto-release.
