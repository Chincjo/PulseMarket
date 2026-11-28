-- =====================================================================
-- PulseMarket — Milestone 25 (worldwide + non-student signup, 2026-11-28)
-- Spec: milestone-25-spec.md. Code first, then SQL; push + live run
-- only with Richard's approval.
-- =====================================================================
-- HOW TO RUN (only after Richard approves, code first then SQL):
--   1. Open the Supabase SQL Editor for project jkvrkhqmzvpiovalhybf.
--   2. Run the CHECKS below first and read the results.
--   3. Paste this whole file and run it ONCE. It is idempotent:
--      every statement is ADD COLUMN IF NOT EXISTS / DO-block guarded
--      / CREATE OR REPLACE / DROP IF EXISTS / INSERT ... ON CONFLICT
--      DO NOTHING, so a second run is safe (it changes nothing the
--      second time and returns "Success. No rows returned").
--   4. Do NOT run milestone-14..19, milestone-23 or milestone-24
--      again — all already live. This file only carries the §1–§8
--      changes below.
--
-- CHECKS (a)–(d) (run these in the same editor, expect 0 rows each):
--   NOTE on run order: checks (a)–(d) read the NEW columns and the
--   NEW pm_fee_breakdown() helper, so on the FIRST run they can only
--   run AFTER this file (or after §1 for (a)–(c) and after §3 for
--   (d)). On any later re-run they can all run BEFORE re-running
--   the file. They are written here, not executed by this file, so
--   a second run still returns "Success. No rows returned".
--   (a) Verifications whose account_type is outside the two types:
--         select user_id, account_type from public.verifications
--         where account_type not in ('student', 'ordinary');
--   (b) Listings / orders / wallet rows with a missing currency
--       (existing rows default to NGN when the columns land):
--         select id from public.listings
--         where currency is null or btrim(currency) = '';
--         select id from public.orders
--         where currency is null or btrim(currency) = '';
--         select id from public.wallet_ledger
--         where currency is null or btrim(currency) = '';
--   (c) Ordinary verifications missing full name, country or selfie:
--         select user_id from public.verifications
--         where account_type = 'ordinary'
--           and (nullif(btrim(coalesce(full_name, '')), '') is null
--             or nullif(btrim(coalesce(country, '')), '') is null
--             or nullif(btrim(coalesce(face_photo_url, '')), '') is null);
--   (d) Orders whose stored fees do not match pm_fee_breakdown()
--       for their currency (NGN fees are unchanged by §3, so
--       pre-M25 orders must already match — expect 0):
--         select o.id, o.code, o.currency, o.item_price,
--                o.payment_method, o.service_fee, o.secure_fee,
--                f.service_fee as expected_service,
--                f.secure_fee as expected_secure
--         from public.orders o
--         cross join lateral public.pm_fee_breakdown(
--           o.item_price, o.payment_method,
--           coalesce(o.currency, 'NGN')) f
--         where o.service_fee <> f.service_fee
--            or o.secure_fee <> f.secure_fee;
--
-- WHAT THIS FILE DOES NOT DO:
--   - It does not change the fee amounts for NGN orders, the theme,
--     manual escrow, or the owner email (pulsemarketsupport@gmail.com).
--   - It does not touch the two-account test listing, rio-8350@muse.ai,
--     or any live data. No statement here rewrites live money.
--   - It does not redefine any milestone-14..19, milestone-23 or
--     milestone-24 object, except where §4/§5 explicitly require a
--     shared function to be redefined (see §4 and §5 notes).
-- =====================================================================


-- ---------------------------------------------------------------------------
-- §1) Account types, country & currency columns.
--   * verifications gains account_type ('student' | 'ordinary'),
--     country, currency, full_name, face_photo_url, gov_id_front_url.
--     university / student_id lose NOT NULL (ordinary rows have
--     none); a CHECK then requires university + student_id for
--     student rows and full_name + country + face_photo_url for
--     ordinary rows. invite_code stays NOT NULL (ordinary users
--     get one too — referrals work for everyone).
--   * listings / orders / wallet_ledger gain currency (NGN default);
--     listings gains country (Nigeria default), orders gains
--     country + ship_to_country. Existing rows keep NGN/Nigeria.
--     (M25 shipping change) orders also gains transport_ref
--     (text, nullable): the plate / flight number for the
--     free-text transport named in orders.courier.
-- ---------------------------------------------------------------------------
alter table public.verifications
  add column if not exists account_type text not null default 'student'
    check (account_type in ('student', 'ordinary'));
alter table public.verifications
  add column if not exists country text;
alter table public.verifications
  add column if not exists currency text not null default 'NGN';
alter table public.verifications
  add column if not exists full_name text;
alter table public.verifications
  add column if not exists face_photo_url text;
alter table public.verifications
  add column if not exists gov_id_front_url text;

alter table public.verifications
  alter column university drop not null;
alter table public.verifications
  alter column student_id drop not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'verifications_account_type_fields_check'
      and conrelid = 'public.verifications'::regclass
  ) then
    alter table public.verifications
      add constraint verifications_account_type_fields_check
      check (
        (account_type = 'student'
          and university is not null
          and student_id is not null)
        or (account_type = 'ordinary'
          and full_name is not null
          and country is not null
          and face_photo_url is not null)
      );
  end if;
end $$;

alter table public.listings
  add column if not exists currency text not null default 'NGN';
alter table public.listings
  add column if not exists country text not null default 'Nigeria';
alter table public.listings
  alter column university drop not null;

-- A listing carries a university (student seller) or a country
-- (ordinary seller, country + state as region text). Which one is
-- required for THIS seller is enforced in pm_validate_listing_
-- insert() (§5), which can read the seller's verification row; a
-- table CHECK cannot see that row, so this CHECK only refuses a
-- listing with neither.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'listings_university_or_country_check'
      and conrelid = 'public.listings'::regclass
  ) then
    alter table public.listings
      add constraint listings_university_or_country_check
      check (university is not null or country is not null);
  end if;
end $$;

alter table public.orders
  add column if not exists currency text not null default 'NGN';
alter table public.orders
  add column if not exists country text;
alter table public.orders
  add column if not exists ship_to_country text;
-- (M25 shipping change) Free-text transport: orders.courier keeps
-- its name but now stores ANY transport name the seller types
-- ("GIG Logistics", "God is Good Motors", "Air Peace flight",
-- "DHL", ... — no allowlist). transport_ref holds the optional
-- plate / flight number for that transport.
alter table public.orders
  add column if not exists transport_ref text;

alter table public.wallet_ledger
  add column if not exists currency text not null default 'NGN';


-- ---------------------------------------------------------------------------
-- §2) currency_rates + pm_currency_rate().
--   Static Nov 2026 reference rates (ESTIMATES, never live rates —
--   the app labels every conversion an estimate). The anchors are
--   spec §2 (NGN 1, USD 1450, GBP 1950, EUR 1680, GHS 90, KES 11,
--   ZAR 84, CAD 1040, AUD 940, INR 16.5, XAF 2.9, XOF 2.9); the
--   rest are sane approximate rates from the same USD anchor.
--   Any unmapped country defaults to USD in the app. RLS is on,
--   public select only; the team updates this table by SQL later
--   (the dashboard runs as postgres, which bypasses RLS). The
--   seed uses ON CONFLICT DO NOTHING so a re-run never overwrites
--   a rate the team has since corrected.
-- ---------------------------------------------------------------------------
create table if not exists public.currency_rates (
  currency text primary key,
  symbol text not null,
  ngn_per_unit numeric not null,
  updated_at timestamptz not null default now()
);

alter table public.currency_rates enable row level security;

drop policy if exists "Anyone reads currency rates" on public.currency_rates;
create policy "Anyone reads currency rates"
  on public.currency_rates for select
  using (true);

insert into public.currency_rates (currency, symbol, ngn_per_unit)
values
  ('NGN', '₦', 1), ('USD', '$', 1450), ('GBP', '£', 1950), ('EUR', '€', 1680),
  ('GHS', '₵', 90), ('KES', 'KSh', 11), ('ZAR', 'R', 84), ('CAD', 'C$', 1040),
  ('AUD', 'A$', 940), ('INR', '₹', 16.5), ('XAF', 'FCFA', 2.9), ('XOF', 'FCFA', 2.9),
  ('AED', 'Dhs', 395), ('AFN', '؋', 21), ('ALL', 'L', 17), ('AMD', '֏', 3.8),
  ('ANG', 'ƒ', 810), ('AOA', 'Kz', 1.6), ('ARS', '$', 1.0), ('AWG', 'ƒ', 810),
  ('AZN', '₼', 853), ('BAM', 'KM', 860), ('BBD', '$', 725), ('BDT', '৳', 12),
  ('BGN', 'лв', 860), ('BHD', 'BD', 3845), ('BIF', 'FBu', 0.5), ('BMD', '$', 1450),
  ('BND', '$', 1120), ('BOB', 'Bs', 210), ('BRL', 'R$', 270), ('BSD', '$', 1450),
  ('BTN', 'Nu', 16.5), ('BWP', 'P', 107), ('BYN', 'Br', 490), ('BZD', '$', 725),
  ('CHF', 'CHF', 1830), ('CLP', '$', 1.55), ('CNY', '¥', 200), ('COP', '$', 0.38),
  ('CRC', '₡', 2.9), ('CUP', '$', 60), ('CVE', '$', 14.5), ('CZK', 'Kč', 69),
  ('DJF', 'Fdj', 8.2), ('DKK', 'kr', 225), ('DOP', '$', 22), ('DZD', 'DA', 11),
  ('EGP', 'E£', 30), ('ERN', 'Nfk', 97), ('ETB', 'Br', 10), ('FJD', '$', 660),
  ('GEL', '₾', 530), ('GMD', 'D', 20), ('GNF', 'FG', 0.17), ('GTQ', 'Q', 188),
  ('HKD', '$', 186), ('HNL', 'L', 55), ('HTG', 'G', 11), ('HUF', 'Ft', 4.1),
  ('IDR', 'Rp', 0.09), ('ILS', '₪', 430), ('IQD', 'ID', 1.1), ('IRR', '﷼', 0.03),
  ('ISK', 'kr', 10.5), ('JMD', '$', 9.3), ('JOD', 'JD', 2045), ('JPY', '¥', 9.4),
  ('KHR', '៛', 0.36), ('KMF', 'CF', 3.4), ('KPW', '₩', 1.6), ('KRW', '₩', 1.0),
  ('KWD', 'KD', 4700), ('KZT', '₸', 2.9), ('LAK', '₭', 0.07), ('LBP', 'LL', 0.02),
  ('LKR', 'Rs', 4.8), ('LRD', '$', 7.2), ('LSL', 'L', 84), ('LYD', 'LD', 26),
  ('MAD', 'DH', 145), ('MDL', 'L', 85), ('MGA', 'Ar', 0.33), ('MKD', 'ден', 27),
  ('MMK', 'K', 0.7), ('MNT', '₮', 0.4), ('MOP', 'MOP$', 181), ('MRU', 'UM', 34),
  ('MUR', 'Rs', 31), ('MVR', 'Rf', 94), ('MWK', 'MK', 0.85), ('MXN', '$', 82),
  ('MYR', 'RM', 350), ('MZN', 'MT', 23), ('NAD', '$', 84), ('NIO', 'C$', 40),
  ('NOK', 'kr', 143), ('NPR', 'Rs', 10.3), ('NZD', '$', 850), ('OMR', 'RO', 3765),
  ('PAB', 'B/.', 1450), ('PEN', 'S/', 410), ('PGK', 'K', 380), ('PHP', '₱', 25),
  ('PKR', 'Rs', 5.2), ('PLN', 'zł', 400), ('PYG', '₲', 0.2), ('QAR', 'QR', 398),
  ('RON', 'lei', 330), ('RSD', 'дин', 14.5), ('RUB', '₽', 18), ('RWF', 'FRw', 1.0),
  ('SAR', 'SR', 386), ('SBD', '$', 175), ('SCR', 'Rs', 100), ('SDG', 'SD', 2.4),
  ('SEK', 'kr', 152), ('SGD', '$', 1110), ('SHP', '£', 1950), ('SLE', 'Le', 64),
  ('SLL', 'Le', 64), ('SOS', 'Sh', 0.03), ('SRD', '$', 36), ('SSP', '£', 0.3),
  ('STN', 'Db', 58), ('SYP', '£', 0.11), ('SZL', 'L', 84), ('THB', '฿', 45),
  ('TJS', 'SM', 150), ('TMT', 'T', 415), ('TND', 'DT', 490), ('TOP', 'T$', 610),
  ('TRY', '₺', 34), ('TTD', '$', 214), ('TWD', '$', 47), ('TZS', 'TSh', 0.58),
  ('UAH', '₴', 34), ('UGX', 'USh', 0.4), ('UYU', '$', 36), ('UZS', 'so''m', 0.12),
  ('VES', 'Bs', 6.6), ('VND', '₫', 0.06), ('VUV', 'VT', 12), ('WST', 'T', 520),
  ('YER', 'YR', 5.8), ('ZMW', 'K', 65), ('ZWG', '$', 56)
on conflict (currency) do nothing;

-- pm_currency_rate(): NGN per 1 unit of the currency. Falls back
-- to the USD row when unknown, and to the 1450 anchor if the table
-- is somehow empty — it NEVER returns null, so fee and tier maths
-- below can never divide by null.
create or replace function public.pm_currency_rate(p_currency text)
returns numeric
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(
    (select ngn_per_unit from public.currency_rates
     where currency = upper(btrim(coalesce(p_currency, '')))),
    (select ngn_per_unit from public.currency_rates
     where currency = 'USD'),
    1450::numeric
  );
$$;

revoke execute on function public.pm_currency_rate(text) from public;
grant execute on function public.pm_currency_rate(text) to authenticated;


