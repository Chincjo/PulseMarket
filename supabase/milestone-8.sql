-- PulseMarket Milestone 8 — Shipping (couriers, Waybill Snap fields,
-- shipping proof + 50% advance, tracking checkpoints, delivery PIN,
-- returns).
--
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query ->
-- paste this whole file -> Run. Safe to run twice: the ALTER TABLE /
-- CREATE TABLE / policy statements use IF NOT EXISTS / DROP IF EXISTS,
-- so re-running it will not duplicate anything or delete existing rows.
--
-- RUN AFTER the Milestone 7 migration: Milestone 7 adds its own columns
-- to orders (seller_code, code_attempts, handoff_locked, handoff photos,
-- buyer_confirmed, seller_confirmed) and creates the evidence-media
-- storage bucket and the security_log table. This file does NOT recreate
-- any of those — it only adds the shipping columns and the checkpoints
-- table below.
--
-- HOW SHIPPING WORKS (see src/lib/shipping.js for the app-side rules):
--   1. A held order is shipped by the seller, who submits shipping proof:
--      waybill number + waybill photo + receipt photo (+ driver phone
--      for bus-park waybills). The app stores the photos in the
--      evidence-media bucket, sets shipping_proof_at, generates a
--      6-digit delivery PIN (orders.delivery_pin) and sets status
--      'shipped'.
--   2. The 50% shipping advance is released ONLY when the proof is
--      complete: courier is GIG, GUO, DHL, Peace or ABC AND a waybill
--      number AND a receipt photo are present. Two wallet_ledger rows
--      move half the shipping fee from the seller's "held" bucket to
--      "available" (kind 'shipping_advance'). A bus-park waybill (driver
--      phone only, no receipt) is recorded and the order ships, but earns
--      NO advance. A missing receipt photo earns no advance either.
--   3. The seller adds checkpoints as the parcel moves (picked up, left
--      origin, stopped, arrived at terminal, out for delivery, ready for
--      pickup, delivered). The buyer watches the timeline on
--      /tracking/:orderId. There is NO live rider GPS feed in this
--      system — the tracking page says so plainly.
--   4. At handover the buyer shares the delivery PIN with the courier.
--      The buyer enters the PIN on the tracking page; a correct PIN
--      confirms delivery (the existing Milestone 6 confirmDelivery).
--   5. Returns: the buyer opens a return (fault 'seller' or 'buyer');
--      the PulseMarket team resolves it. Seller fault: the buyer gets
--      the item price + shipping back and the seller owes the advance
--      back (recorded as a 'debt' ledger entry until settled). Buyer
--      fault: the buyer gets the item price back only; the seller keeps
--      the advance and the rest of the shipping fee.
-- Balances are never stored — the app computes them by SUM(amount) over
-- wallet_ledger grouped by bucket. There is NO seed or sample data here.
--
-- No new environment variables are needed. No payment-provider keys
-- are involved.

-- ---------------------------------------------------------------------------
-- 1) Shipping columns on orders
-- delivery_pin: 6-digit code the buyer shares with the courier at
--   handover. Only ever shown to the buyer, never to the seller.
-- waybill_number: typed in by the seller (Waybill Snap is guided
--   capture only — no OCR, no auto-fill).
-- waybill_photo / receipt_photo: public URLs in the evidence-media
--   bucket (created by Milestone 7).
-- driver_phone: bus-park waybills — a driver phone and no receipt.
-- shipping_proof_at: when the seller submitted the proof.
-- shipping_advance_released: true once the 50% advance has moved.
-- return_status / return_reason: 'opened' while a return is open.
-- rider_name / rider_phone: same-city Chowdeck Relay rider details.
-- ---------------------------------------------------------------------------
alter table public.orders
  add column if not exists delivery_pin text,
  add column if not exists waybill_number text,
  add column if not exists waybill_photo text,
  add column if not exists receipt_photo text,
  add column if not exists driver_phone text,
  add column if not exists shipping_proof_at timestamptz,
  add column if not exists shipping_advance_released boolean not null default false,
  add column if not exists return_status text,
  add column if not exists return_reason text,
  add column if not exists rider_name text,
  add column if not exists rider_phone text;

-- ---------------------------------------------------------------------------
-- 2) Shipping checkpoints — one row per stop on a parcel's journey.
-- status: picked_up, left_origin, stopped, arrived_terminal,
--   out_for_delivery, ready_for_pickup, delivered.
-- ---------------------------------------------------------------------------
create table if not exists public.shipping_checkpoints (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  status text not null
    check (status in ('picked_up', 'left_origin', 'stopped', 'arrived_terminal', 'out_for_delivery', 'ready_for_pickup', 'delivered')),
  location text,
  note text,
  photo text,
  created_at timestamptz not null default now()
);

create index if not exists shipping_checkpoints_order_idx
  on public.shipping_checkpoints (order_id, created_at);

alter table public.shipping_checkpoints enable row level security;

-- The buyer, the seller, or the PulseMarket team can read the
-- checkpoints of an order they are part of.
drop policy if exists "Order participants read checkpoints" on public.shipping_checkpoints;
create policy "Order participants read checkpoints"
  on public.shipping_checkpoints for select
  using (
    exists (
      select 1 from public.orders o
      where o.id = shipping_checkpoints.order_id
      and (
        o.buyer_id = auth.uid()
        or o.seller_id = auth.uid()
        or (auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com'
      )
    )
  );

-- Only the seller of the order (or the PulseMarket team) can add a
-- checkpoint. The app also checks this before inserting.
drop policy if exists "Order sellers add checkpoints" on public.shipping_checkpoints;
create policy "Order sellers add checkpoints"
  on public.shipping_checkpoints for insert
  with check (
    (auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com'
    or exists (
      select 1 from public.orders o
      where o.id = shipping_checkpoints.order_id
      and o.seller_id = auth.uid()
    )
  );
