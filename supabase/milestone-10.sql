-- PulseMarket Milestone 10 — Notifications + 48h auto-release.
--
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query ->
-- paste this whole file -> Run. Safe to run twice: the CREATE TABLE /
-- policy statements use IF NOT EXISTS / DROP IF EXISTS, so re-running
-- it will not duplicate anything or delete existing rows.
--
-- RUN AFTER the Milestone 6 migration (it creates public.orders and
-- public.wallet_ledger, which the function below reads and writes) and
-- after Milestone 8 (which adds return_status to orders).
--
-- ---------------------------------------------------------------------------
-- HOW THE 48-HOUR AUTO-RELEASE WORKS — READ THIS FIRST
-- ---------------------------------------------------------------------------
-- A held order the buyer confirmed as delivered sits in status
-- 'delivered' with delivered_at set. If the buyer never confirms the
-- release and never opens a return, the held money must still reach
-- the seller: 48 hours after delivery it releases automatically.
--
-- There are TWO mechanisms, and only one needs to be live:
--
--   1. SERVER-SIDE (preferred when available): the function
--      auto_release_overdue_orders() below. It does NOTHING on its own
--      — a function never runs itself. It needs a pg_cron schedule:
--      enable the pg_cron extension in the Supabase dashboard, then
--      schedule `select auto_release_overdue_orders()` to run hourly.
--      Do NOT add CREATE EXTENSION to this file: enabling the
--      extension needs dashboard privileges and the statement would
--      fail when this file is run in the SQL Editor.
--
--   2. APP-SIDE (the live mechanism if pg_cron is not available):
--      src/lib/autoRelease.js runAutoReleaseCheck() does the same
--      release through the app's existing releaseOrder() and the
--      coordinator calls it on app open after sign-in. If pg_cron is
--      not available on the free tier, the app-side check IS the live
--      mechanism — the SQL function below is then only a backup for
--      later, when pg_cron is enabled.
--
-- Either way, an order is released only when ALL of these hold:
--   - status = 'delivered' AND payment_method = 'held' (cash orders
--     are settled face to face — there is no held money to release);
--   - delivered_at is more than 48 hours ago;
--   - no return is open (return_status is not 'opened'). A return
--     opened by the buyer stops the release until the PulseMarket
--     team resolves it. There is no separate disputes table in this
--     app — an open return is the in-app dispute signal, and a
--     status of 'disputed' can never be 'delivered' at the same time.
--
-- LEDGER MATH (mirrors src/lib/orders.js releaseOrder, with one
-- correction — read this): the app's release writes held -total and
-- available +(item_price + shipping_fee). That is exact when no
-- shipping advance was ever released. But Milestone 8 can already
-- have moved half the shipping fee out of "held" (kind
-- 'shipping_advance'). Writing -total again in that case would drive
-- the held bucket negative by the advance. So this function subtracts
-- the advance already released first:
--   held entry    = -(total - advance already released)
--   available entry = item_price + (shipping_fee - advance already
--     released)
-- so the held bucket ends at exactly 0 and the seller receives
-- item_price + shipping_fee in total across the advance and the
-- release. The app-side releaseOrder() (src/lib/orders.js) was
-- aligned with this math by the coordinator: it subtracts any
-- already-released shipping advance from both legs of the release.
--
-- ---------------------------------------------------------------------------
-- CROSS-USER NOTIFICATIONS — insert_notification RPC (added by the
-- coordinator, after Milestone 10 landed)
-- ---------------------------------------------------------------------------
-- The insert policy below allows a row only for its own owner, or for
-- the PulseMarket team account. A buyer messaging a seller could not
-- notify the seller through a plain insert, because with the anon key
-- the database sees the ACTING user, not the recipient. The fix is
-- the SECURITY DEFINER function insert_notification() at the end of
-- this file: the app calls it through src/lib/notifications.js
-- notifyUser(), passing the order or conversation the event belongs
-- to, and the function only inserts when the caller is the recipient
-- themselves, a participant of that order/conversation, or the
-- PulseMarket team account. Nobody can write into a stranger's inbox.
-- The plain-insert policy stays as the fallback for self-notifies.
--
-- There is NO seed or sample data here. No new environment variables
-- are needed. Support email: pulsemarketsupport@gmail.com.

-- ---------------------------------------------------------------------------
-- 1) Notifications — one row per user per event.
-- kind: 'order' (order placed / paid / held), 'message' (chat message
--   or offer), 'checkpoint' (parcel stop), 'dispute' (return opened /
--   resolved), 'rating', 'boost' (boost bought / ending — ending is
--   derived on the Notifications page, no stored row needed),
--   'release' (held money released, including auto-release),
--   'system' (anything else from the PulseMarket team).
-- link: the in-app route to open when the notification is tapped,
--   e.g. '/order/<id>', '/chat/<id>', '/tracking/<orderId>'.
-- ---------------------------------------------------------------------------
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null
    check (kind in ('order', 'message', 'checkpoint', 'dispute', 'rating', 'boost', 'release', 'system')),
  title text not null,
  body text,
  link text,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists notifications_user_idx
  on public.notifications (user_id, created_at desc);