-- ---------------------------------------------------------------------------
-- §3) pm_fee_breakdown(): the fee formula, currency-aware.
--   Spec §4, EXACTLY (same formula as feeBreakdown() in
--   src/lib/fees.js). NGN constants: flat 150, threshold 5000,
--   cap 2000, secure flat 100. For currency C with rate R = NGN
--   per 1 unit of C:
--     flatFee    = max(1, round(150 / R))
--     threshold  = max(1, round(5000 / R))
--     cap        = max(1, ceil(2000 / R))
--     secureFlat = max(1, round(100 / R))
--   cash or price 0 -> (0, 0).
--   else service = price < threshold ? flatFee
--                                : min(round(price * 0.05), cap);
--        secure  = round(price * 0.015) + secureFlat.
--   Verification (worked by hand, not by running):
--     NGN (R=1)        -> 150 / 5000 / 2000 / 100 (unchanged).
--     USD @1450        -> flat round(150/1450)=0 -> 1;
--                          threshold round(5000/1450)=3;
--                          cap ceil(2000/1450)=2;
--                          secureFlat round(100/1450)=0 -> 1.
--                          $100 held -> service min(round(5), 2) = 2,
--                          secure round(1.5) + 1 = 3. Total 105.
--     GBP @1950        -> flat round(150/1950)=0 -> 1;
--                          threshold round(5000/1950)=3;
--                          cap ceil(2000/1950)=2;
--                          secureFlat round(100/1950)=0 -> 1.
--                          £100 held -> service 2, secure 3.
--                          Total 105.
--   Cash face-to-face stays NO fee, always. The seller always
--   keeps the full item price.
-- ---------------------------------------------------------------------------
create or replace function public.pm_fee_breakdown(
  p_price integer, p_method text, p_currency text
)
returns table (service_fee integer, secure_fee integer)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_rate numeric;
  v_flat integer;
  v_threshold integer;
  v_cap integer;
  v_secure_flat integer;
  v_service integer;
  v_secure integer;
begin
  if coalesce(p_method, '') = 'cash' or coalesce(p_price, 0) = 0 then
    return query select 0, 0;
    return;
  end if;
  v_rate := public.pm_currency_rate(p_currency);
  v_flat := greatest(1, round(150 / v_rate)::integer);
  v_threshold := greatest(1, round(5000 / v_rate)::integer);
  v_cap := greatest(1, ceil(2000 / v_rate)::integer);
  v_secure_flat := greatest(1, round(100 / v_rate)::integer);
  if p_price < v_threshold then
    v_service := v_flat;
  else
    v_service := least(round(p_price * 0.05)::integer, v_cap);
  end if;
  v_secure := round(p_price * 0.015)::integer + v_secure_flat;
  return query select v_service, v_secure;
end;
$$;

revoke execute on function public.pm_fee_breakdown(integer, text, text) from public;
grant execute on function public.pm_fee_breakdown(integer, text, text) to authenticated;


-- ---------------------------------------------------------------------------
-- §4) pm_validate_order_insert(): redefined from Milestone 20
-- (the function containing the inline fee block, ~line 2720 there).
-- ONLY three things change; every other check is verbatim:
--   (1) the inline fee block now calls pm_fee_breakdown() with
--       NEW.currency (the fee-mismatch and total exceptions are
--       verbatim);
--   (2) (M25 shipping change) NO courier allowlist, NO courier
--       tiers, NO Chowdeck checks. orders.courier now stores the
--       FREE-TEXT transport name the seller types — any non-empty
--       text is accepted ("GIG Logistics", "God is Good Motors",
--       "Air Peace flight", "DHL", ...). A shipping order is
--       refused only when no transport name is given at all
--       ('Type the name of the transport for this shipment.').
--       orders.transport_ref (plate / flight number) is optional
--       and may be null; a transport_ref on its own is never
--       enough — the name is what is required. The old tier-1
--       GIG/GUO block and all three Chowdeck blocks are gone, so
--       a high-value order may travel with any transport and any
--       transport may deliver in any state or country. A
--       meet-in-person order still names no transport at all
--       (courier AND transport_ref must both be null).
--   (3) (M25, kept) the shipping-fee zone check, ship_to_state
--       required, and all currency/fee logic are unchanged.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_order_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_listing public.listings%rowtype;
  v_service integer;
  v_secure integer;
begin
  if auth.uid() is null then
    return NEW;
  end if;
  if NEW.status is distinct from 'reserved' then
    raise exception 'A new order always starts as reserved.';
  end if;
  if NEW.buyer_id is distinct from auth.uid() then
    raise exception 'An order can only be placed as yourself.';
  end if;
  if NEW.buyer_id = NEW.seller_id then
    raise exception 'You cannot buy your own listing.';
  end if;
  if NEW.seller_code is not null then
    raise exception 'Seller codes are stored in the handoff table, not on the order.';
  end if;
  if NEW.delivery_pin is not null then
    raise exception 'A new order has no delivery PIN yet.';
  end if;
  if coalesce(NEW.frozen, false) then
    raise exception 'A new order is never frozen.';
  end if;
  if coalesce(NEW.code_attempts, 0) <> 0
    or coalesce(NEW.handoff_locked, false)
    or NEW.handoff_scanned_at is not null
    or NEW.handoff_photo_buyer is not null
    or NEW.handoff_photo_seller is not null
    or coalesce(NEW.buyer_confirmed, false)
    or coalesce(NEW.seller_confirmed, false)
    or coalesce(NEW.shipping_advance_released, false)
    or NEW.return_status is not null
    or NEW.paid_at is not null
    or NEW.held_at is not null
    or NEW.delivered_at is not null
    or NEW.released_at is not null
  then
    raise exception 'A new order cannot already carry handoff, shipping or payment history.';
  end if;

  -- Lock the listing row: two buyers reserving the same item at the
  -- same time now queue here instead of both reading it 'active'.
  -- (The partial unique index in Milestone 15 section 5 is the
  -- backstop — it refuses a second open order for the listing even
  -- if the lock were ever bypassed.)
  select * into v_listing from public.listings where id = NEW.listing_id for update;
  if not found then
    raise exception 'That listing does not exist.';
  end if;
  if v_listing.status <> 'active' then
    raise exception 'This item is no longer available.';
  end if;
  if v_listing.seller_id <> NEW.seller_id then
    raise exception 'That listing belongs to a different seller.';
  end if;

  -- (DB-5) Only a verified, unflagged student can place an order.
  -- The app requires verification before checkout; a direct API
  -- call could otherwise order with no verification row at all.
  if not exists (
    select 1 from public.verifications
    where user_id = NEW.buyer_id
      and status = 'approved'
  ) then
    raise exception 'Only approved students can place an order — verification must be approved first.';
  end if;
  if exists (
    select 1 from public.verifications
    where user_id = NEW.buyer_id and coalesce(flagged, false)
  ) then
    raise exception 'This account is flagged and cannot place orders.';
  end if;

  -- (A c6) Cash is paid face to face, so a cash order can never
  -- ship — shipping proof needs status 'held', which a cash order
  -- never reaches. The app refuses this too; the database is the
  -- backstop.
  if NEW.payment_method = 'cash' and NEW.delivery_method = 'shipping' then
    raise exception 'Cash is paid face to face — choose meet in person.';
  end if;
  -- (M20 M-23) The agreed price is honoured: an item_price
  -- equal to the conversation's agreed_price is accepted when a
  -- conversation exists for this buyer and listing with that
  -- price agreed (0 < agreed <= listing price — the conversation
  -- update trigger already guarantees an agreed price only ever
  -- comes from an accepted offer). Fees below are re-derived
  -- from NEW.item_price, so no fee change is needed.
  if NEW.item_price <> v_listing.price
    and not exists (
      select 1 from public.conversations c
      where c.buyer_id = NEW.buyer_id
        and c.seller_id = NEW.seller_id
        and c.listing_id = NEW.listing_id
        and c.agreed_price = NEW.item_price
        and c.agreed_price > 0
        and c.agreed_price <= v_listing.price
    ) then
    raise exception 'The order price must match the listing price or the price you agreed with the seller.';
  end if;

  -- (F8) The delivery method must be one this listing offers, and a
  -- same_state listing never leaves the seller's state.
  if cardinality(v_listing.delivery_methods) > 0
    and not (NEW.delivery_method = any(v_listing.delivery_methods)) then
    raise exception 'This seller does not offer that delivery method for this item.';
  end if;
  if v_listing.ships_to = 'same_state'
    and NEW.delivery_method = 'shipping'
    and NEW.ship_to_state is distinct from v_listing.state then
    raise exception 'This item only ships within the seller''s state.';
  end if;

  -- (M25) Fees, mirroring feeBreakdown: cash (or a free item) has
  -- no fees; a held order pays what pm_fee_breakdown() derives
  -- from the order currency (NGN constants flat 150, threshold
  -- 5000, cap 2000, secure flat 100, converted through the
  -- currency rate). NGN is unchanged. The fee-mismatch and
  -- total exceptions below are verbatim.
  select f.service_fee, f.secure_fee into v_service, v_secure
  from public.pm_fee_breakdown(
    NEW.item_price, NEW.payment_method, coalesce(NEW.currency, 'NGN')
  ) as f;
  if NEW.service_fee <> v_service or NEW.secure_fee <> v_secure then
    raise exception 'The fees on this order do not match the PulseMarket fee rules.';
  end if;
  if NEW.total <> NEW.item_price + NEW.service_fee + NEW.secure_fee + NEW.shipping_fee then
    raise exception 'The order total does not add up.';
  end if;

  if NEW.delivery_method = 'meetup' then
    if NEW.shipping_fee <> 0 then
      raise exception 'A meet-in-person order has no shipping fee.';
    end if;
    if NEW.meetup_spot is null or btrim(NEW.meetup_spot) = '' then
      raise exception 'Choose a safe meetup spot.';
    end if;
    -- (DB-5) The spot must be one of the app's safe meetup spots,
    -- not any string the caller invents. Students pick a campus
    -- spot (SAFE_MEETUP_SPOTS); ordinary users pick a generic
    -- spot (GENERIC_MEETUP_SPOTS) — both lists are allowed here.
    if NEW.meetup_spot not in ('University main gate', 'Student centre / SUG building', 'Campus library entrance', 'Faculty building lobby', 'Hostel common area (daytime)', 'Police station', 'Bank branch', 'Shopping mall', 'Busy public place (daytime only)') then
      raise exception 'Choose a safe meetup spot from the list.';
    end if;
    if NEW.courier is not null or NEW.transport_ref is not null then
      raise exception 'A meet-in-person order has no transport.';
    end if;
  elsif NEW.delivery_method = 'shipping' then
    -- The fee is priced from the ship-to state, not the buyer's
    -- university state: the parcel goes where ship_to_state says.
    if NEW.shipping_fee <> public.pm_shipping_fee(v_listing.state, NEW.ship_to_state) then
      raise exception 'The shipping fee does not match the zone for the state to ship to.';
    end if;
    if NEW.ship_to_state is null or btrim(NEW.ship_to_state) = '' then
      raise exception 'Choose the state to ship to.';
    end if;
    -- (M25 shipping change) Free-text transport: orders.courier
    -- stores whatever transport name the seller types — any
    -- non-empty text is accepted, there is no allowlist, no
    -- tier and no per-transport rule. Only a missing name is
    -- refused. transport_ref (plate / flight number) is
    -- optional and is never checked here.
    if NEW.courier is null or btrim(NEW.courier) = '' then
      raise exception 'Type the name of the transport for this shipment.';
    end if;
  end if;

  return NEW;
end;
$$;

drop trigger if exists pm_validate_order_insert_trg on public.orders;
create trigger pm_validate_order_insert_trg
  before insert on public.orders
  for each row execute function public.pm_validate_order_insert();


-- ---------------------------------------------------------------------------
-- §5) Verification gates.
--   * pm_chat_verification_ok() is NOT redefined here. It is
--     already type-agnostic: it only asks for an APPROVED row
--     that is not flagged, and never mentions university,
--     student_id or account_type — so an approved ORDINARY
--     verification passes exactly like an approved student one.
--     Both types pass. (Same for pm_validate_conversation_insert
--     and the buyer check inside pm_validate_order_insert: both
--     only ask for status = 'approved'.)
--   * pm_validate_listing_values() (M20) IS redefined below:
--     the university->state check is skipped when NEW.university
--     is NULL (ordinary sellers); the student path is verbatim.
--     Without this, no ordinary seller could post a listing.
--   * pm_validate_listing_insert() (M22 §9) IS redefined below:
--     the approved check accepts either type, the university
--     lock applies to student rows only, and ordinary sellers
--     are locked to their verified country.
--   * pm_validate_verification_insert() (M21 §12) IS redefined
--     below: student rows keep the two-ID-photo checks verbatim;
--     ordinary rows need full_name + country + a selfie
--     (face_photo_url) in the same private 'verification-ids'
--     bucket, with an optional government ID photo.
--   * review_verification() (M19 §3) IS redefined below with
--     the three new face rejection reasons. The rejection-reason
--     column CHECK is extended first, or the RPC could never
--     store a face reason.
--   * pm_validate_verification_update() (M19 §6) IS redefined
--     below: the two photo-assuming checks branch on account
--     type — student rows keep every M19 check verbatim,
--     ordinary rows require the selfie instead. Without this
--     the §7 face RPCs could never succeed (see §5, continued).
-- ---------------------------------------------------------------------------

-- (M25) Extend the rejection_reason column CHECK (M19 §1) with
-- the three face reasons. The old list is kept whole.
alter table public.verifications
  drop constraint if exists verifications_rejection_reason_check;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'verifications_rejection_reason_check'
      and conrelid = 'public.verifications'::regclass
  ) then
    alter table public.verifications
      add constraint verifications_rejection_reason_check
      check (rejection_reason is null
        or rejection_reason in ('blurry', 'wrong document', 'name mismatch', 'expired', 'other', 'blurry selfie', 'face not clear', 'face does not match ID'));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- §9) pm_validate_listing_insert(): a listing must use the seller's verified university.
-- (M25) Redefined: the approved-verification check now accepts
-- EITHER account type; the university lock applies to student
-- rows only, and ordinary sellers are locked to their verified
-- country instead. Every other check is verbatim.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_listing_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return NEW;
  end if;
  if NEW.seller_id is distinct from auth.uid() then
    raise exception 'A listing can only be posted as yourself.';
  end if;
  if not exists (
    select 1 from public.verifications v
    where v.user_id = NEW.seller_id
      and v.status = 'approved'
  ) then
    raise exception 'Only approved users can post a listing — verification must be approved first.';
  end if;
  -- (Milestone 22) The university is locked at verification: a
  -- UNIPORT-verified student used to post as "University of Lagos",
  -- breaking state filtering, same-state rules and shipping zones.
  -- The app refuses it first (createListingRow); this is the
  -- backstop against a direct API call.
  -- (M25) Student rows only: an ordinary seller has no
  -- university, so NEW.university is null for them and must NOT
  -- be compared against a verification row. Ordinary sellers
  -- are locked to their verified country instead (same idea:
  -- country + state as region text).
  if exists (
    select 1 from public.verifications v
    where v.user_id = NEW.seller_id
      and coalesce(v.account_type, 'student') = 'student'
      and v.university is distinct from NEW.university
  ) then
    raise exception 'A listing must use your verified university.';
  end if;
  if exists (
    select 1 from public.verifications v
    where v.user_id = NEW.seller_id
      and v.account_type = 'ordinary'
      and v.country is distinct from NEW.country
  ) then
    raise exception 'A listing must use your verified country.';
  end if;
  -- (M18) A flagged seller cannot post new listings (chat and
  -- orders already refuse flagged accounts).
  if exists (
    select 1 from public.verifications
    where user_id = NEW.seller_id
      and coalesce(flagged, false)
  ) then
    raise exception 'Your account is under review — contact support before posting a new listing.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_listing_insert_trg on public.listings;
