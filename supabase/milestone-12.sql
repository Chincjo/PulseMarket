-- PulseMarket Milestone 12 — Disputes + frozen orders.
--
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query ->
-- paste this whole file -> Run. Safe to run twice: the CREATE TABLE /
-- CREATE SEQUENCE / ALTER TABLE / policy statements use IF NOT EXISTS /
-- DROP IF EXISTS, so re-running it will not duplicate anything or
-- delete existing rows.
--
-- RUN AFTER the Milestone 6 migration (it creates public.orders, which
-- the disputes table references and which gains the frozen column
-- below) and after Milestone 10 (this file replaces the
-- auto_release_overdue_orders() function from milestone-10.sql with
-- the same function plus a frozen guard — see section 4).
--
-- HOW DISPUTES WORK (see src/lib/disputes.js for the app-side rules):
--   1. The buyer of an order files a report from /dispute/:orderId:
--      a category, at least 20 characters of explanation, a contact
--      email, and at least one piece of in-app evidence for the order
--      (dispute video, 10–20s, recorded in the app — never a gallery
--      video). A report with no evidence is refused, never filed.
--   2. Filing freezes the money: orders.frozen is set to true, and a
--      security_log row ('dispute_filed') records it. The 48-hour
--      auto-release skips frozen orders (section 4).
--   3. The buyer sees ONLY "Report sent — under review" plus the
--      ticket ID (PM-TKT-####). The ticket number comes from the
--      dispute_ticket_seq sequence (ticket_id default below), so
--      numbers are unique and sequential.
--   4. The PulseMarket team (pulsemarketsupport@gmail.com, the ONLY
--      admin) reviews and resolves disputes in the private /admin
--      panel. Resolving records the outcome only — it does NOT move
--      any money. Money moves only through the existing manual release
--      / refund steps.
--
-- There is NO seed or sample data here. No new environment variables
-- are needed. Support email: pulsemarketsupport@gmail.com.

-- ---------------------------------------------------------------------------
-- 1) Ticket sequence + disputes table.
-- ticket_id: 'PM-TKT-' + 4 digits from dispute_ticket_seq, built by the
--   column default — the app inserts without a ticket_id and reads the
--   generated one back, so the app never invents a ticket number.
-- status: 'open' (just filed), 'under_review' (team is looking at it),
--   'resolved' (team recorded an outcome).
-- resolution_note: written by the team when resolving. Reporters never
--   see it — the app's fetchMyDisputes / fetchDisputeByTicket select
--   only ticket_id, status, category and created_at.
-- ---------------------------------------------------------------------------
create sequence if not exists public.dispute_ticket_seq
  start with 1
  increment by 1;