create index if not exists notifications_unread_idx
  on public.notifications (user_id, created_at desc) where is_read = false;

alter table public.notifications enable row level security;

-- Each student reads only their own notifications.
drop policy if exists "Users read their own notifications" on public.notifications;
create policy "Users read their own notifications"
  on public.notifications for select
  using (auth.uid() = user_id);

-- A notification row is inserted only for its own owner, or by the
-- PulseMarket team account. See the KNOWN LIMIT note in the header:
-- cross-user inserts from the app are refused until a SECURITY
-- DEFINER helper or Edge Function is added.
drop policy if exists "Users insert their own notifications" on public.notifications;
create policy "Users insert their own notifications"
  on public.notifications for insert
  with check (
    auth.uid() = user_id
    or (auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com'
  );

-- Each student marks only their own notifications read.
drop policy if exists "Users update their own notifications" on public.notifications;
create policy "Users update their own notifications"
  on public.notifications for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Nobody deletes notifications (no delete policy).

-- ---------------------------------------------------------------------------
-- 2) Server-side auto-release — see the header. Run hourly via pg_cron:
--      select auto_release_overdue_orders();
--    Returns the order codes it released (one row per order), so the
--    pg_cron run history shows what happened. Returns no rows when
--    nothing was due. SECURITY DEFINER so the scheduled job can write
--    the ledger and update orders/listings regardless of who scheduled
--    it; it only ever touches orders that are already 'delivered' and
--    more than 48 hours old with no open return.
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

-- ---------------------------------------------------------------------------
-- 3) insert_notification RPC — cross-user notifications, safely.
-- SECURITY DEFINER so the insert bypasses the notifications RLS, but
-- the function itself enforces who may notify whom: the caller may
-- insert a notification ONLY when they are (a) the recipient
-- themselves, (b) the buyer or seller of the order the event belongs
-- to (p_order_id), (c) a participant of the conversation the event
-- belongs to (p_conversation_id), or (d) the PulseMarket team
-- account. Any other call raises an exception and inserts nothing,
-- so no student can write into a stranger's inbox. The app calls
-- this through notifyUser() in src/lib/notifications.js, which passes
-- the order/conversation id of each event.
-- ---------------------------------------------------------------------------
create or replace function public.insert_notification(
  p_user_id uuid,
  p_kind text,
  p_title text,
  p_body text default null,
  p_link text default null,
  p_order_id uuid default null,
  p_conversation_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_allowed boolean := false;
begin
  if p_user_id is null then
    raise exception 'notification needs a recipient';
  end if;
  if p_kind not in ('order', 'message', 'checkpoint', 'dispute', 'rating', 'boost', 'release', 'system') then
    raise exception 'unknown notification kind %', p_kind;
  end if;
  if p_title is null or btrim(p_title) = '' then
    raise exception 'notification needs a title';
  end if;

  -- (a) notifying yourself is always allowed.
  if auth.uid() = p_user_id then
    v_allowed := true;
  end if;

  -- (b) a participant of the order may notify the other party.
  if not v_allowed and p_order_id is not null then
    select exists (
      select 1 from public.orders
      where id = p_order_id
        and (buyer_id = auth.uid() or seller_id = auth.uid())
    ) into v_allowed;
  end if;

  -- (c) a participant of the conversation may notify the other party.
  if not v_allowed and p_conversation_id is not null then
    select exists (
      select 1 from public.conversations
      where id = p_conversation_id
        and (buyer_id = auth.uid() or seller_id = auth.uid())
    ) into v_allowed;
  end if;

  -- (d) the PulseMarket team account may notify anyone.
  if not v_allowed and (auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com' then
    v_allowed := true;
  end if;

  if not v_allowed then
    raise exception 'not allowed to notify this user';
  end if;

  insert into public.notifications (user_id, kind, title, body, link)
  values (p_user_id, p_kind, btrim(p_title), nullif(btrim(coalesce(p_body, '')), ''), nullif(btrim(coalesce(p_link, '')), ''))
  returning id into v_id;

  return v_id;
end;
$$;

-- Only signed-in users may call it (never anonymous).
revoke execute on function public.insert_notification(uuid, text, text, text, text, uuid, uuid) from public;
grant execute on function public.insert_notification(uuid, text, text, text, text, uuid, uuid) to authenticated;
