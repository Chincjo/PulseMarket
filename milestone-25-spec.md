# Milestone 25 — Worldwide + non-student signup (spec, 2026-11-28)

Richard's decision: PulseMarket opens to ordinary people (including parents) in
every country from day one. Students keep the current university flow.
Nothing here is live yet — code first, then SQL, push + live run only with
Richard's approval.

## 1. Account types

- `student` — current university verification, unchanged.
- `ordinary` — new. At signup the user picks "I am a student" or
  "I am not a student". Students keep university + currency lock;
  ordinary users get country + currency lock instead.

## 2. Country & currency

- Every user picks a country at verification.
- App: `COUNTRIES` table in `src/lib/data.js` — ISO code, name, currency
  code, symbol, static NGN reference rate (`ngnRate`, NGN per 1 unit).
  Cover all countries; any unmapped country defaults to USD.
  Anchor rates (static reference, Nov 2026, labelled estimates everywhere):
  NGN 1, USD 1450, GBP 1950, EUR 1680, GHS 90, KES 11, ZAR 84, CAD 1040,
  AUD 940, INR 16.5, XAF 2.9, XOF 2.9. Fill the rest with sane
  approximate rates; never invent a rate as live — always "estimate".
- DB: new table `currency_rates` (currency text PK, symbol text,
  ngn_per_unit numeric not null, updated_at) seeded with the same anchors
  + the same full list; helper `pm_currency_rate(p_currency text)`
  returns ngn_per_unit, falling back to the USD row when unknown (never null).
- `listings`, `orders`, `wallet_ledger` gain `currency text not null
  default 'NGN'`; `listings`/`orders` also gain `country text` (seller
  country, default 'Nigeria') and orders gains `ship_to_country text`.
  Existing rows keep NGN.
- Prices are stored and charged in the SELLER's currency. The buyer sees
  the seller-currency price plus an approximate conversion into their own
  currency, always labelled as an estimate. English only, day one.

## 3. Face verification (ordinary users)

- Selfie photo (in-app camera or upload, required) + full name + country,
  optional government ID photo. Upload to the SAME private
  `verification-ids` bucket as student ID photos (never a public bucket),
  same 10MB cap + real-photo check + different-files check when both
  photos are present.
- Status `pending review`; team approves/rejects in /admin, reusing the
  existing rejection-reason mechanism. New face reasons: `blurry selfie`,
  `face not clear`, `face does not match ID`. Re-submit after rejection
  works like the student flow. Never auto-approve.
- `verifications` gains: `account_type text not null default 'student'
  check (account_type in ('student','ordinary'))`, `country text`,
  `currency text not null default 'NGN'`, `full_name text`,
  `face_photo_url text`, `gov_id_front_url text`.
  `university` / `student_id` lose NOT NULL (ordinary rows have none);
  add a check: student rows need university + student_id; ordinary rows
  need full_name + country + face_photo_url. `invite_code` stays NOT NULL
  (ordinary users get one too — referrals work for everyone).

## 4. Fees — currency-aware, SAME formula in app and DB

NGN constants: flat 150, threshold 5000, cap 2000, secure flat 100.
For currency C with rate R = ngn per 1 unit of C:

- `flatFee = max(1, round(150 / R))`
- `threshold = max(1, round(5000 / R))`
- `cap = max(1, ceil(2000 / R))`
- `secureFlat = max(1, round(100 / R))`
- cash or price 0 → service 0, secure 0.
- else service = price < threshold ? flatFee : min(round(price * 0.05), cap);
  secure = round(price * 0.015) + secureFlat.

Check: NGN → 150 / 5000 / 2000 / 100 (unchanged). USD @1450 → 1 / 3 / 2 / 1:
$100 held → service 2, secure 3, total 105. GBP @1950 → 1 / 3 / 2 / 1:
£100 held → service 2, secure 3, total 105. Cash face-to-face stays NO fee,
always. Seller always keeps the full item price.
- App: `feeBreakdown(price, method, currency='NGN')` in `src/lib/fees.js`;
  add generic `formatMoney(amount, currency)` (keep `formatNaira` as the
  NGN alias); fee labels become currency-aware.