create trigger pm_validate_listing_insert_trg
  before insert on public.listings
  for each row execute function public.pm_validate_listing_insert();


-- ---------------------------------------------------------------------------
-- pm_validate_listing_values() (M20): redefined for M25.
--   Root cause (re-validation: 33/36 tests pass, but NO ordinary
--   seller can post a listing): the M20 version unconditionally
--   maps NEW.university through the 20-Nigerian-universities CASE
--   and raises 'Choose your university from the list.' -- and
--   university is NULL for every ordinary seller, so this values
--   trigger vetoed every ordinary listing insert even though
--   pm_validate_listing_insert() (above) already accepts them.
--   The ONLY change from the M20 original is the added
--   NEW.university IS NOT NULL guard on the university->state
--   block: NULL university (ordinary sellers) skips that check
--   entirely; a non-NULL university takes the student path
--   exactly as before. Every other check (price, photos,
--   delivery_methods, category, condition) is verbatim.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_listing_values()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expected_state text;
begin
  if auth.uid() is null then
    return NEW;
  end if;

  if TG_OP = 'INSERT' or NEW.price is distinct from OLD.price then
    if NEW.price is null or NEW.price < 1 or NEW.price > 50000000 then
      raise exception 'Price must be between ₦1 and ₦50,000,000.';
    end if;
  end if;

  -- (M25) A student listing must keep its university: an UPDATE
  -- that deliberately nulls it would otherwise slip past the
  -- NULL-skip branch below (and the section 1 check, since
  -- country defaults to 'Nigeria' and is NOT NULL). Only
  -- reachable by a direct API call -- the app never nulls a
  -- university on update.
  if TG_OP = 'UPDATE' and OLD.university is not null and NEW.university is null then
    raise exception 'A student listing must keep its university.';
  end if;

  -- (M25) Ordinary sellers always have university NULL (student
  -- listings always carry one -- enforced by the listing insert
  -- trigger and the section 1 check), so skip the university->state
  -- mapping for them entirely: their state is free-text region,
  -- and the NOT NULL column constraint already guarantees it is
  -- present. Without this, the CASE below maps NULL to no state
  -- and raises 'Choose your university from the list.', vetoing
  -- every ordinary listing insert. When NEW.university is NOT
  -- NULL the student path below is unchanged.
  if (TG_OP = 'INSERT'
    or NEW.university is distinct from OLD.university
    or NEW.state is distinct from OLD.state)
    and NEW.university is not null then
    -- University -> state, copied exactly from UNIVERSITIES in
    -- src/lib/data.js (universityState() is the app-side mirror).
    v_expected_state := case NEW.university
      when 'University of Port Harcourt' then 'Rivers'
      when 'University of Lagos' then 'Lagos'
      when 'University of Ibadan' then 'Oyo'
      when 'Obafemi Awolowo University' then 'Osun'
      when 'University of Nigeria, Nsukka' then 'Enugu'
      when 'Ahmadu Bello University' then 'Kaduna'
      when 'University of Benin' then 'Edo'
      when 'University of Ilorin' then 'Kwara'
      when 'Lagos State University' then 'Lagos'
      when 'Federal University of Technology, Akure' then 'Ondo'
      when 'Federal University of Technology, Owerri' then 'Imo'
      when 'Federal University of Technology, Minna' then 'Niger'
      when 'Nnamdi Azikiwe University' then 'Anambra'
      when 'University of Calabar' then 'Cross River'
      when 'University of Jos' then 'Plateau'
      when 'Bayero University Kano' then 'Kano'
      when 'Rivers State University' then 'Rivers'
      when 'Delta State University' then 'Delta'
      when 'Enugu State University of Science and Technology' then 'Enugu'
      when 'Covenant University' then 'Ogun'
      else null
    end;
    if v_expected_state is null then
      raise exception 'Choose your university from the list.';
    end if;
    if NEW.state is distinct from v_expected_state then
      raise exception 'The state does not match that university.';
    end if;
  end if;

  if TG_OP = 'INSERT' or NEW.photos is distinct from OLD.photos then
    if NEW.photos is null
      or array_length(NEW.photos, 1) is null
      or array_length(NEW.photos, 1) < 1
      or array_length(NEW.photos, 1) > 4 then
      raise exception 'A listing needs 1 to 4 photos.';
    end if;
    if exists (
      select 1 from unnest(NEW.photos) p where p is null or btrim(p) = ''
    ) then
      raise exception 'A listing needs 1 to 4 photos.';
    end if;
  end if;

  if TG_OP = 'INSERT' or NEW.delivery_methods is distinct from OLD.delivery_methods then
    if NEW.delivery_methods is distinct from array['meetup']::text[]
      and NEW.delivery_methods is distinct from array['shipping']::text[] then
      raise exception 'Choose how the buyer gets it: meet in person or shipping.';
    end if;
  end if;

  if TG_OP = 'INSERT' or NEW.category is distinct from OLD.category then
    if NEW.category is null or NEW.category not in (
      'Phones & gadgets', 'Fashion', 'Books & study', 'Electronics',
      'Home & hostel', 'Beauty & care', 'Sports & fitness',
      'Food & snacks', 'Services', 'Tickets', 'Vehicles', 'Other'
    ) then
      raise exception 'Choose a category from the list.';
    end if;
  end if;

  if TG_OP = 'INSERT' or NEW.condition is distinct from OLD.condition then
    if NEW.condition is null or NEW.condition not in (
      'New', 'Like New', 'Good', 'Fair', 'Spoilt'
    ) then
      raise exception 'Choose a condition from the list.';
    end if;
  end if;

  return NEW;
end;
$$;

drop trigger if exists pm_validate_listing_values_trg on public.listings;
create trigger pm_validate_listing_values_trg
  before insert on public.listings
  for each row execute function public.pm_validate_listing_values();

drop trigger if exists pm_validate_listing_values_update_trg on public.listings;
create trigger pm_validate_listing_values_update_trg
  before update on public.listings
  for each row
  when (
    OLD.price is distinct from NEW.price
    or OLD.university is distinct from NEW.university
    or OLD.state is distinct from NEW.state
    or OLD.photos is distinct from NEW.photos
    or OLD.delivery_methods is distinct from NEW.delivery_methods
    or OLD.category is distinct from NEW.category
    or OLD.condition is distinct from NEW.condition
  )
  execute function public.pm_validate_listing_values();



-- ---------------------------------------------------------------------------
-- §5, continued: pm_validate_verification_insert() (M21 §12).
-- Redefined so an ordinary user can create a verification row at
-- all: the M21 version demanded both student ID photos for every
-- row. Student rows keep every M21 check verbatim; ordinary rows
-- branch to the selfie rules above. All other checks (own row,
-- starts pending review, never flagged, no self-referral, no
-- rejection reason on a new row) are verbatim.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_verification_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or public.pm_is_owner() then
    return NEW;
  end if;
  -- (M21) A verification row belongs to the caller. (RLS already
  -- enforces this; the trigger is the backstop for a direct call.)
  if NEW.user_id is distinct from auth.uid() then
    if coalesce(NEW.account_type, 'student') = 'ordinary' then
      raise exception 'You can only verify your own account.';
    end if;
    raise exception 'You can only verify your own student account.';
  end if;
  if NEW.status is distinct from 'pending review' then
    raise exception 'New verifications always start as pending review.';
  end if;
  if coalesce(NEW.flagged, false) then
    raise exception 'A new verification is never flagged.';
  end if;
  if NEW.referred_by is not null and NEW.invite_code is not null
    and NEW.referred_by = NEW.invite_code then
    raise exception 'You cannot refer yourself.';
  end if;
  -- (M25) Photo rules branch on account type. A student row
  -- must carry both ID photos, in the caller's own folder (bare
  -- storage paths, e.g. '<uid>/front-<ms>.jpg' — see
  -- src/lib/listings.js). The team reviews whatever is stored
  -- here, so a photo-less or fake-URL row must never be created.
  -- An ordinary row carries a selfie instead (face_photo_url,
  -- required) plus an optional government ID photo
  -- (gov_id_front_url); both go to the SAME private
  -- 'verification-ids' bucket, with the same own-folder and
  -- must-exist checks. The table CHECK in M25 §1 enforces
  -- full_name + country + face_photo_url for ordinary rows;
  -- the trigger below also refuses blank strings.
  if coalesce(NEW.account_type, 'student') = 'ordinary' then
    if nullif(btrim(coalesce(NEW.full_name, '')), '') is null
      or nullif(btrim(coalesce(NEW.country, '')), '') is null then
      raise exception 'Add your full name and country to your verification.';
    end if;
    if NEW.face_photo_url is null or btrim(NEW.face_photo_url) = '' then
      raise exception 'Add a selfie photo for face verification.';
    end if;
    if split_part(NEW.face_photo_url, '?', 1) not like auth.uid()::text || '/%' then
      raise exception 'The selfie must be a photo you uploaded from this app.';
    end if;
    if NEW.gov_id_front_url is not null and btrim(NEW.gov_id_front_url) <> '' then
      if split_part(NEW.gov_id_front_url, '?', 1) not like auth.uid()::text || '/%' then
        raise exception 'The ID photo must be a photo you uploaded from this app.';
      end if;
      if NEW.gov_id_front_url = NEW.face_photo_url then
        raise exception 'The selfie and the ID photo must be different files.';
      end if;
    end if;
    if not exists (
        select 1 from storage.objects
        where bucket_id = 'verification-ids'
          and name = split_part(NEW.face_photo_url, '?', 1)
      )
      or (NEW.gov_id_front_url is not null and btrim(NEW.gov_id_front_url) <> ''
        and not exists (
          select 1 from storage.objects
          where bucket_id = 'verification-ids'
            and name = split_part(NEW.gov_id_front_url, '?', 1)
        )) then
      raise exception 'The selfie must be a photo you uploaded from this app.';
    end if;
  else
    if NEW.id_front_url is null or btrim(NEW.id_front_url) = ''
      or NEW.id_back_url is null or btrim(NEW.id_back_url) = '' then
      raise exception 'Add photos of the front and back of your student ID.';
    end if;
    if NEW.id_front_url = NEW.id_back_url then
      raise exception 'The front and back photos must be different files.';
    end if;
    if split_part(NEW.id_front_url, '?', 1) not like auth.uid()::text || '/%'
      or split_part(NEW.id_back_url, '?', 1) not like auth.uid()::text || '/%' then
      raise exception 'The ID photos must be photos you uploaded from this app.';
    end if;
    -- (M21) The path pattern alone proves nothing — the file must
    -- actually exist in the private bucket (the same check resubmit
    -- already does). Without this, a row can point at photos that
    -- were never uploaded and the team can approve a student whose
    -- ID was never seen.
    if not exists (
        select 1 from storage.objects
        where bucket_id = 'verification-ids'
          and name = split_part(NEW.id_front_url, '?', 1)
      )
      or not exists (
        select 1 from storage.objects
        where bucket_id = 'verification-ids'
          and name = split_part(NEW.id_back_url, '?', 1)
      ) then
      raise exception 'The ID photos must be photos you uploaded from this app.';
    end if;
  end if;
  -- (M19) A new verification has no rejection reason or note — a
  -- rejection only ever comes from the team review (§3).
  if NEW.rejection_reason is not null or NEW.rejection_note is not null then
    raise exception 'A new verification has no rejection reason.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_verification_insert_trg on public.verifications;
create trigger pm_validate_verification_insert_trg
  before insert on public.verifications
  for each row execute function public.pm_validate_verification_insert();



-- ---------------------------------------------------------------------------
-- §5, continued: review_verification() (M19 §3).
-- Redefined with the extended rejection-reason list (the three
-- face reasons) and an approval photo check that branches on
-- account type: students still need both ID photos; ordinary
-- users need their selfie. The no-reason refusal, the 280-char
-- note cap, the owner-only gate, and the approve-clears-reason
-- behaviour are all verbatim.
-- ---------------------------------------------------------------------------
drop function if exists public.review_verification(uuid, text);