create table if not exists public.disputes (
  id uuid primary key default gen_random_uuid(),
  ticket_id text not null unique
    default ('PM-TKT-' || lpad(nextval('dispute_ticket_seq')::text, 4, '0')),
  order_id uuid not null references public.orders (id) on delete cascade,
  reporter_id uuid not null references auth.users (id) on delete cascade,
  category text not null,
  explanation text not null,
  email text not null,
  status text not null default 'open'
    check (status in ('open', 'under_review', 'resolved')),
  resolution_note text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create index if not exists disputes_order_idx
  on public.disputes (order_id, created_at desc);
create index if not exists disputes_reporter_idx
  on public.disputes (reporter_id, created_at desc);
create index if not exists disputes_status_idx
  on public.disputes (status, created_at desc);

alter table public.disputes enable row level security;

-- A reporter reads only their own disputes. The PulseMarket team
-- reads all of them.
drop policy if exists "Reporters read their own disputes" on public.disputes;
create policy "Reporters read their own disputes"
  on public.disputes for select
  using (
    auth.uid() = reporter_id
    or (auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com'
  );

-- Only the buyer of the referenced order can file a dispute, and only
-- as themselves. The app also checks this, the category, the
-- explanation length, the email and the evidence before inserting.
drop policy if exists "Buyers file disputes for their own orders" on public.disputes;
create policy "Buyers file disputes for their own orders"
  on public.disputes for insert
  with check (
    auth.uid() = reporter_id
    and exists (
      select 1 from public.orders o
      where o.id = disputes.order_id
      and o.buyer_id = auth.uid()
    )
  );

-- Only the PulseMarket team can change a dispute (resolve it, or mark
-- it under review). Reporters never update their own disputes.
drop policy if exists "Only the team updates disputes" on public.disputes;
create policy "Only the team updates disputes"
  on public.disputes for update
  using ((auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com')
  with check ((auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com');

-- Nobody deletes disputes (no delete policy).

-- ---------------------------------------------------------------------------
-- 2) Frozen flag on orders. True while a dispute is open: the money
--    must not release until the team has reviewed it. The app sets it
--    when a dispute is filed (src/lib/disputes.js fileDispute).
-- ---------------------------------------------------------------------------
alter table public.orders
  add column if not exists frozen boolean not null default false;

create index if not exists orders_frozen_idx
  on public.orders (frozen) where frozen = true;

-- ---------------------------------------------------------------------------
-- 3) Security log — the team reads all rows. Milestone 7 already
--    created this table and the team-only select policy; restating it
--    here keeps the rule in place if this file is run on its own.
-- ---------------------------------------------------------------------------
drop policy if exists "Only the team reads the security log" on public.security_log;
create policy "Only the team reads the security log"
  on public.security_log for select
  using ((auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com');

-- ---------------------------------------------------------------------------
-- 4) Server-side auto-release, with the frozen guard (Milestone 12).
--    This is the auto_release_overdue_orders() function from
--    supabase/milestone-10.sql copied exactly, with ONE change: the
--    order selection now also requires `and not coalesce(o.frozen,
--    false)`, so an order under dispute never auto-releases while its
--    money is frozen. Nothing else in the function was changed — read
--    milestone-10.sql for the full explanation of the ledger math,
--    the shipping-advance correction and the pg_cron schedule
--    (`select auto_release_overdue_orders()` hourly).
-- ---------------------------------------------------------------------------
create or replace function public.auto_release_overdue_orders()
returns setof text
language plpgsql
security definer
set search_path = public
as $$
declare
  o record;
  v_advance integer;
  v_held_out integer;
  v_release_in integer;
  v_already_released boolean;
begin
  for o in
    select *
    from public.orders
    where status = 'delivered'
      and payment_method = 'held'
      and delivered_at is not null
      and delivered_at <= now() - interval '48 hours'
      and return_status is distinct from 'opened'
      -- Milestone 12 frozen guard: an order under dispute never
      -- auto-releases while its money is frozen.
      and not coalesce(o.frozen, false)
    order by delivered_at asc
    for update skip locked
  loop
    -- Shipping advance already released for this order (Milestone 8:
    -- half the shipping fee can already sit in "available"). It has
    -- already left "held", so it must not leave "held" a second time
    -- and must not be paid to the seller a second time.
    select coalesce(sum(amount), 0) into v_advance
    from public.wallet_ledger
    where order_id = o.id
      and kind = 'shipping_advance'
      and bucket = 'available';

    v_held_out := greatest(o.total - v_advance, 0);
    v_release_in := greatest(o.item_price + o.shipping_fee - v_advance, 0);

    -- Safety net: if a release was already written for this order
    -- (e.g. the app released the money but crashed before updating
    -- the order status), do NOT pay twice — just close the order out.
    select exists (
      select 1 from public.wallet_ledger
      where order_id = o.id
        and kind = 'release'
        and bucket = 'held'
        and amount < 0
    ) into v_already_released;

    if not v_already_released then
      if v_held_out > 0 then
        insert into public.wallet_ledger
          (order_id, user_id, bucket, kind, amount, note, created_by)
        values
          (o.id, o.seller_id, 'held', 'release', -v_held_out,
           'Auto-release (48h) — released from hold for order ' || o.code,
           o.buyer_id);
      end if;
      if v_release_in > 0 then
        insert into public.wallet_ledger
          (order_id, user_id, bucket, kind, amount, note, created_by)
        values
          (o.id, o.seller_id, 'available', 'release', v_release_in,
           'Auto-release (48h) — released to seller for order ' || o.code,
           o.buyer_id);
      end if;
    end if;

    update public.orders
    set status = 'released',
        released_at = coalesce(released_at, now()),
        updated_at = now()
    where id = o.id;

    update public.listings
    set status = 'sold'
    where id = o.listing_id;

    -- Tell both parties. This insert is inside the SECURITY DEFINER
    -- function, so it is NOT blocked by the notifications RLS the
    -- way app-side cross-user inserts are. It must never block the
    -- release itself, so a failure here is swallowed.
    begin
      insert into public.notifications (user_id, kind, title, body, link)
      values
        (o.buyer_id, 'release',
         'Money released for order ' || o.code,
         '48 hours passed since delivery, so the held money for order ' || o.code || ' was released to the seller.',
         '/order/' || o.id::text),
        (o.seller_id, 'release',
         'Money released for order ' || o.code,
         '48 hours passed since delivery, so the held money for order ' || o.code || ' was released to your available balance.',
         '/order/' || o.id::text);
    exception when others then
      null;
    end;

    return next o.code;
  end loop;
  return;
end;
$$;