- DB: new `pm_fee_breakdown(p_price integer, p_method text, p_currency text)`
  returning (service_fee, secure_fee); the order-insert trigger (the one
  with the inline fee block, ~line 2720 in milestone-20.sql — find its
  function name) is redefined to call it with `NEW.currency`.

## 5. Shipping — free-text transport, no courier list

- Same-city meetup/cash works anywhere. There is NO courier
  allowlist, NO courier tiers and NO per-transport rule anywhere:
  the seller types the name of the transport for the shipment
  into `orders.courier` — any transport at all ("GIG Logistics",
  "GUO Transport", "God is Good Motors", "Air Peace flight",
  "DHL", ...). An optional plate / flight number goes in the new
  `orders.transport_ref` column. A shipping order is refused only
  when no transport name is given at all; a plate/flight number
  on its own is never enough. A meet-in-person order names no
  transport at all (courier AND transport_ref both null).
- Nigeria keeps the GIG/GUO state zones for the shipping FEE
  (the fee is priced from the ship-to state, never invented).
  Other countries: domestic same-country shipping; fee confirmed
  by the team (app shows 0 + "confirmed by the team", never a
  made-up number).
- International shipping works with any transport the seller
  types. Tracked shipments earn the 50% shipping advance with
  waybill + receipt, exactly like GIG/GUO used to — the advance
  is proof-complete (waybill number + receipt photo on the
  order), regardless of the transport name. No transport is
  excluded from the advance.
- Rider details: the seller may set rider name/phone on their
  own held or shipped order when the order is SAME-CITY
  (ship-to state = the listing's state AND ship-to country =
  the listing's country), regardless of the transport name.
  The team may set rider details any time (except on terminal
  orders), as before.
- Delivery PIN, checkpoints and the 50% shipping advance behave
  exactly as today. Checkpoints are keyed off location (same-city
  vs cross-state vs cross-country), never off a transport name.

## 6. Verification gates

- App.jsx login-first + verification gate accepts an APPROVED student
  verification OR an APPROVED ordinary verification. No approved
  verification of either type → locked out, exactly as today. The gate
  is status-based, so the change is: Verify.jsx must be able to produce
  an ordinary row, and the App.jsx device-copy push-up
  (`local?.university`) must also accept `local?.accountType ===
  'ordinary'`.
- `pm_chat_verification_ok` is already type-agnostic (approved + not
  flagged) — both types pass. Do NOT narrow it; add a test proving an
  approved ordinary verification passes. Any listing-insert verification
  check that assumes a university must be updated to accept both types.

## 7. Meetup spots

- `SAFE_MEETUP_SPOTS` stays campus-specific for students. Ordinary users
  get `GENERIC_MEETUP_SPOTS`: police station, bank branch, shopping
  mall, busy public place, daytime only.

## 8. Admin

- /admin lists BOTH verification types with an account-type badge
  (Student / Ordinary), country + currency for ordinary, university +
  student ID for students. Photo viewer shows selfie (+ gov ID) for
  ordinary, ID front/back for students. Approve confirm text adapts.
  Rejection reasons extended with the three face reasons. Never link
  /admin from the user app.

## 9. Money

- Manual escrow stays the launch bridge. `PULSEMARKET_BANK` is NGN
  Moniepoint only — NEVER invent account numbers. For non-NGN orders,
  checkout shows "the PulseMarket team will share payment details by
  email" (the app already does this when bank details are not ready).

## 10. Search / Home

- Listings show a country badge; Search gains a country filter. No fake
  listings, no sample data, production only.

## Hard rules

- Theme black/white/grey + warm brown (#7d5027) only, no green/lime.
- No admin UI in the user app. Cash = NO fee. Owner email
  pulsemarketsupport@gmail.com / OWNER_EMAIL untouched.
- Code first, then SQL. NEVER run milestone-14..19, milestone-23 or
  milestone-24 on live Supabase (all already live). This milestone's SQL
  runs only after Richard approves, exactly once.
- `npm run build` must pass; lint no NEW errors (baseline 21 warnings /
  0 errors). `milestone-25.sql` idempotent; validate on scratch
  PostgreSQL 16 (chain M3-4 → M24, then M25 twice) + functional tests.
- Do not touch the two-account test listing, rio-8350@muse.ai, or live data.
