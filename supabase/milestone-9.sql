-- PulseMarket Milestone 9 — Evidence Locker (in-app camera media only,
-- verified ticks, money gates).
--
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query ->
-- paste this whole file -> Run. Safe to run twice: the CREATE TABLE /
-- policy statements use IF NOT EXISTS / DROP IF EXISTS, so re-running
-- it will not duplicate anything or delete existing rows.
--
-- RUN AFTER the Milestone 7 migration: Milestone 7 created the
-- evidence-media storage bucket (public read, owner-only write under
-- <user-id>/). This file does NOT recreate that bucket — it only adds
-- the evidence table below. The app uploads to that bucket at
-- <user-id>/evidence-<orderId>-<kind>-<timestamp>.<ext>.
--
-- HOW THE EVIDENCE LOCKER WORKS (see src/lib/evidence.js for the
-- app-side rules):
--   1. Photos and videos are recorded IN THE APP only — MediaRecorder
--      for video, the camera capture input for photos. Nothing is
--      picked from the gallery, so a video cannot be faked by uploading
--      an old clip.
--   2. Every row carries a verified tick. A video is verified ONLY when
--      its length fits its kind's rule: dispute evidence 10–20s,
--      packing video 15–30s, unboxing video max 60s (no minimum).
--      Handoff / waybill / receipt / return media are photos, so they
--      have no duration rule — a photo present is enough. Anything that
--      fails its rule is stored with verified=false and a plain reason
--      (e.g. "Video is 8s — dispute evidence must be 10–20s").
--   3. The verified tick is what gates money: confirmDelivery in
--      src/lib/orders.js refuses a shipping order until the buyer has
--      a verified unboxing video for it. Meet-in-person orders are
--      gated by the Milestone 7 handoff instead, not by evidence.
-- There is NO seed or sample data here.
--
-- No new environment variables are needed. No payment-provider keys
-- are involved.

-- ---------------------------------------------------------------------------
-- 1) Evidence — one row per photo / video recorded in the app.
-- kind: packing, unboxing, dispute (videos) and handoff, waybill,
--   receipt, return (photos).
-- media_type: photo or video.
-- duration_seconds: video length in whole seconds; null for photos.
-- verified / verified_reason: set by the app when the row is uploaded,
--   from the same rules in src/lib/evidence.js (verifyEvidenceRow).
--   verified is never set by hand in the database.
-- ---------------------------------------------------------------------------
create table if not exists public.evidence (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  user_id uuid not null,
  kind text not null
    check (kind in ('packing', 'unboxing', 'dispute', 'handoff', 'waybill', 'receipt', 'return')),
  media_type text not null
    check (media_type in ('photo', 'video')),
  url text not null,
  duration_seconds integer,
  verified boolean not null default false,
  verified_reason text,
  created_at timestamptz not null default now()
);

create index if not exists evidence_order_kind_idx
  on public.evidence (order_id, kind);

create index if not exists evidence_user_idx
  on public.evidence (user_id, created_at desc);

alter table public.evidence enable row level security;

-- The buyer, the seller, or the PulseMarket team can read the evidence
-- of an order they are part of.
drop policy if exists "Order participants read evidence" on public.evidence;
create policy "Order participants read evidence"
  on public.evidence for select
  using (
    exists (
      select 1 from public.orders o
      where o.id = evidence.order_id
      and (
        o.buyer_id = auth.uid()
        or o.seller_id = auth.uid()
        or (auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com'
      )
    )
  );

-- Only the buyer or the seller of the order can add evidence, and only
-- for their own user_id. The app also checks this before uploading.
drop policy if exists "Order participants add their own evidence" on public.evidence;
create policy "Order participants add their own evidence"
  on public.evidence for insert
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.orders o
      where o.id = evidence.order_id
      and (o.buyer_id = auth.uid() or o.seller_id = auth.uid())
    )
  );

-- Only the student who recorded a row can delete it. The app also
-- deletes the file from the evidence-media bucket when a row is
-- deleted, so no orphan file is left behind.
drop policy if exists "Owners delete their own evidence" on public.evidence;
create policy "Owners delete their own evidence"
  on public.evidence for delete
  using (user_id = auth.uid());