create or replace function public.review_verification(p_user_id uuid, p_status text, p_reason text default null, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.pm_is_owner() then
    raise exception 'Only the PulseMarket team can review verifications.';
  end if;
  if p_status not in ('approved', 'rejected') then
    raise exception 'A verification can only be approved or rejected.';
  end if;
  if p_user_id is null then
    raise exception 'A verification needs a student.';
  end if;
  -- (M19) A rejection without a reason fails — the student must be
  -- told what to fix. The fixed list matches the column CHECK in
  -- §1 and VERIFICATION_REJECTION_REASONS in src/lib/listings.js.
  -- (M25) Extended with the three face reasons for ordinary
  -- verifications: 'blurry selfie', 'face not clear',
  -- 'face does not match ID'. The column CHECK is extended in
  -- M25 §5 alongside this RPC.
  if p_status = 'rejected' then
    if p_reason is null
      or p_reason not in ('blurry', 'wrong document', 'name mismatch', 'expired', 'other', 'blurry selfie', 'face not clear', 'face does not match ID') then
      raise exception 'A rejection needs a reason: blurry, wrong document, name mismatch, expired, other, blurry selfie, face not clear or face does not match ID.';
    end if;
    if v_note is not null and char_length(v_note) > 280 then
      raise exception 'Keep the note to the student under 280 characters.';
    end if;
  end if;
  -- (M18) Approval needs ID photos to review. Grandfathered rows
  -- are already approved, so they never pass through here again;
  -- a photo-less row must resubmit with photos first.
  -- (M25) Ordinary rows have no student ID photos: approval
  -- needs the selfie (face_photo_url) instead. A government ID
  -- photo is optional for ordinary users, so it is not required
  -- here.
  if p_status = 'approved' then
    if exists (
      select 1 from public.verifications
      where user_id = p_user_id
        and account_type = 'ordinary'
    ) then
      if not exists (
        select 1 from public.verifications
        where user_id = p_user_id
          and nullif(btrim(face_photo_url), '') is not null
      ) then
        raise exception 'That user has no selfie to review — ask them to submit a selfie first.';
      end if;
    elsif not exists (
      select 1 from public.verifications
      where user_id = p_user_id
        and nullif(btrim(id_front_url), '') is not null
        and nullif(btrim(id_back_url), '') is not null
    ) then
      raise exception 'That student has no ID photos to review — ask them to submit photos first.';
    end if;
  end if;
  update public.verifications
    set status = p_status,
        -- (M19) An approval carries no reason or note; a rejection
        -- carries exactly the reason and note given. Either way the
        -- row never keeps a reason from an earlier decision.
        rejection_reason = case when p_status = 'rejected' then p_reason else null end,
        rejection_note = case when p_status = 'rejected' then v_note else null end
    where user_id = p_user_id;
  if not found then
    raise exception 'That student has no verification to review.';
  end if;
end;
$$;

revoke execute on function public.review_verification(uuid, text, text, text) from public;
grant execute on function public.review_verification(uuid, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- §5, continued: pm_validate_verification_update() (M19 §6).
-- Redefined so the §7 face RPCs can succeed on ordinary rows.
-- WHY: resubmit_face_verification() / replace_face_verification_
-- photos() set the pulsemarket.verification_resubmit flag and
-- UPDATE the verifications row, and this trigger fires on that
-- UPDATE. The M19 version required NEW.id_front_url and
-- NEW.id_back_url non-null in its resubmit branch, and ordinary
-- rows have no student ID photos — so the UPDATE raised 'A
-- resubmission needs photos of the front and back of your
-- student ID.' and the face RPCs could never succeed.
-- WHAT CHANGED: only the two places where the trigger assumes
-- student photos now branch on account_type (coalesce(NEW.
-- account_type, 'student')). Student rows keep EVERY M19 check
-- verbatim, including the two-ID-photo requirement and the
-- team-only status/reason rules. Ordinary rows require the
-- selfie (face_photo_url) instead of the two student ID photos
-- (government ID stays optional, own-folder + different-file
-- when given), and otherwise follow the same branch logic. No
-- other check, message or behaviour changes. CREATE OR REPLACE,
-- so a re-run is safe; the trigger itself is re-created below
-- (same name, same timing), matching the M19 file and the other
-- §5 redefinitions.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_verification_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resubmit boolean := coalesce(current_setting('pulsemarket.verification_resubmit', true) = 'true', false);
begin
  if auth.uid() is null or public.pm_is_owner() then
    return NEW;
  end if;
  -- Milestone 17 resubmit path: resubmit_verification() sets the
  -- transaction flag 'pulsemarket.verification_resubmit' (the same
  -- pattern as the handoff flag the flagged check below
  -- recognises), and the RPC itself already checked the caller is
  -- the row owner and the row is 'rejected'. Only exactly rejected
  -- -> 'pending review' may pass here, and only with new ID
  -- photos — every other column is still locked, so university /
  -- student ID / student email / invite code / referral /
  -- chat_verified_only cannot move on a resubmit.
  -- (M19) replace_verification_photos() sets the same flag, and
  -- its RPC already checked the row is 'pending review', so the
  -- branch also allows 'pending review' -> 'pending review' with
  -- new photos — and nothing else. Both RPCs clear the rejection
  -- reason/note, so they must end up null here.
  if v_resubmit then
    if auth.uid() <> OLD.user_id then
      raise exception 'Only the student can resubmit their own verification.';
    end if;
    if OLD.status not in ('rejected', 'pending review') or NEW.status <> 'pending review' then
      raise exception 'A resubmission can only move a rejected or waiting verification back to pending review.';
    end if;
    if NEW.flagged is distinct from OLD.flagged
      or NEW.university is distinct from OLD.university
      or NEW.student_id is distinct from OLD.student_id
      or NEW.student_email is distinct from OLD.student_email
      or NEW.invite_code is distinct from OLD.invite_code
      or NEW.referred_by is distinct from OLD.referred_by
      or NEW.chat_verified_only is distinct from OLD.chat_verified_only
      or NEW.user_id is distinct from OLD.user_id then
      raise exception 'A resubmission can only update the ID photos.';
    end if;
    -- (M25) Photo rules branch on account type. Student rows keep
    -- the M19 checks verbatim (both ID photos, own folder).
    -- Ordinary rows have no student ID photos: the resubmit /
    -- replace needs the selfie (face_photo_url) instead, in the
    -- caller's own folder, and the optional government ID photo
    -- (gov_id_front_url) must be in the caller's own folder and
    -- a different file from the selfie when one is given.
    if coalesce(NEW.account_type, 'student') = 'ordinary' then
      if NEW.face_photo_url is null or btrim(NEW.face_photo_url) = '' then
        raise exception 'A resubmission needs a selfie photo for face verification.';
      end if;
      if split_part(NEW.face_photo_url, '?', 1) not like auth.uid()::text || '/%' then
        raise exception 'The selfie must be a photo you uploaded from this app.';
      end if;
      if NEW.gov_id_front_url is not null and btrim(NEW.gov_id_front_url) <> '' then
        if split_part(NEW.gov_id_front_url, '?', 1) not like auth.uid()::text || '/%' then
          raise exception 'The ID photo must be a photo you uploaded from this app.';
        end if;
        if NEW.gov_id_front_url = NEW.face_photo_url then
          raise exception 'The selfie and the ID photo must be different files.';
        end if;
      end if;
    else
      if NEW.id_front_url is null or btrim(NEW.id_front_url) = ''
        or NEW.id_back_url is null or btrim(NEW.id_back_url) = ''
        or NEW.id_front_url = NEW.id_back_url then
        raise exception 'A resubmission needs photos of the front and back of your student ID.';
      end if;
      if split_part(NEW.id_front_url, '?', 1) not like auth.uid()::text || '/%'
        or split_part(NEW.id_back_url, '?', 1) not like auth.uid()::text || '/%' then
        raise exception 'The ID photos must be photos you uploaded from this app.';
      end if;
    end if;
    -- (M19) A resubmit / replace clears the earlier rejection
    -- reason and note — it must never smuggle a new one in.
    if NEW.rejection_reason is not null or NEW.rejection_note is not null then
      raise exception 'A resubmission clears the earlier rejection reason.';
    end if;
    return NEW;
  end if;
  -- (M18) ID photos can only change through resubmit_verification()
  -- (the branch above, which returns early). A direct update that
  -- swaps the photo URLs is refused — otherwise the resubmit RPC's
  -- own-folder check means nothing.
  -- (M19) Same for replace_verification_photos(): the branch above
  -- is the only way photos change.
  -- (M25) Same branch as above, outside the resubmit flag:
  -- photo URLs can only change through the resubmit / replace
  -- RPCs. Student rows lock the two ID photos; ordinary rows
  -- lock the selfie and the optional government ID photo instead.
  if coalesce(NEW.account_type, 'student') = 'ordinary' then
    if NEW.face_photo_url is distinct from OLD.face_photo_url
      or NEW.gov_id_front_url is distinct from OLD.gov_id_front_url then
      raise exception 'Face verification photos can only be changed by resubmitting your verification or replacing them while under review.';
    end if;
  else
    if NEW.id_front_url is distinct from OLD.id_front_url
      or NEW.id_back_url is distinct from OLD.id_back_url then
      raise exception 'ID photos can only be changed by resubmitting your verification or replacing them while under review.';
    end if;
  end if;
  -- (M19) The rejection reason and note are set only by the team
  -- review RPC (§3). A student writing them directly — e.g. to
  -- fake a rejection, or to wipe a real one — is refused.
  if NEW.rejection_reason is distinct from OLD.rejection_reason
    or NEW.rejection_note is distinct from OLD.rejection_note then
    raise exception 'Only the PulseMarket team can set a rejection reason.';
  end if;
  if NEW.status is distinct from OLD.status then
    raise exception 'Only the PulseMarket team can change a verification status.';
  end if;
  if NEW.flagged is distinct from OLD.flagged
    and not coalesce(current_setting('pulsemarket.handoff_rpc', true) = 'true', false) then
    raise exception 'Only the PulseMarket team can flag an account.';
  end if;
  if NEW.university is distinct from OLD.university
    or NEW.student_id is distinct from OLD.student_id
    or NEW.student_email is distinct from OLD.student_email
  then
    raise exception 'University, student ID and student email cannot be changed after verification is submitted.';
  end if;
  -- (DB-9) Invite codes may be backfilled exactly once: rows created
  -- before invite codes existed have invite_code NULL, and
  -- getOrCreateInviteCode() fills it in. Any other change is refused.
  if NEW.invite_code is distinct from OLD.invite_code
    and OLD.invite_code is not null
  then
    raise exception 'Invite code cannot be changed after verification is submitted.';
  end if;
  if NEW.referred_by is distinct from OLD.referred_by then
    if OLD.referred_by is not null then
      raise exception 'A referral cannot be changed once recorded.';
    end if;
    if NEW.referred_by = NEW.invite_code then
      raise exception 'You cannot refer yourself.';
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_verification_update_trg on public.verifications;
create trigger pm_validate_verification_update_trg
  before update on public.verifications
  for each row execute function public.pm_validate_verification_update();

-- ---------------------------------------------------------------------------
-- §5, continued: resubmit_verification() (M20 §1) and
-- replace_verification_photos() (M19 §4), redefined with an
-- account_type guard. WHY: the M20/M19 student RPCs have NO
-- account_type check, so a rejected ordinary user calling the
-- student resubmit RPC directly would succeed — the M25 update
-- trigger's ordinary resubmit branch only requires the selfie
-- to still be present — bypassing the face flow. The app never
-- calls these RPCs for ordinary rows (it branches to the §7
-- face RPCs), but a direct call must be refused. WHAT CHANGED:
-- exactly one guard in each function, after the caller/row-
-- existence checks and before any UPDATE: an 'ordinary' row
-- raises 'This is for student verifications — ordinary
-- (non-student) verifications use the face verification flow.'
-- Everything else in both functions is the live version
-- verbatim (M20 for resubmit_verification, M19 for
-- replace_verification_photos): same checks, same updates,
-- same messages. CREATE OR REPLACE, so a re-run is safe.
-- ---------------------------------------------------------------------------
create or replace function public.resubmit_verification(p_front_url text, p_back_url text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_front text;
  v_back text;
  v_account_type text;
begin
  if auth.uid() is null then
    raise exception 'Sign in first to resubmit your verification.';
  end if;
  if p_front_url is null or btrim(p_front_url) = ''
    or p_back_url is null or btrim(p_back_url) = '' then
    raise exception 'Add photos of the front and back of your student ID.';
  end if;
  if p_front_url = p_back_url then
    raise exception 'The front and back photos must be different files.';
  end if;
  -- (M18) CRITICAL FIX: the app stores BARE storage paths
  -- ('<uid>/front-<ms>.jpg'), never public URLs — see
  -- src/lib/listings.js. M17's '%verification-ids/<uid>/%' pattern
  -- could never match a bare path, so EVERY resubmit was refused
  -- and a rejected student could never resubmit. The path must
  -- start with the caller's own uid folder, and the object must
  -- actually exist in the private bucket.
  if split_part(p_front_url, '?', 1) not like auth.uid()::text || '/%'
    or split_part(p_back_url, '?', 1) not like auth.uid()::text || '/%'
    or not exists (
      select 1 from storage.objects
      where bucket_id = 'verification-ids'
        and name = split_part(p_front_url, '?', 1)
    )
    or not exists (
      select 1 from storage.objects
      where bucket_id = 'verification-ids'
        and name = split_part(p_back_url, '?', 1)
    ) then
    raise exception 'The ID photos must be photos you uploaded from this app.';
  end if;
  select status, id_front_url, id_back_url, account_type into v_status, v_front, v_back, v_account_type
    from public.verifications
    where user_id = auth.uid();
  if not found then
    raise exception 'You have no verification to resubmit — submit it first.';
  end if;
  -- (M25) Student RPC only: an ordinary row must use the face
  -- verification flow (resubmit_face_verification in §7).
  if v_account_type = 'ordinary' then
    raise exception 'This is for student verifications — ordinary (non-student) verifications use the face verification flow.';
  end if;
  -- (M20) Rejected rows resubmit as before. A pending row resubmits
  -- ONLY when it is missing a photo — the rows M17 let through
  -- without photos. A pending row with both photos uses Replace
  -- photos instead (and, until APP-1 is fixed, the team rejects it
  -- so the student can resubmit normally).
  if v_status = 'pending review' then
    if nullif(btrim(coalesce(v_front, '')), '') is not null
      and nullif(btrim(coalesce(v_back, '')), '') is not null then
      raise exception 'Your photos are already in — use Replace photos while you wait, or wait for the team review.';
    end if;
  elsif v_status <> 'rejected' then
    raise exception 'Only a rejected verification can be resubmitted.';
  end if;
  -- Transaction-local flag (gone at commit) that the update trigger
  -- in section 6 recognises. Set it here, inside the RPC, and
  -- nowhere else: the app cannot set it through PostgREST.
  perform set_config('pulsemarket.verification_resubmit', 'true', true);
  update public.verifications
    set status = 'pending review',
        id_front_url = p_front_url,
        id_back_url = p_back_url,
        -- (M19) A resubmit clears the rejection reason and note.
        rejection_reason = null,
        rejection_note = null
    where user_id = auth.uid();
end;
$$;

revoke execute on function public.resubmit_verification(text, text) from public;
grant execute on function public.resubmit_verification(text, text) to authenticated;

create or replace function public.replace_verification_photos(p_front_url text, p_back_url text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_account_type text;
begin
  if auth.uid() is null then
    raise exception 'Sign in first to replace your ID photos.';
  end if;
  if p_front_url is null or btrim(p_front_url) = ''
    or p_back_url is null or btrim(p_back_url) = '' then
    raise exception 'Add photos of the front and back of your student ID.';
  end if;
  if p_front_url = p_back_url then
    raise exception 'The front and back photos must be different files.';
  end if;
  if split_part(p_front_url, '?', 1) not like auth.uid()::text || '/%'
    or split_part(p_back_url, '?', 1) not like auth.uid()::text || '/%'
    or not exists (
      select 1 from storage.objects
      where bucket_id = 'verification-ids'
        and name = split_part(p_front_url, '?', 1)
    )
    or not exists (
      select 1 from storage.objects
      where bucket_id = 'verification-ids'
        and name = split_part(p_back_url, '?', 1)
    ) then
    raise exception 'The ID photos must be photos you uploaded from this app.';
  end if;
  select status, account_type into v_status, v_account_type
    from public.verifications
    where user_id = auth.uid();
  if not found then
    raise exception 'You have no verification to update — submit it first.';
  end if;
  -- (M25) Student RPC only: an ordinary row must use the face
  -- verification flow (replace_face_verification_photos in §7).
  if v_account_type = 'ordinary' then
    raise exception 'This is for student verifications — ordinary (non-student) verifications use the face verification flow.';
  end if;
  if v_status <> 'pending review' then
    raise exception 'You can only replace your ID photos while your verification is still under review.';
  end if;
  -- Transaction-local flag (gone at commit) that the update trigger
  -- in section 6 recognises. Set it here, inside the RPC, and
  -- nowhere else: the app cannot set it through PostgREST.
  perform set_config('pulsemarket.verification_resubmit', 'true', true);
  update public.verifications
    set status = 'pending review',
        id_front_url = p_front_url,
        id_back_url = p_back_url,
        rejection_reason = null,
        rejection_note = null
    where user_id = auth.uid();
end;
$$;

revoke execute on function public.replace_verification_photos(text, text) from public;
grant execute on function public.replace_verification_photos(text, text) to authenticated;


-- ---------------------------------------------------------------------------
-- §7) Face-verification RPCs for ordinary users (follow-up).
--   Mirrors the student RPCs in m19/02-verification.sql §4–§5
--   (replace_verification_photos / resubmit_verification) exactly,
--   with the student ID photos swapped for the ordinary selfie
--   (+ optional government ID):
--     * replace_face_verification_photos(p_face_path, p_gov_id_path):
--       an ordinary user still 'pending review' swaps their selfie
--       (and gov ID, if one was uploaded) for new ones. Status
--       stays 'pending review' — nothing else moves — and any
--       earlier rejection reason/note is cleared (a pending row
--       should not carry one).
--     * resubmit_face_verification(p_face_path, p_gov_id_path):
--       a REJECTED ordinary user submits a new selfie (+ optional
--       gov ID). Status moves back to 'pending review' and the
--       rejection reason/note are cleared, exactly like the
--       student resubmit.
--   Both: only the signed-in user, for their own row; the row must
--   exist and be account_type 'ordinary' (a student row is refused
--   plainly — students use the student RPCs); the selfie path must
--   be non-null, a bare storage path in the caller's own folder of
--   the private 'verification-ids' bucket, and the object must
--   actually exist there; the gov ID path may be null (gov ID is
--   optional) and, when given, must pass the same own-folder +
--   exists checks and differ from the selfie. Never auto-approve;
--   no other column changes. SECURITY DEFINER, set search_path =
--   public, same as the student RPCs. The same transaction flag
--   ('pulsemarket.verification_resubmit') is set so the update
--   trigger recognises this as the one allowed photo change.
--   Idempotency mirrors the student RPCs: a second identical
--   replace call succeeds (same values re-set, status already
--   'pending review'); a second identical resubmit call is
--   refused ('Only a rejected verification can be resubmitted.')
--   because the first call already moved the row back to
--   'pending review' — same as the student resubmit.
--   NOTE: the gov ID path replaces gov_id_front_url wholesale,
--   so passing null clears a previously stored gov ID. The app
--   (resubmitFaceVerification / replaceFaceVerificationPhotos in
--   src/lib/listings.js) uploads fresh photos on every call and
--   passes null only when no gov ID was uploaded this time, so
--   that matches the app's intent.
--   FIXED (M25 follow-up, §5 above): pm_validate_verification_
--   update() is now redefined in §5 with an ordinary branch
--   (face_photo_url instead of the two student ID photos), so
--   these RPCs' UPDATEs pass the trigger; the scratch-PG16
--   validation step will confirm this.
-- ---------------------------------------------------------------------------
create or replace function public.replace_face_verification_photos(p_face_path text, p_gov_id_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_account_type text;
begin
  if auth.uid() is null then
    raise exception 'Sign in first to replace your face verification photos.';
  end if;
  if p_face_path is null or btrim(p_face_path) = '' then
    raise exception 'Add a selfie photo for face verification.';
  end if;
  if p_gov_id_path is not null and btrim(p_gov_id_path) <> ''
    and p_gov_id_path = p_face_path then
    raise exception 'The selfie and the ID photo must be different files.';
  end if;
  -- (M19, student RPCs verbatim) Bare storage paths
  -- ('<uid>/selfie-<ms>.jpg'), in the caller's own folder, and
  -- the object must actually exist in the private bucket. The
  -- gov ID is optional: its checks run only when one is given.
  if split_part(p_face_path, '?', 1) not like auth.uid()::text || '/%'
    or not exists (
      select 1 from storage.objects
      where bucket_id = 'verification-ids'
        and name = split_part(p_face_path, '?', 1)
    )
    or (p_gov_id_path is not null and btrim(p_gov_id_path) <> ''
      and (split_part(p_gov_id_path, '?', 1) not like auth.uid()::text || '/%'
        or not exists (
          select 1 from storage.objects
          where bucket_id = 'verification-ids'
            and name = split_part(p_gov_id_path, '?', 1)
        ))) then
    raise exception 'The selfie must be a photo you uploaded from this app.';
  end if;
  select status, account_type into v_status, v_account_type
    from public.verifications
    where user_id = auth.uid();
  if not found then
    raise exception 'You have no verification to update — submit it first.';
  end if;
  if coalesce(v_account_type, 'student') <> 'ordinary' then
    raise exception 'This is for ordinary (non-student) verifications — student verifications use the student photo flow.';
  end if;
  if v_status <> 'pending review' then
    raise exception 'You can only replace your face verification photos while your verification is still under review.';
  end if;
  -- Transaction-local flag (gone at commit) that the update trigger
  -- recognises. Set it here, inside the RPC, and nowhere else: the
  -- app cannot set it through PostgREST. (Same flag as the student
  -- RPCs in m19/02-verification.sql §4–§5.)
  perform set_config('pulsemarket.verification_resubmit', 'true', true);
  update public.verifications
    set status = 'pending review',
        face_photo_url = p_face_path,
        gov_id_front_url = p_gov_id_path,
        rejection_reason = null,
        rejection_note = null
    where user_id = auth.uid();
end;
$$;

revoke execute on function public.replace_face_verification_photos(text, text) from public;
grant execute on function public.replace_face_verification_photos(text, text) to authenticated;

create or replace function public.resubmit_face_verification(p_face_path text, p_gov_id_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_account_type text;
begin
  if auth.uid() is null then
    raise exception 'Sign in first to resubmit your verification.';
  end if;
  if p_face_path is null or btrim(p_face_path) = '' then
    raise exception 'Add a selfie photo for face verification.';
  end if;
  if p_gov_id_path is not null and btrim(p_gov_id_path) <> ''
    and p_gov_id_path = p_face_path then
    raise exception 'The selfie and the ID photo must be different files.';
  end if;
  -- (M19, student RPCs verbatim) Bare storage paths
  -- ('<uid>/selfie-<ms>.jpg'), in the caller's own folder, and
  -- the object must actually exist in the private bucket. The
  -- gov ID is optional: its checks run only when one is given.
  if split_part(p_face_path, '?', 1) not like auth.uid()::text || '/%'
    or not exists (
      select 1 from storage.objects
      where bucket_id = 'verification-ids'
        and name = split_part(p_face_path, '?', 1)
    )
    or (p_gov_id_path is not null and btrim(p_gov_id_path) <> ''
      and (split_part(p_gov_id_path, '?', 1) not like auth.uid()::text || '/%'
        or not exists (
          select 1 from storage.objects
          where bucket_id = 'verification-ids'
            and name = split_part(p_gov_id_path, '?', 1)
        ))) then
    raise exception 'The selfie must be a photo you uploaded from this app.';
  end if;
  select status, account_type into v_status, v_account_type
    from public.verifications
    where user_id = auth.uid();
  if not found then
    raise exception 'You have no verification to resubmit — submit it first.';
  end if;
  if coalesce(v_account_type, 'student') <> 'ordinary' then
    raise exception 'This is for ordinary (non-student) verifications — student verifications use the student photo flow.';
  end if;
  if v_status <> 'rejected' then
    raise exception 'Only a rejected verification can be resubmitted.';
  end if;
  -- Transaction-local flag (gone at commit) that the update trigger
  -- recognises. Set it here, inside the RPC, and nowhere else: the
  -- app cannot set it through PostgREST. (Same flag as the student
  -- RPCs in m19/02-verification.sql §4–§5.)
  perform set_config('pulsemarket.verification_resubmit', 'true', true);
  update public.verifications
    set status = 'pending review',
        face_photo_url = p_face_path,
        gov_id_front_url = p_gov_id_path,
        -- (M19) A resubmit clears the rejection reason and note.
        rejection_reason = null,
        rejection_note = null
    where user_id = auth.uid();
end;
$$;

revoke execute on function public.resubmit_face_verification(text, text) from public;
grant execute on function public.resubmit_face_verification(text, text) to authenticated;


-- ---------------------------------------------------------------------------
-- §8) Free-text transport (shipping change, 2026-11-28 — Richard's
-- decision: REMOVE the courier selection entirely, replace it with
-- free-text fields). No courier allowlist, no courier tiers, no
-- Chowdeck checks anywhere in this file any more (see §4).
--   * pm_validate_ledger_insert(): redefined from milestone-24
--     §1 (the LATEST definition — milestone-23's version is
--     superseded by it). EXACTLY ONE change, everything else
--     verbatim M24: the shipping-advance courier allowlist gate
--     is REMOVED. The advance is now proof-complete only: seller
--     or team, held order shipped/delivered, waybill number +
--     receipt photo on the order (checked just below the removed
--     gate), exactly half the shipping fee — REGARDLESS of the
--     transport name in orders.courier.
--   * pm_validate_order_update(): redefined from milestone-24
--     §2–§5 (the LATEST definition — milestone-23's version is
--     superseded by it; m19/03's Chowdeck branch and the
--     milestone-15 flag gate it came from are both inside this
--     text). EXACTLY TWO changes, everything else verbatim M24:
--     (a) the shipping-advance flag gate (§9) drops the
--     courier-membership test — the flag may be set when the
--     seller, shipped/delivered, waybill + receipt present, and
--     the available shipping_advance leg exists, REGARDLESS of
--     transport name; (b) the rider-details branch (§11): the
--     seller may set rider_name/rider_phone on their own order
--     while held/shipped when the order is SAME-CITY
--     (ship_to_state = listing state AND ship_to_country =
--     listing country, looked up inside the function) instead of
--     OLD.courier = 'Chowdeck Relay'. Team rules unchanged.
--   CREATE OR REPLACE only, like milestone-24: the triggers
--   already exist, so no trigger statements are needed. A second
--   run is safe.
-- ---------------------------------------------------------------------------

create or replace function public.pm_validate_ledger_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_advance integer := 0;
  v_half integer := 0;
  v_held_sum integer := 0;
  v_owed integer := 0;
  v_avail_sum integer := 0;
begin
  if auth.uid() is null then
    return NEW;
  end if;

  if NEW.kind in ('hold', 'release', 'shipping_advance', 'refund')
    and NEW.order_id is null then
    raise exception 'A % ledger entry needs an order.', NEW.kind;
  end if;

  if NEW.order_id is not null then
    -- (F4) Lock the order row first: every sum read below (advance,
    -- held sum, owed debt) is then taken after the lock, so two
    -- concurrent money moves for this order queue here and the
    -- second one sees the first one's committed rows. The app's
    -- paired insert holds the lock for both of its rows (same
    -- transaction), and auto_release_overdue_orders() already holds
    -- it (FOR UPDATE SKIP LOCKED) — re-locking in the same
    -- transaction is a no-op.
    select * into v_order from public.orders where id = NEW.order_id for update;
    if not found then
      raise exception 'That order does not exist.';
    end if;
    -- Shipping advance already paid out for this order.
    select coalesce(sum(amount), 0) into v_advance
    from public.wallet_ledger
    where order_id = NEW.order_id
      and kind = 'shipping_advance'
      and bucket = 'available';
  end if;

  -- Frozen money does not move: the team resolves the dispute first.
  if NEW.kind in ('hold', 'release', 'shipping_advance', 'refund', 'debt')
    and NEW.order_id is not null
    and coalesce(v_order.frozen, false) then
    raise exception 'This order is frozen — a dispute is open. The PulseMarket team resolves it first.';
  end if;

  if NEW.kind = 'hold' then
    if not public.pm_is_owner() then
      raise exception 'Only the PulseMarket team can hold money for an order.';
    end if;
    if v_order.payment_method <> 'held' then
      raise exception 'Cash orders never hold money.';
    end if;
    -- (F11) A hold is the team confirming the buyer's transfer
    -- arrived, which only ever happens while the order is 'paid'.
    if v_order.status <> 'paid' then
      raise exception 'A hold can only be recorded once the buyer has marked the order paid.';
    end if;
    if NEW.user_id <> v_order.seller_id or NEW.bucket <> 'held'
      or NEW.amount <> v_order.total then
      raise exception 'A hold must put the order total in the seller''s held bucket.';
    end if;
  elsif NEW.kind = 'release' then
    -- (DB-1a) Only the buyer, the team, or the seller after 48h can
    -- release held money. Without this, the seller could insert
    -- the two release rows themselves while the order is still
    -- 'held' and take the money before delivery — the trigger only
    -- checked amounts and status, never who was writing. The seller
    -- branch mirrors the order-update trigger (48h auto-release
    -- only). The buyer-fault remaining-shipping leg is written by
    -- the team, so pm_is_owner() covers it.
    -- (Milestone 24) The seller branch also covers a 'released'
    -- order: release_order() completes a half-move there, and the
    -- bucket branches below only ever allow the exact missing
    -- completion leg on a released order, so a seller still cannot
    -- write anything else. The 48h gate still applies.
    if not (auth.uid() = v_order.buyer_id or public.pm_is_owner()
      or (auth.uid() = v_order.seller_id and v_order.status in ('delivered', 'released')
          and v_order.delivered_at is not null
          and v_order.delivered_at <= now() - interval '48 hours')) then
      raise exception 'Only the buyer, the PulseMarket team, or the seller after 48 hours can release held money.';
    end if;
    if v_order.payment_method <> 'held' then
      raise exception 'Cash orders never release held money.';
    end if;
    if NEW.user_id <> v_order.seller_id then
      raise exception 'A release pays the seller of the order.';
    end if;
    if not exists (
      select 1 from public.wallet_ledger
      where order_id = NEW.order_id and kind = 'hold' and bucket = 'held'
    ) then
      raise exception 'A release needs the money to be held first.';
    end if;
    if NEW.bucket = 'held' then
      -- (Milestone 23) A release held leg is also allowed on a
      -- 'released' order when it completes a missing leg — the
      -- available leg is already there with the right amount
      -- (release_order §4a verifies it before writing). Any other
      -- released-order release is still refused.
      if v_order.status <> 'delivered'
        and not (
          v_order.status = 'released'
          and exists (
            select 1 from public.wallet_ledger
            where order_id = NEW.order_id and kind = 'release' and bucket = 'available'
              and amount = greatest(v_order.item_price + v_order.shipping_fee - v_advance, 0)
          )
        ) then
        raise exception 'A release can only be written once delivery is confirmed.';
      end if;
      if coalesce(v_order.return_status, '') = 'opened' then
        raise exception 'A return is open — the held money cannot be released.';
      end if;
      if NEW.amount <> -(v_order.total - v_advance) then
        raise exception 'A release must take exactly what is still held (total minus any advance already paid).';
      end if;
    elsif NEW.bucket = 'available' then
      -- The full release, or the remaining-shipping leg of a
      -- buyer-fault return (the buyer gets the item price back, the
      -- seller keeps the rest of the shipping fee).
      if NEW.amount = greatest(v_order.item_price + v_order.shipping_fee - v_advance, 0)
        and coalesce(v_order.return_status, '') <> 'opened' then
        -- (Milestone 23) Same completion allowance as the held leg
        -- above: a 'released' order may gain its missing available
        -- leg when the held leg is already there with the right
        -- amount (release_order §4a verifies it first).
        if v_order.status <> 'delivered'
          and not (
            v_order.status = 'released'
            and exists (
              select 1 from public.wallet_ledger
              where order_id = NEW.order_id and kind = 'release' and bucket = 'held'
                and amount = -(v_order.total - v_advance)
            )
          ) then
          raise exception 'A release can only be written once delivery is confirmed.';
        end if;
        if not exists (
          select 1 from public.wallet_ledger
          where order_id = NEW.order_id and kind = 'release' and bucket = 'held'
        ) then
          raise exception 'A release to the seller needs its held leg first.';
        end if;
      elsif coalesce(v_order.return_status, '') = 'opened'
        and NEW.amount = greatest(v_order.shipping_fee - v_advance, 0) then
        -- Buyer-fault return leg: written while the order is still
        -- shipped or delivered, as part of resolving the return.
        if v_order.status not in ('shipped', 'delivered') then
          raise exception 'The remaining-shipping leg can only be written while the order is shipped or delivered.';
        end if;
        if not exists (
          select 1 from public.wallet_ledger
          where order_id = NEW.order_id and kind = 'refund' and bucket = 'held'
        ) then
          raise exception 'The remaining-shipping leg needs the refund held leg first.';
        end if;
        -- (Milestone 24) This leg is the buyer-fault remainder
        -- ONLY: on a seller-fault return the buyer is refunded the
        -- FULL total (shipping included), so paying the seller the
        -- shipping remainder too would conjure money from nothing.
        -- And the buyer's refund must already be written — the old
        -- check only required the held leg, so in the window after
        -- the refund legs were written but before the order flipped
        -- to refunded, a seller-fault return could still take this
        -- leg (a seller after 48h on a delivered order passes the
        -- release actor check above).
        if v_order.return_reason not like 'Buyer fault%' then
          raise exception 'The remaining-shipping leg is only for a buyer-fault return.';
        end if;
        if not exists (
          select 1 from public.wallet_ledger
          where order_id = NEW.order_id and kind = 'refund' and bucket = 'available'
        ) then
          raise exception 'The remaining-shipping leg needs the buyer refund first.';
        end if;
      else
        raise exception 'A release must pay the seller exactly the item price plus the shipping fee, minus any advance already paid.';
      end if;
    else
      raise exception 'A release moves money between held and available only.';
    end if;
  elsif NEW.kind = 'shipping_advance' then
    -- (DB-1d) Only the seller (or the team fixing a record) can
    -- claim the shipping advance. The trigger already checks the
    -- row pays the seller; this checks who is writing it.
    if auth.uid() <> v_order.seller_id and not public.pm_is_owner() then
      raise exception 'Only the seller can claim the shipping advance.';
    end if;
    if v_order.payment_method <> 'held' or v_order.status not in ('shipped', 'delivered') then
      raise exception 'A shipping advance is only paid once the order has shipped.';
    end if;
    -- (M25 shipping change) No courier allowlist any more: the
    -- advance is proof-complete only. Any transport name earns it
    -- once the waybill number + receipt photo are on the order
    -- (checked just below) — the old allowlist check is gone.
    -- A meet-in-person order can never reach here with a real
    -- advance anyway: its shipping fee is 0, so the only legs it
    -- could ever write are a pair of 0 rows.
    -- The proof must already be on the order: the app saves the
    -- waybill number + receipt photo and ships the order first, so
    -- an advance with no proof behind it is refused here.
    if v_order.waybill_number is null or btrim(v_order.waybill_number) = ''
      or v_order.receipt_photo is null then
      raise exception 'A shipping advance needs the waybill number and receipt photo on the order.';
    end if;
    if NEW.user_id <> v_order.seller_id then
      raise exception 'A shipping advance pays the seller of the order.';
    end if;
    v_half := v_order.shipping_fee / 2;
    if NEW.bucket = 'held' and NEW.amount <> -v_half then
      raise exception 'A shipping advance moves exactly half the shipping fee out of hold.';
    elsif NEW.bucket = 'available' then
      if NEW.amount <> v_half then
        raise exception 'A shipping advance pays exactly half the shipping fee.';
      end if;
      if not exists (
        select 1 from public.wallet_ledger
        where order_id = NEW.order_id and kind = 'shipping_advance' and bucket = 'held'
      ) then
        raise exception 'A shipping advance to the seller needs its held leg first.';
      end if;
    elsif NEW.bucket not in ('held', 'available') then
      raise exception 'A shipping advance moves money between held and available only.';
    end if;
  elsif NEW.kind = 'refund' then
    -- (M20 D-3 / M-1 — READ THIS BEFORE CHANGING THE AMOUNTS
    -- BELOW.) A buyer who is refunded loses NOTHING when the
    -- seller is at fault (seller-fault return: FULL total), and
    -- the books must still balance. A TEAM refund with no return
    -- open is different: the buyer gets item + shipping back and
    -- the fees stay with PulseMarket (owner decision 2026-11-26).
    -- The old amounts created money whenever a shipping advance
    -- had been paid: the buyer leg paid item + shipping in full
    -- (8,500) while the seller KEPT the advance (1,750) with no
    -- debt recorded — 8,500 + 1,750 = 10,250 out of 8,925 held,
    -- so 1,325 naira was conjured out of nothing on a 5,000 /
    -- 3,500 order with a 1,750 advance. The fixed leg design is:
    --   * refund held leg, seller: -(total - advance)
    --   * refund available leg, buyer: +total for a seller-fault
    --     return (the FULL total, fees included); +(item_price +
    --     shipping_fee) for a team refund with no return open
    --     (NOT the total, NOT total - advance)
    --   * seller debt leg, seller available: -advance (kind
    --     'debt', written by the team via recordSellerDebt; skip
    --     it when advance = 0)
    -- The buyer nets the refund amount; the seller nets 0
    -- (advance received, then owed straight back); the hold
    -- drains to 0; on a team refund the fee stays with
    -- PulseMarket.
    -- WHY THERE IS NO SEPARATE +advance BUYER LEG: the
    -- wallet_ledger_one_refund_idx unique index allows exactly
    -- ONE 'refund' row per (order, bucket), so a second
    -- buyer-available refund row and a seller-available refund
    -- row can never exist — the +advance is folded into the
    -- buyer's leg instead (+total on a seller-fault return,
    -- +item + shipping on a team refund), and the clawback rides
    -- on the existing 'debt' kind (one debt per order, draft §2
    -- index), which is exactly what resolveReturn already
    -- records. The net money movement is identical to the
    -- four-leg sketch (held -(total-advance); buyer +(refund
    -- amount - advance); seller -advance; buyer +advance) —
    -- only the row shape differs.
    -- Buyer-fault is unchanged and already balances: refund
    -- available pays the buyer the item price only, and the
    -- 'release' remaining-shipping leg pays the seller
    -- (shipping - advance), so the buyer nets
    -- item + shipping - advance and the seller keeps the advance.
    -- (DB-2) Cash orders never hold money, so they can never refund
    -- through the ledger. A cash return is sorted out face to face.
    if v_order.payment_method <> 'held' then
      raise exception 'Cash orders never refund through the ledger.';
    end if;
    -- (DB-1b) A refund while a return is open is the team's job:
    -- the buyer opens the return, the team adjudicates fault. A
    -- buyer inserting refund rows directly could pick 'Seller
    -- fault' and pay themselves in full with no adjudication. (A
    -- cancel reversal from reserved/paid has no return open, so it
    -- is unaffected.)
    if coalesce(v_order.return_status, '') = 'opened' and not public.pm_is_owner() then
      raise exception 'Only the PulseMarket team can write a refund while a return is open.';
    end if;
    if NEW.bucket = 'held' then
      if NEW.user_id <> v_order.seller_id
        or NEW.amount <> -(v_order.total - v_advance) then
        raise exception 'A refund must take exactly what is still held (total minus any advance already paid).';
      end if;
      -- Either a return is open (the normal refund), or the order
      -- is still reserved/paid and the hold is being reversed on
      -- cancellation — or (F2) the team is refunding a held order
      -- the seller never shipped, with no return open.
      if coalesce(v_order.return_status, '') <> 'opened'
        and v_order.status not in ('reserved', 'paid')
        and not (public.pm_is_owner() and v_order.status in ('held', 'shipped', 'delivered')) then
        raise exception 'A refund out of hold needs an open return, or a team refund of a held, shipped or delivered order.';
      end if;
    elsif NEW.bucket = 'available' then
      if public.pm_is_owner() and v_order.status in ('held', 'shipped', 'delivered')
        and coalesce(v_order.return_status, '') <> 'opened' then
        -- (F2) Team refund with no return open (refundHeldOrder):
        -- owner decision 2026-11-26 — team refunds KEEP the fee:
        -- the buyer gets item + shipping back, NOT the total. A
        -- held order never shipped has no advance; on a
        -- shipped/delivered order the app must also record the
        -- shipping advance as a seller debt (recordSellerDebt,
        -- -advance) so the seller does not keep money the buyer
        -- was refunded — see the M-1 note at the top of the
        -- refund branch. No return is open, so the fault-amount
        -- rules below do not apply.
        if NEW.user_id <> v_order.buyer_id
          or NEW.amount <> v_order.item_price + v_order.shipping_fee then
          raise exception 'A team refund pays the buyer the item price plus the shipping fee — the fees stay with PulseMarket.';
        end if;
      else
        if coalesce(v_order.return_status, '') <> 'opened' then
          raise exception 'A refund to the buyer needs an open return.';
        end if;
        if v_order.status not in ('shipped', 'delivered') then
          raise exception 'A refund to the buyer can only be written once the order has shipped.';
        end if;
        if NEW.user_id <> v_order.buyer_id then
          raise exception 'A refund pays the buyer of the order.';
        end if;
        if v_order.return_reason like 'Seller fault%' then
          -- (M20 D-3 / M-1) The buyer gets the FULL total back,
          -- fees included. The amount is the total — NOT
          -- item + shipping and NOT total - advance (the advance
          -- is clawed back separately as a seller debt; see the
          -- note at the top of the refund branch).
          if NEW.amount <> v_order.total then
            raise exception 'A seller-fault refund pays the buyer the order total in full.';
          end if;
        elsif v_order.return_reason like 'Buyer fault%' then
          if NEW.amount <> v_order.item_price then
            raise exception 'A buyer-fault refund pays the buyer the item price only.';
          end if;
        else
          raise exception 'A refund to the buyer needs a return reason that says whose fault it is.';
        end if;
      end if;
      if not exists (
        select 1 from public.wallet_ledger
        where order_id = NEW.order_id and kind = 'refund' and bucket = 'held'
      ) then
        raise exception 'A refund to the buyer needs its held leg first.';
      end if;
    else
      raise exception 'A refund moves money between held and available only.';
    end if;
  elsif NEW.kind = 'debt' then
    if not public.pm_is_owner() then
      raise exception 'Only the PulseMarket team can record a seller debt.';
    end if;
    if NEW.order_id is not null and NEW.user_id <> v_order.seller_id then
      raise exception 'A seller debt belongs to the seller of the order.';
    end if;
    if NEW.bucket <> 'available' or NEW.amount >= 0 then
      raise exception 'A seller debt is a negative available entry.';
    end if;
  elsif NEW.kind = 'repayment' then
    -- (DB-1c) A repayment is the team recording money the seller
    -- paid back. A seller writing repayment rows for themselves
    -- would clear their own debt with no payment — and no app code
    -- ever writes a repayment, so a direct API insert is currently
    -- the only way one appears.
    if not public.pm_is_owner() then
      raise exception 'Only the PulseMarket team can record a repayment.';
    end if;
    if NEW.order_id is null then
      raise exception 'A repayment needs an order.';
    end if;
    if NEW.user_id <> v_order.seller_id then
      raise exception 'A repayment belongs to the seller who owed the debt.';
    end if;
    -- (Milestone 22) A repayment settles the debt WITHOUT crediting
    -- the seller's withdrawable balance, so it lives in the
    -- 'settled' bucket, never 'available'. The old rule wrote it as
    -- a positive 'available' entry: after a seller-fault refund the
    -- seller's available balance is advance (+1,750) + debt (-1,750)
    -- = 0, and recording the genuine 1,750 repayment as +1,750
    -- 'available' put the balance back to +1,750 — money the seller
    -- had already received once as the advance and then paid back.
    -- Withdrawing it would have paid the advance twice. The debt
    -- math is unchanged: sellerDebtAmount() nets 'debt' against
    -- 'repayment' by kind (no bucket filter), and the balances RPC
    -- and the app only sum the 'held' and 'available' buckets, so a
    -- 'settled' repayment is invisible to withdrawable balances.
    -- The cap below is kind-based, so it still caps the repayment
    -- at the outstanding debt. (The wallet_ledger bucket CHECK is
    -- widened to include 'settled' in §8 of milestone-22.sql.)
    if NEW.bucket <> 'settled' or NEW.amount <= 0 then
      raise exception 'A repayment settles a debt without crediting the seller — it lives in the settled bucket.';
    end if;
    -- A repayment may never exceed what the seller still owes on
    -- this order — otherwise a seller could mint money by writing
    -- repayment rows for themselves. (The order-row lock above
    -- serialises concurrent repayments, so two at once cannot both
    -- pass against the same outstanding debt.)
    select coalesce(sum(abs(amount)), 0) into v_owed
    from public.wallet_ledger
    where order_id = NEW.order_id and kind = 'debt';
    select v_owed - coalesce(sum(amount), 0) into v_owed
    from public.wallet_ledger
    where order_id = NEW.order_id and kind = 'repayment';
    if NEW.amount > v_owed then
      raise exception 'A repayment cannot exceed the debt still owed on this order.';
    end if;
  elsif NEW.kind = 'withdrawal' then
    if NEW.bucket <> 'available' or NEW.amount >= 0
      or NEW.user_id <> auth.uid() then
      raise exception 'A withdrawal takes money out of your own available balance.';
    end if;
    -- (F4) A withdrawal usually has no order to lock, so serialise
    -- per user instead: two concurrent withdrawals can no longer
    -- both read the same balance and both pass.
    perform pg_advisory_xact_lock(727001, hashtext(NEW.user_id::text));
    select coalesce(sum(amount), 0) into v_avail_sum
    from public.wallet_ledger
    where user_id = NEW.user_id and bucket = 'available';
    if v_avail_sum + NEW.amount < 0 then
      raise exception 'A withdrawal cannot take more than the available balance.';
    end if;
  end if;

  -- Held money can never leave hold more than entered: the order's
  -- held sum must stay >= 0 after this row. This is the backstop
  -- against a release and a refund (or any two racing money moves)
  -- draining the same hold twice — the unique indexes only stop
  -- two rows of the SAME kind. (F4) The order-row lock taken above
  -- is what makes this read-then-check safe against a concurrent
  -- move: the second move waits, then re-reads the sum including
  -- the first move's committed rows.
  if NEW.bucket = 'held' and NEW.amount < 0 and NEW.order_id is not null then
    select coalesce(sum(amount), 0) into v_held_sum
    from public.wallet_ledger
    where order_id = NEW.order_id and bucket = 'held';
    if v_held_sum + NEW.amount < 0 then
      raise exception 'There is not enough money held for this order to cover this move.';
    end if;
  end if;

  return NEW;
end;
$$;



create or replace function public.pm_validate_order_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_owner boolean := public.pm_is_owner();
  v_is_buyer boolean := v_uid = OLD.buyer_id;
  v_is_seller boolean := v_uid = OLD.seller_id;
  v_via_rpc boolean := coalesce(current_setting('pulsemarket.handoff_rpc', true) = 'true', false);
  -- (Milestone 23) Set (transaction-local) by the dispute triggers
  -- in §2/§9 before THEY flip the frozen flag, so their updates
  -- pass the §6 branch below even when the caller is the buyer.
  v_via_unfreeze boolean := coalesce(current_setting('pulsemarket.unfreeze_rpc', true) = 'true', false);
  v_handoff_ok boolean;
  v_flag_only boolean;
  -- (M25 shipping change) Same-city check for the rider branch:
  -- the listing's state/country, looked up when rider details
  -- change (see §11 below).
  v_listing_state text;
  v_listing_country text;
begin
  if v_uid is null then
    return NEW;
  end if;

  -- (a) Money timestamps are stamped here, from the database clock,
  -- not the phone's clock. A caller-supplied value is overwritten.
  if OLD.status = 'reserved' and NEW.status = 'paid' then
    NEW.paid_at := now();
  end if;
  if OLD.status = 'paid' and NEW.status = 'held' then
    NEW.held_at := now();
  end if;
  if OLD.status is distinct from 'delivered' and NEW.status = 'delivered' then
    NEW.delivered_at := now();
  end if;
  if OLD.status is distinct from 'released' and NEW.status = 'released' then
    NEW.released_at := now();
  end if;

  -- 1) Money and identity fields never change after the order is placed.
  if NEW.id is distinct from OLD.id
    or NEW.code is distinct from OLD.code
    or NEW.listing_id is distinct from OLD.listing_id
    or NEW.buyer_id is distinct from OLD.buyer_id
    or NEW.seller_id is distinct from OLD.seller_id
    or NEW.item_price is distinct from OLD.item_price
    or NEW.service_fee is distinct from OLD.service_fee
    or NEW.secure_fee is distinct from OLD.secure_fee
    or NEW.shipping_fee is distinct from OLD.shipping_fee
    or NEW.total is distinct from OLD.total
    or NEW.payment_method is distinct from OLD.payment_method
    or NEW.delivery_method is distinct from OLD.delivery_method
    or NEW.created_at is distinct from OLD.created_at
    or NEW.meetup_spot is distinct from OLD.meetup_spot
    or NEW.ship_to_state is distinct from OLD.ship_to_state
    or NEW.courier is distinct from OLD.courier
  then
    raise exception 'Order details cannot be changed after the order is placed.';
  end if;

  -- The seller code never lives on the order any more (Milestone 14).
  if NEW.seller_code is not null then
    raise exception 'Seller codes are stored in the handoff table, not on the order.';
  end if;

  -- 2) Timestamps only move with the status move they belong to.
  -- (They are stamped above, so a change here means the caller is
  -- trying to move one without its status move.)
  if NEW.paid_at is distinct from OLD.paid_at
    and not (OLD.status = 'reserved' and NEW.status = 'paid') then
    raise exception 'paid_at can only be set when the order is marked paid.';
  end if;
  if NEW.held_at is distinct from OLD.held_at
    and not (OLD.status = 'paid' and NEW.status = 'held') then
    raise exception 'held_at can only be set when the transfer is confirmed.';
  end if;
  if NEW.delivered_at is distinct from OLD.delivered_at
    and not (OLD.status is distinct from 'delivered' and NEW.status = 'delivered') then
    raise exception 'delivered_at can only be set when delivery is confirmed.';
  end if;
  if NEW.released_at is distinct from OLD.released_at
    and not (OLD.status is distinct from 'released' and NEW.status = 'released') then
    raise exception 'released_at can only be set when the money is released.';
  end if;

  -- 3) Frozen money does not move at all until the team resolves the
  -- dispute and unfreezes the order.
  if coalesce(OLD.frozen, false) and NEW.status is distinct from OLD.status then
    raise exception 'This order is frozen — a dispute is open. The PulseMarket team resolves it first.';
  end if;

  -- (DB-15) A return cannot be opened or changed while the order is
  -- frozen — the team resolves the dispute first, then the return.
  -- The unfreeze itself only flips `frozen`, so this never blocks
  -- it. (Handoff confirms are left alone: the status gate above
  -- and the ledger frozen check already stop any money moving.)
  if coalesce(OLD.frozen, false)
    and (NEW.return_status is distinct from OLD.return_status
         or NEW.return_reason is distinct from OLD.return_reason) then
    raise exception 'This order is frozen — a return cannot be opened or changed until the dispute is resolved.';
  end if;

  -- 4) Status moves: only the listed actor may make each move.
  if NEW.status is distinct from OLD.status then
    -- (c) A return that is open stops any release: the money must
    -- stay put until the team resolves the return.
    if NEW.status = 'released' and coalesce(OLD.return_status, '') = 'opened' then
      raise exception 'A return is open for this order — the PulseMarket team resolves it first.';
    end if;

    -- Milestone 17: held -> released is forbidden for EVERYONE,
    -- including the team. Money is only released after delivery is
    -- confirmed (delivered -> released, below). A held order the
    -- seller never ships exits through held -> refunded (team
    -- refund, kept below), never through release — so a buyer can
    -- never release before the item arrives, and the team cannot
    -- do it for them either. Deleting the old branch alone would
    -- have left the generic "cannot move" error; this says why.
    if OLD.status = 'held' and NEW.status = 'released' then
      raise exception 'Money is only released after delivery is confirmed — it cannot be released while the order is still held.';
    end if;

    if OLD.status = 'reserved' and NEW.status = 'paid' and v_is_buyer and OLD.payment_method = 'held' then
      null;
    elsif OLD.status = 'reserved' and NEW.status = 'delivered' and v_is_buyer and OLD.payment_method = 'cash' then
      null;
    elsif OLD.status = 'reserved' and NEW.status = 'cancelled' and v_is_buyer then
      null;
    elsif OLD.status = 'reserved' and NEW.status = 'cancelled' and v_is_seller then
      -- (M18) The seller may cancel a reserved order the buyer has
      -- ghosted on — the listing goes back to active. Never from
      -- 'paid': the buyer may already have transferred, and only
      -- the team can unwind that.
      null;
    elsif OLD.status = 'paid' and NEW.status = 'held' and v_owner and OLD.payment_method = 'held' then
      null;
    elsif OLD.status = 'paid' and NEW.status = 'cancelled' and v_is_buyer then
      null;
    elsif OLD.status in ('reserved', 'paid') and NEW.status = 'cancelled' and v_owner then
      -- (M18) The team may cancel a reserved or paid order (a
      -- ghosted buyer, a fraudulent listing). Cancelling a paid
      -- order is a team-only unwind — the transfer is returned by
      -- hand, outside the ledger.
      null;
    elsif OLD.status = 'held' and NEW.status = 'shipped' and v_is_seller and OLD.payment_method = 'held' then
      null;
    elsif OLD.status = 'held' and NEW.status = 'delivered' and v_is_buyer and OLD.payment_method = 'held' and OLD.delivery_method = 'meetup' then
      -- (M21) held -> delivered is the meet-in-person path only. A
      -- shipping order must pass through 'shipped' (waybill + PIN +
      -- tracking) before it can be delivered.
      null;
    elsif OLD.status = 'held' and NEW.status = 'refunded' and v_owner and OLD.payment_method = 'held' then
      -- (F2) Team refund of an order the seller never shipped
      -- (refundHeldOrder, /admin). The refund legs must already
      -- exist — the (b) check below enforces that — and the app
      -- refuses it while a return is open or the order is frozen.
      null;
    elsif OLD.status = 'shipped' and NEW.status = 'delivered' and v_is_buyer and OLD.payment_method = 'held' then
      null;
    elsif OLD.status = 'shipped' and NEW.status = 'refunded' and v_owner and OLD.payment_method = 'held' then
      null;
    elsif OLD.status = 'delivered' and NEW.status = 'released'
      and (v_is_buyer or v_owner
           or (v_is_seller and OLD.delivered_at <= now() - interval '48 hours'))
      and OLD.payment_method = 'held' then
      -- The seller branch is the 48h auto-release only: once the
      -- buyer confirmed delivery 48h ago, the release is due
      -- whoever's phone runs the check. A seller can never release
      -- early — that would skip the buyer's return window.
      null;
    elsif OLD.status = 'delivered' and NEW.status = 'refunded' and v_owner and OLD.payment_method = 'held' then
      null;
    else
      raise exception 'Order cannot move from % to %.', OLD.status, NEW.status;
    end if;

    -- Delivery needs the handoff (meet in person) or the verified
    -- unboxing video (shipping). Release of a meet-in-person order
    -- needs the handoff too.
    if NEW.status = 'delivered' or (NEW.status = 'released' and OLD.delivery_method = 'meetup') then
      if OLD.delivery_method = 'meetup' then
        v_handoff_ok := OLD.handoff_scanned_at is not null
          and OLD.handoff_photo_buyer is not null
          and OLD.handoff_photo_seller is not null
          and coalesce(OLD.buyer_confirmed, false)
          and coalesce(OLD.seller_confirmed, false);
        if not v_handoff_ok then
          raise exception 'Handoff not complete — the buyer must scan the seller code and both sides must confirm with photos.';
        end if;
      elsif NEW.status = 'delivered' and OLD.delivery_method = 'shipping' then
        if not public.pm_has_verified_unboxing(OLD.id) then
          raise exception 'Add your unboxing video first — it must be recorded in the app and no longer than 60 seconds.';
        end if;
      end if;
    end if;

    -- (b) The status must have its money behind it already: the
    -- app writes the ledger rows first and then moves the status,
    -- so at this point the rows must exist. A status-only update
    -- (no ledger) used to mark money held / released / refunded
    -- that never moved.
    if OLD.status = 'paid' and NEW.status = 'held' then
      if not exists (
        select 1 from public.wallet_ledger
        where order_id = OLD.id and kind = 'hold' and bucket = 'held'
      ) then
        raise exception 'No hold is recorded for this order — the money cannot be marked held.';
      end if;
      -- (Milestone 24) A hold leg alone does not prove the money is
      -- there: a cancel that crashed after writing its reversal
      -- leaves a hold leg AND a refund leg in the held bucket, and
      -- the sum is zero. The whole held bucket must equal the
      -- order total, or the order cannot be marked held (marking
      -- it would resurrect a cancelled order).
      if (select coalesce(sum(amount), 0) from public.wallet_ledger
          where order_id = OLD.id and bucket = 'held') <> OLD.total then
        raise exception 'The held amount does not match this order total — the money cannot be marked held.';
      end if;
    end if;
    if NEW.status = 'released' then
      if not exists (
        select 1 from public.wallet_ledger
        where order_id = OLD.id and kind = 'release' and bucket = 'held'
      ) or not exists (
        select 1 from public.wallet_ledger
        where order_id = OLD.id and kind = 'release' and bucket = 'available'
      ) then
        raise exception 'No release is recorded for this order — the money cannot be marked released.';
      end if;
    end if;
    if NEW.status = 'refunded' then
      if not exists (
        select 1 from public.wallet_ledger
        where order_id = OLD.id and kind = 'refund' and bucket = 'held'
      ) or not exists (
        select 1 from public.wallet_ledger
        where order_id = OLD.id and kind = 'refund' and bucket = 'available'
      ) then
        raise exception 'No refund is recorded for this order — it cannot be marked refunded.';
      end if;
    end if;

    -- (d) Shipping needs proof: a held order becomes shipped only
    -- with a waybill number, a waybill photo and a delivery PIN.
    if OLD.status = 'held' and NEW.status = 'shipped' then
      if NEW.waybill_number is null or btrim(NEW.waybill_number) = ''
        or NEW.waybill_photo is null
        or NEW.delivery_pin is null then
        raise exception 'Shipping proof needs a waybill number, a waybill photo and a delivery PIN.';
      end if;
    end if;
  end if;

  -- 5) Handoff scan / attempts / lock: only the server-side code
  -- check (verify_seller_code) or the team may write these. A buyer
  -- typing the code into a direct API call cannot mark their own
  -- handoff scanned.
  if NEW.handoff_scanned_at is distinct from OLD.handoff_scanned_at
    or NEW.code_attempts is distinct from OLD.code_attempts
    or NEW.handoff_locked is distinct from OLD.handoff_locked
  then
    if not (v_via_rpc or v_owner) then
      raise exception 'The seller code can only be checked through the handoff scan.';
    end if;
  end if;

  -- 6) Frozen flag: the buyer may freeze (file a dispute); only the
  -- team may unfreeze (resolve it).
  if NEW.frozen is distinct from OLD.frozen then
    if v_owner then
      null;
    elsif v_is_buyer and NEW.frozen = true and coalesce(OLD.frozen, false) = false then
      null;
    -- (Milestone 23) The dispute triggers set this flag
    -- (transaction-local) when THEY flip the flag — §2 unfreezing
    -- on delete, §9 re-freezing on re-open — so their updates pass
    -- even when the caller is the buyer deleting their own dispute.
    -- Without it, §2's whole DELETE failed here: the deleter is the
    -- buyer, and only the team may unfreeze. A caller cannot set
    -- the flag through the API (set_config is not exposed there),
    -- and it dies with the transaction — same as handoff_rpc.
    elsif v_via_unfreeze then
      null;
    else
      raise exception 'Only the PulseMarket team can change the frozen flag.';
    end if;
  end if;

  -- 7) Handoff photos: each side sets only its own, and it must be a
  -- file they uploaded to their own folder in the evidence bucket
  -- (the URL pattern the app's own uploads produce). (e) A photo is
  -- frozen once that side has confirmed — the evidence cannot be
  -- swapped after the handoff is agreed.
  if NEW.handoff_photo_buyer is distinct from OLD.handoff_photo_buyer then
    -- (Milestone 24) The team may correct a handoff photo too —
    -- before this, only the buyer could set it, so a wrong photo
    -- could only be fixed outside the app. The "cannot change
    -- after confirm" rule below still applies to everyone.
    if not (v_is_buyer or v_owner) then
      raise exception 'Only the buyer can set the buyer handoff photo.';
    end if;
    if coalesce(OLD.buyer_confirmed, false) then
      raise exception 'The buyer handoff photo cannot be changed after the buyer confirmed.';
    end if;
    if NEW.handoff_photo_buyer is not null
      and NEW.handoff_photo_buyer not like '%/storage/v1/object/public/evidence-media/' || v_uid::text || '/%' then
      raise exception 'The handoff photo must be a photo uploaded from this app.';
    end if;
  end if;
  if NEW.handoff_photo_seller is distinct from OLD.handoff_photo_seller then
    -- (Milestone 24) Same team bypass as the buyer photo above.
    if not (v_is_seller or v_owner) then
      raise exception 'Only the seller can set the seller handoff photo.';
    end if;
    if coalesce(OLD.seller_confirmed, false) then
      raise exception 'The seller handoff photo cannot be changed after the seller confirmed.';
    end if;
    if NEW.handoff_photo_seller is not null
      and NEW.handoff_photo_seller not like '%/storage/v1/object/public/evidence-media/' || v_uid::text || '/%' then
      raise exception 'The handoff photo must be a photo uploaded from this app.';
    end if;
  end if;

  -- 8) Dual confirm: only your own flag, only after the scan and
  -- your own photo, and never un-confirming.
  if NEW.buyer_confirmed is distinct from OLD.buyer_confirmed then
    if not v_is_buyer or NEW.buyer_confirmed is not true
      or OLD.handoff_scanned_at is null or OLD.handoff_photo_buyer is null then
      raise exception 'Only the buyer can confirm, after scanning the code and taking the handoff photo.';
    end if;
  end if;
  if NEW.seller_confirmed is distinct from OLD.seller_confirmed then
    if not v_is_seller or NEW.seller_confirmed is not true
      or OLD.handoff_scanned_at is null or OLD.handoff_photo_seller is null then
      raise exception 'Only the seller can confirm, after the code is scanned and taking the handoff photo.';
    end if;
  end if;

  -- 9) Shipping proof: seller only, only with the held -> shipped move.
  -- (f) One exception: setting ONLY the shipping_advance_released
  -- flag, on a shipped/delivered order whose proof is complete and
  -- whose advance is already in the ledger — the retry step in
  -- submitShippingProof, after the advance was paid but the flag
  -- update was lost.
  if NEW.delivery_pin is distinct from OLD.delivery_pin
    or NEW.waybill_number is distinct from OLD.waybill_number
    or NEW.waybill_photo is distinct from OLD.waybill_photo
    or NEW.receipt_photo is distinct from OLD.receipt_photo
    or NEW.driver_phone is distinct from OLD.driver_phone
    or NEW.shipping_proof_at is distinct from OLD.shipping_proof_at
    or NEW.shipping_advance_released is distinct from OLD.shipping_advance_released
  then
    v_flag_only :=
      NEW.delivery_pin is not distinct from OLD.delivery_pin
      and NEW.waybill_number is not distinct from OLD.waybill_number
      and NEW.waybill_photo is not distinct from OLD.waybill_photo
      and NEW.receipt_photo is not distinct from OLD.receipt_photo
      and NEW.driver_phone is not distinct from OLD.driver_phone
      and NEW.shipping_proof_at is not distinct from OLD.shipping_proof_at
      and NEW.shipping_advance_released is distinct from OLD.shipping_advance_released;
    if v_flag_only then
      if not (v_is_seller and NEW.shipping_advance_released = true
              and OLD.status in ('shipped', 'delivered') and NEW.status = OLD.status
              and OLD.waybill_number is not null and OLD.receipt_photo is not null
              and exists (
                select 1 from public.wallet_ledger
                where order_id = OLD.id and kind = 'shipping_advance'
                  and bucket = 'available' and amount > 0
              )) then
        raise exception 'The shipping advance flag can only be set once the advance is in the ledger.';
      end if;
    else
      -- (M21) Team correction: a wrong delivery PIN blocks the buyer
      -- at handover and a typo'd waybill number breaks tracking, so
      -- the team may fix the text fields after shipping. Team-only,
      -- no status change, and the photos stay locked (a re-uploaded
      -- photo cannot be re-pointed here).
      -- (Milestone 22) The flag stays locked here too: the old
      -- condition let the team flip shipping_advance_released in
      -- the same update as a PIN fix, even with no advance in the
      -- ledger — which then made the advance retry skip a
      -- legitimate advance. (A flag-only change still goes through
      -- the seller path above, which requires the advance.)
      if v_owner and NEW.status = OLD.status and OLD.status in ('shipped', 'delivered')
        and NEW.waybill_photo is not distinct from OLD.waybill_photo
        and NEW.receipt_photo is not distinct from OLD.receipt_photo
        and NEW.shipping_proof_at is not distinct from OLD.shipping_proof_at
        and NEW.shipping_advance_released is not distinct from OLD.shipping_advance_released then
        null;
      elsif not (v_is_seller and OLD.status = 'held' and NEW.status = 'shipped') then
        raise exception 'Shipping proof can only be submitted by the seller when the money is held.';
      end if;
      if NEW.delivery_pin is not null and NEW.delivery_pin !~ '^[0-9]{6}$' then
        raise exception 'The delivery PIN must be 6 digits.';
      end if;
      if NEW.waybill_number is not null and btrim(NEW.waybill_number) = '' then
        raise exception 'The waybill number cannot be empty.';
      end if;
      -- (M21) Only a photo that actually changed is re-checked, and
      -- it is checked against the seller's folder, not the caller's:
      -- the team correcting a PIN must not trip on the seller's
      -- existing photo.
      if NEW.waybill_photo is distinct from OLD.waybill_photo
        and NEW.waybill_photo is not null
        and NEW.waybill_photo not like '%/storage/v1/object/public/evidence-media/' || OLD.seller_id::text || '/%' then
        raise exception 'The waybill photo must be a photo uploaded from this app.';
      end if;
      if NEW.receipt_photo is distinct from OLD.receipt_photo
        and NEW.receipt_photo is not null
        and NEW.receipt_photo not like '%/storage/v1/object/public/evidence-media/' || OLD.seller_id::text || '/%' then
        raise exception 'The receipt photo must be a photo uploaded from this app.';
      end if;
    end if;
  end if;

  -- 10) Returns: the buyer opens (after shipping), the team resolves.
  if NEW.return_status is distinct from OLD.return_status then
    if NEW.return_status = 'opened' then
      if not v_is_buyer or OLD.status not in ('shipped', 'delivered') then
        raise exception 'A return can only be opened by the buyer after the item has shipped.';
      end if;
      -- (M21) A return that was already resolved cannot be opened
      -- again — re-opening stalled every release while it sat open.
      -- Something new after a resolution goes through a dispute.
      -- (Milestone 24) A rejected return is terminal too.
      if OLD.return_status in ('resolved', 'rejected') then
        raise exception 'This return was already resolved or rejected — it cannot be opened again. If something new came up, file a dispute and the PulseMarket team will look at it.';
      end if;
      -- (M20 M-7) The reason must travel with the opening: a
      -- return opened without a fault-prefixed reason can never
      -- be refunded, because the ledger prices the refund from
      -- the stored reason prefix. The app always sets it; this
      -- is the backstop for a direct API call.
      if NEW.return_reason is null
        or (NEW.return_reason not like 'Seller fault%'
            and NEW.return_reason not like 'Buyer fault%') then
        raise exception 'Opening a return needs a reason that starts with "Seller fault" or "Buyer fault".';
      end if;
    elsif NEW.return_status = 'resolved' then
      if not v_owner or OLD.return_status <> 'opened' then
        raise exception 'Only the PulseMarket team can resolve an open return.';
      end if;
    elsif NEW.return_status = 'rejected' then
      -- (Milestone 24) A bogus return can be rejected by the team:
      -- the order carries on as if the return never happened
      -- (release and the 48h auto-release already unblock on
      -- anything but 'opened'), and the buyer's recourse if
      -- something is still wrong is a dispute. Terminal: a
      -- rejected return cannot be re-opened (see above).
      if not v_owner or OLD.return_status <> 'opened' then
        raise exception 'Only the PulseMarket team can reject an open return.';
      end if;
    else
      raise exception 'Unknown return status.';
    end if;
  end if;
  if NEW.return_reason is distinct from OLD.return_reason then
    -- (M20 §12-B, WIDENED — see the file header, note B-2.) The
    -- team may correct the fault label while the return is open
    -- (staying 'opened') or in the same update that resolves it.
    -- The correction MUST land before the refund legs are written:
    -- the ledger prices the refund from the stored reason at
    -- insert time, and once the return is resolved the ledger
    -- refuses refund legs outright — so a correction allowed ONLY
    -- at resolution would always arrive too late to price the
    -- refund. resolveReturn must therefore write the corrected
    -- reason FIRST (its own order update), then the refund legs,
    -- then the resolving update.
    if v_owner and OLD.return_status = 'opened'
      and NEW.return_status in ('opened', 'resolved') then
      null;
    elsif not (v_is_buyer and NEW.return_status = 'opened'
            and OLD.return_status is distinct from 'opened') then
      raise exception 'The return reason can only be set when the return is opened.';
    end if;
  end if;

  -- 11) Rider details (M19 Decision 6). The team may set them
  -- any time, as before. The SELLER may also set them, but ONLY
  -- for their own order, ONLY while the order is held or shipped,
  -- and ONLY when the order is SAME-CITY — ship_to_state equals
  -- the listing's state AND ship_to_country equals the listing's
  -- country (looked up below; a missing ship_to_country on a
  -- pre-M25 order counts as the listing's country, as in
  -- pm_validate_order_insert). The transport name plays no part:
  -- any free-text transport qualifies when the order is
  -- same-city. Every other status or actor is still team-only,
  -- and a rider edit may not smuggle a status change with it.
  if (NEW.rider_name is distinct from OLD.rider_name
      or NEW.rider_phone is distinct from OLD.rider_phone) then
    -- (M25 shipping change) Same-city is judged from the listing,
    -- not from a courier name (see §11 above).
    select state, country into v_listing_state, v_listing_country
      from public.listings where id = OLD.listing_id;
    -- (M20 §12-C) The team may set rider details any time
    -- EXCEPT on a terminal order, and never smuggled with a status
    -- change.
    if v_owner and NEW.status = OLD.status
      and OLD.status not in ('cancelled', 'refunded', 'released') then
      null;
    elsif v_is_seller
      and OLD.status in ('held', 'shipped')
      and OLD.ship_to_state is not distinct from v_listing_state
      and coalesce(OLD.ship_to_country, v_listing_country) is not distinct from v_listing_country
      and NEW.status = OLD.status
      -- (Milestone 24) No rider edits while a dispute is open —
      -- the rider details are part of what the team is reviewing.
      and not coalesce(OLD.frozen, false)
    then
      if NEW.rider_name is not null and btrim(NEW.rider_name) = '' then
        raise exception 'The rider name cannot be empty.';
      end if;
      if NEW.rider_phone is not null
        and NEW.rider_phone !~ '^\+?[0-9][0-9 ()-]{6,14}$' then
        raise exception 'That rider phone number does not look right.';
      end if;
    else
      raise exception 'Only the PulseMarket team can set rider details, except the seller for a held or shipped same-city order.';
    end if;
  end if;

  return NEW;
end;
$$;


-- =====================================================================
-- LIVE-RUN PROCEDURE (restated): run this file ONCE, after Richard
-- approves, code first then SQL. Run checks (a)–(d) from the header
-- (after §1 for (a)–(c), after §3 for (d) on the first run) and
-- expect 0 rows each. Never re-run milestone-14..19, milestone-23
-- or milestone-24. Do not touch the two-account test listing,
-- rio-8350@muse.ai, or live data.
-- =====================================================================
