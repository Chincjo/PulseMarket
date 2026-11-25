-- PulseMarket Milestone 6 — Payments + wallet ledger (MANUAL-ESCROW MODE).
--
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query ->
-- paste this whole file -> Run. Safe to run twice: the CREATE TABLE /
-- policy statements use IF NOT EXISTS / DROP IF EXISTS, so re-running
-- it will not duplicate anything or delete existing rows.
--
-- HOW MANUAL ESCROW WORKS (no payment provider is wired in):
--   1. Buyer reserves an item (order status 'reserved'). Cash orders are
--      settled face to face; held orders are paid by bank transfer to
--      PulseMarket, using the order code (PM-ORD-XXXXXX) as reference.
--   2. The owner (pulsemarketsupport@gmail.com) confirms the transfer
--      arrived: 'paid' -> 'held', and the full total enters the seller's
--      "held" wallet bucket (one wallet_ledger row).
--   3. Buyer confirms delivery: 'held'/'shipped' -> 'delivered'.
--   4. Release (buyer or owner): 'held'/'delivered' -> 'released'. Two
--      ledger rows: the total leaves "held" and the item price + shipping
--      fee enters "available". Service + secure fees stay with PulseMarket.
-- Balances are never stored — the app computes them by SUM(amount) over
-- wallet_ledger grouped by bucket. There is NO seed or sample data here.
--
-- Run AFTER the Milestone 5 migration: the listings policy below reads
-- public.conversations, which Milestone 5 creates.
--
-- No new environment variables are needed. No Paystack keys or SDK are
-- involved: Paystack activation was refused (needs CAC registration +
-- escrow authorisation), so payments stay manual until that changes.

-- ---------------------------------------------------------------------------
-- 1) Orders
-- code: 'PM-ORD-' + 6 uppercase letters/digits, generated client-side
--       (generateOrderCode in src/lib/orders.js). The buyer uses it as the
--       bank-transfer reference.
-- payment_method: 'cash' = face to face, no fees. 'held' = bank transfer
--       to PulseMarket, money held until the buyer confirms delivery.
-- delivery_method: 'meetup' or 'shipping'.
-- status flow (held): reserved -> paid -> held -> delivered -> released
--   (shipped is set by a later milestone's shipping step).
-- status flow (cash): reserved -> delivered, then the listing is sold.
-- cancelled / refunded / disputed can happen from the open states.
-- ---------------------------------------------------------------------------
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  listing_id uuid not null references public.listings (id) on delete cascade,
  buyer_id uuid not null references auth.users (id) on delete cascade,
  seller_id uuid not null references auth.users (id) on delete cascade,
  item_price integer not null check (item_price >= 0),
  service_fee integer not null default 0 check (service_fee >= 0),
  secure_fee integer not null default 0 check (secure_fee >= 0),
  shipping_fee integer not null default 0 check (shipping_fee >= 0),
  total integer not null check (total >= 0),
  payment_method text not null check (payment_method in ('cash', 'held')),
  delivery_method text not null check (delivery_method in ('meetup', 'shipping')),
  status text not null default 'reserved'
    check (status in ('reserved', 'paid', 'held', 'shipped', 'delivered', 'released', 'cancelled', 'refunded', 'disputed')),
  meetup_spot text,
  ship_to_state text,
  courier text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  paid_at timestamptz,
  held_at timestamptz,
  delivered_at timestamptz,
  released_at timestamptz
);

create index if not exists orders_buyer_idx on public.orders (buyer_id, created_at desc);
create index if not exists orders_seller_idx on public.orders (seller_id, created_at desc);
create index if not exists orders_listing_idx on public.orders (listing_id);
create index if not exists orders_code_idx on public.orders (code);

alter table public.orders enable row level security;

-- Buyer, seller, or the PulseMarket team (owner email) can read an order.
drop policy if exists "Order participants read orders" on public.orders;
create policy "Order participants read orders"
  on public.orders for select
  using (
    auth.uid() = buyer_id
    or auth.uid() = seller_id
    or (auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com'
  );

-- Only the buyer can create an order, and only as themselves.
drop policy if exists "Buyers create their own orders" on public.orders;
create policy "Buyers create their own orders"
  on public.orders for insert
  with check (auth.uid() = buyer_id);

-- Buyer, seller, or the owner can update an order (the app's transition
-- functions decide which moves are legal; RLS only decides who may try).
drop policy if exists "Order participants update orders" on public.orders;
create policy "Order participants update orders"
  on public.orders for update
  using (
    auth.uid() = buyer_id
    or auth.uid() = seller_id
    or (auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com'
  )
  with check (
    auth.uid() = buyer_id
    or auth.uid() = seller_id
    or (auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com'
  );

-- ---------------------------------------------------------------------------
-- 2) Wallet ledger
-- amount is SIGNED: positive adds to the bucket, negative removes.
-- bucket 'held' = money waiting for delivery confirmation.
-- bucket 'available' = money the seller can withdraw.
-- kind: 'hold' (money enters hold), 'release' (hold -> available, or
--   money leaves hold), 'refund', 'shipping_advance', 'withdrawal',
--   'debt', 'repayment'. Balances are SUM(amount) grouped by bucket.
-- ---------------------------------------------------------------------------
create table if not exists public.wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders (id) on delete set null,
  user_id uuid not null references auth.users (id) on delete cascade,
  bucket text not null check (bucket in ('held', 'available')),
  kind text not null check (kind in ('hold', 'release', 'refund', 'shipping_advance', 'withdrawal', 'debt', 'repayment')),
  amount integer not null,
  note text,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists wallet_ledger_user_idx on public.wallet_ledger (user_id, created_at desc);
create index if not exists wallet_ledger_order_idx on public.wallet_ledger (order_id);

alter table public.wallet_ledger enable row level security;

-- Each student reads only their own ledger rows.
drop policy if exists "Users read their own ledger" on public.wallet_ledger;
create policy "Users read their own ledger"
  on public.wallet_ledger for select
  using (auth.uid() = user_id);

-- Ledger rows are written only by a participant of the referenced order
-- (buyer or seller) or by the PulseMarket team. A release is started by
-- the buyer but the rows belong to the seller, so the check is about
-- being a participant of the order — not about owning the row. The app
-- writes them only through the paired moves in src/lib/orders.js.
drop policy if exists "Order participants write ledger" on public.wallet_ledger;
create policy "Order participants write ledger"
  on public.wallet_ledger for insert
  with check (
    (auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com'
    or exists (
      select 1 from public.orders o
      where o.id = wallet_ledger.order_id
      and (o.buyer_id = auth.uid() or o.seller_id = auth.uid())
    )
  );

-- ---------------------------------------------------------------------------
-- 3) Listings: let order participants (and chat participants) read a
-- reserved / sold listing they are part of, so a buyer can still open
-- the item page after reserving it. Active listings stay public.
-- (public.conversations is created by the Milestone 5 migration, which
-- runs before this one.)
-- ---------------------------------------------------------------------------
drop policy if exists "Anyone reads active listings" on public.listings;
create policy "Anyone reads active listings"
  on public.listings for select
  using (
    status = 'active'
    or auth.uid() = seller_id
    or exists (
      select 1 from public.orders o
      where o.listing_id = listings.id
      and (o.buyer_id = auth.uid() or o.seller_id = auth.uid())
    )
    or exists (
      select 1 from public.conversations c
      where c.listing_id = listings.id
      and (c.buyer_id = auth.uid() or c.seller_id = auth.uid())
    )
  );
