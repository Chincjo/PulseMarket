-- PulseMarket Milestone 7 — Face-to-face handoff (seller code + QR +
-- photo proof + dual confirm).
--
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query ->
-- paste this whole file -> Run. Safe to run twice: the CREATE TABLE /
-- ALTER TABLE / policy statements use IF NOT EXISTS / DROP IF EXISTS,
-- so re-running it will not duplicate anything or delete existing rows.
--
-- HOW THE HANDOFF WORKS:
--   1. When a meet-in-person order is opened for handoff, the seller
--      gets a one-time code (PM-XXXXXX, src/lib/handoff.js). The seller
--      shows it (big text + a QR code made on their own phone).
--   2. At the meetup the buyer scans / types the code. 5 wrong codes
--      locks the handoff and flags the attempting account.
--   3. Both sides take a photo of the handover (in-app camera only).
--   4. Both sides confirm. Only then can the money be released
--      (releaseOrder) or delivery confirmed (confirmDelivery) — those
--      gates live in src/lib/orders.js.
-- There is NO seed or sample data here. No new environment variables
-- are needed. Run AFTER the Milestone 6 migration (it adds columns to
-- public.orders and public.verifications, which Milestones 3-4 and 6
-- create).

-- ---------------------------------------------------------------------------
-- 1) Handoff columns on orders
-- seller_code: one-time code for this deal only (PM-XXXXXX). The partial
--   unique index below enforces that no two open deals share a code,
--   while still allowing orders with no code yet (NULLs are not indexed).
-- code_attempts: wrong-code guesses so far; 5 locks the handoff.
-- handoff_locked: set at 5 wrong attempts; only the PulseMarket team
--   can clear it (contact support).
-- handoff_scanned_at: when the buyer scanned the code correctly.
-- handoff_photo_buyer / handoff_photo_seller: public URLs of the
--   handover photos in the evidence-media bucket.
-- buyer_confirmed / seller_confirmed: each side's own confirmation.
-- ---------------------------------------------------------------------------
alter table public.orders
  add column if not exists seller_code text,
  add column if not exists code_attempts integer not null default 0,
  add column if not exists handoff_locked boolean not null default false,
  add column if not exists handoff_scanned_at timestamptz,
  add column if not exists handoff_photo_buyer text,
  add column if not exists handoff_photo_seller text,
  add column if not exists buyer_confirmed boolean not null default false,
  add column if not exists seller_confirmed boolean not null default false;

-- One-time code per deal: a code value can appear on at most one order.
-- (Partial index: orders with no code yet are not constrained.)
create unique index if not exists orders_seller_code_unique_idx
  on public.orders (seller_code)
  where seller_code is not null;

-- ---------------------------------------------------------------------------
-- 2) Security log — wrong codes, locks and blocked releases.
-- Written by the app (src/lib/handoff.js / src/lib/orders.js). Only the
-- PulseMarket team can read it; order participants can write rows about
-- their own orders.
-- ---------------------------------------------------------------------------
create table if not exists public.security_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete set null,
  order_id uuid references public.orders (id) on delete set null,
  action text not null,
  detail text,
  created_at timestamptz not null default now()
);

create index if not exists security_log_order_idx
  on public.security_log (order_id, created_at desc);
create index if not exists security_log_user_idx
  on public.security_log (user_id, created_at desc);

alter table public.security_log enable row level security;

-- Order participants (buyer or seller) — and the PulseMarket team, who
-- also writes blocked-release rows — can log events about an order.
drop policy if exists "Order participants log security events" on public.security_log;
create policy "Order participants log security events"
  on public.security_log for insert
  with check (
    (auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com'
    or exists (
      select 1 from public.orders o
      where o.id = security_log.order_id
      and (o.buyer_id = auth.uid() or o.seller_id = auth.uid())
    )
  );

-- Only the PulseMarket team can read the security log.
drop policy if exists "Only the team reads the security log" on public.security_log;
create policy "Only the team reads the security log"
  on public.security_log for select
  using ((auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com');

-- ---------------------------------------------------------------------------
-- 3) Flagged accounts — set when a handoff is locked after 5 wrong
-- codes. A flagged account is reviewed by the PulseMarket team.
-- ---------------------------------------------------------------------------
alter table public.verifications
  add column if not exists flagged boolean not null default false;

-- ---------------------------------------------------------------------------
-- 4) Evidence storage bucket: evidence-media (public read, owner-only
-- write). Handoff photos go to <user-id>/handoff-<orderId>-<role>.jpg.
-- Milestone 9 reuses this bucket for delivery evidence. Same policy
-- pattern as the listing-photos bucket in supabase/milestone-3-4.sql.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('evidence-media', 'evidence-media', true)
on conflict (id) do nothing;

drop policy if exists "Anyone reads evidence media" on storage.objects;
create policy "Anyone reads evidence media"
  on storage.objects for select
  using (bucket_id = 'evidence-media');

drop policy if exists "Students upload their own evidence media" on storage.objects;
create policy "Students upload their own evidence media"
  on storage.objects for insert
  with check (
    bucket_id = 'evidence-media'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Students replace their own evidence media" on storage.objects;
create policy "Students replace their own evidence media"
  on storage.objects for update
  using (
    bucket_id = 'evidence-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Students delete their own evidence media" on storage.objects;
create policy "Students delete their own evidence media"
  on storage.objects for delete
  using (
    bucket_id = 'evidence-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
