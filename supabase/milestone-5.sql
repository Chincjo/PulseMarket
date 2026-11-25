-- PulseMarket Milestone 5 — real chat (Supabase-backed).
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query ->
-- paste this whole file -> Run. It creates the chat tables and the
-- security rules (RLS) in one go. Safe to run twice: the CREATE TABLE /
-- policy statements use IF NOT EXISTS / DROP IF EXISTS, so re-running it
-- will not duplicate anything or delete existing rows.
--
-- No new environment variables are needed: the app already has
-- VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in Vercel.
-- No seed or sample data is created here — every conversation, message
-- and pickup ticket is created by a real student using the app.
--
-- NOTE: the seller-code handoff (the PM-XXXXXX code scanned at meetup)
-- arrives in Milestone 7. Pickup tickets in this milestone only record
-- where and when buyer and seller agreed to meet.

-- ---------------------------------------------------------------------------
-- 1) Conversations — one per (listing, buyer). The listing title, price
-- and seller label are snapshots: they stay as they were when the chat
-- started, even if the listing is edited or sold afterwards.
-- agreed_price is set when an offer is accepted (Milestone 5 chat offers).
-- buyer_last_read_at / seller_last_read_at drive the unread badge.
-- ---------------------------------------------------------------------------
create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings (id) on delete cascade,
  buyer_id uuid not null references auth.users (id) on delete cascade,
  seller_id uuid not null references auth.users (id) on delete cascade,
  listing_title text not null default '',
  listing_price integer not null default 0 check (listing_price >= 0),
  seller_label text not null default 'Student',
  agreed_price integer check (agreed_price is null or agreed_price >= 0),
  buyer_last_read_at timestamptz,
  seller_last_read_at timestamptz,
  created_at timestamptz not null default now(),
  last_message_at timestamptz
);

-- One chat per buyer per listing — a second "Chat Seller" tap reopens
-- the existing conversation instead of starting a duplicate.
create unique index if not exists conversations_listing_buyer_idx
  on public.conversations (listing_id, buyer_id);
create index if not exists conversations_participant_idx
  on public.conversations (buyer_id, seller_id, last_message_at desc);

alter table public.conversations enable row level security;

drop policy if exists "Participants read their conversations" on public.conversations;
create policy "Participants read their conversations"
  on public.conversations for select
  using (auth.uid() = buyer_id or auth.uid() = seller_id);

drop policy if exists "Participants start conversations" on public.conversations;
create policy "Participants start conversations"
  on public.conversations for insert
  with check (auth.uid() = buyer_id or auth.uid() = seller_id);

drop policy if exists "Participants update their conversations" on public.conversations;
create policy "Participants update their conversations"
  on public.conversations for update
  using (auth.uid() = buyer_id or auth.uid() = seller_id)
  with check (auth.uid() = buyer_id or auth.uid() = seller_id);

-- ---------------------------------------------------------------------------
-- 2) Messages — text, offers and system notes inside a conversation.
-- kind 'offer' carries offer_amount and offer_status; accepting an offer
-- sets conversations.agreed_price (done by the app, Milestone 5).
-- ---------------------------------------------------------------------------
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  sender_id uuid not null references auth.users (id) on delete cascade,
  body text not null default '',
  kind text not null default 'text'
    check (kind in ('text', 'offer', 'system')),
  offer_amount integer check (offer_amount is null or offer_amount >= 0),
  offer_status text check (offer_status is null or offer_status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now()
);

create index if not exists messages_conversation_idx
  on public.messages (conversation_id, created_at);

alter table public.messages enable row level security;

-- Only a participant of the parent conversation can read its messages.
drop policy if exists "Participants read messages" on public.messages;
create policy "Participants read messages"
  on public.messages for select
  using (
    exists (
      select 1 from public.conversations c
      where c.id = messages.conversation_id
        and (c.buyer_id = auth.uid() or c.seller_id = auth.uid())
    )
  );

-- Only a participant can send, and only as themselves.
drop policy if exists "Participants send messages" on public.messages;
create policy "Participants send messages"
  on public.messages for insert
  with check (
    auth.uid() = sender_id
    and exists (
      select 1 from public.conversations c
      where c.id = messages.conversation_id
        and (c.buyer_id = auth.uid() or c.seller_id = auth.uid())
    )
  );

-- Participants can update a message (accepting / declining an offer).
drop policy if exists "Participants update messages" on public.messages;
create policy "Participants update messages"
  on public.messages for update
  using (
    exists (
      select 1 from public.conversations c
      where c.id = messages.conversation_id
        and (c.buyer_id = auth.uid() or c.seller_id = auth.uid())
    )
  )
  with check (
    exists (
      select 1 from public.conversations c
      where c.id = messages.conversation_id
        and (c.buyer_id = auth.uid() or c.seller_id = auth.uid())
    )
  );

-- ---------------------------------------------------------------------------
-- 3) Pickup tickets — a meetup the buyer and seller agreed in chat:
-- a safe spot, a date and a time. This is only the plan to meet; the
-- seller-code handoff that proves the handover arrives in Milestone 7.
-- ---------------------------------------------------------------------------
create table if not exists public.pickup_tickets (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  order_id uuid,
  meetup_spot text not null default '',
  date text not null default '',
  time text not null default '',
  status text not null default 'scheduled'
    check (status in ('scheduled', 'done', 'rescheduled', 'cancelled')),
  created_at timestamptz not null default now()
);

create index if not exists pickup_tickets_conversation_idx
  on public.pickup_tickets (conversation_id, created_at desc);

alter table public.pickup_tickets enable row level security;

drop policy if exists "Participants read pickup tickets" on public.pickup_tickets;
create policy "Participants read pickup tickets"
  on public.pickup_tickets for select
  using (
    exists (
      select 1 from public.conversations c
      where c.id = pickup_tickets.conversation_id
        and (c.buyer_id = auth.uid() or c.seller_id = auth.uid())
    )
  );

drop policy if exists "Participants create pickup tickets" on public.pickup_tickets;
create policy "Participants create pickup tickets"
  on public.pickup_tickets for insert
  with check (
    exists (
      select 1 from public.conversations c
      where c.id = pickup_tickets.conversation_id
        and (c.buyer_id = auth.uid() or c.seller_id = auth.uid())
    )
  );

drop policy if exists "Participants update pickup tickets" on public.pickup_tickets;
create policy "Participants update pickup tickets"
  on public.pickup_tickets for update
  using (
    exists (
      select 1 from public.conversations c
      where c.id = pickup_tickets.conversation_id
        and (c.buyer_id = auth.uid() or c.seller_id = auth.uid())
    )
  )
  with check (
    exists (
      select 1 from public.conversations c
      where c.id = pickup_tickets.conversation_id
        and (c.buyer_id = auth.uid() or c.seller_id = auth.uid())
    )
  );

-- ---------------------------------------------------------------------------
-- 4) Blocked users — a student can block another student; a blocked
-- student cannot start a new chat with the blocker (checked by the app).
-- ---------------------------------------------------------------------------
create table if not exists public.blocked_users (
  blocker_id uuid not null references auth.users (id) on delete cascade,
  blocked_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);

alter table public.blocked_users enable row level security;

drop policy if exists "Students manage their own blocks" on public.blocked_users;
create policy "Students manage their own blocks"
  on public.blocked_users for all
  using (auth.uid() = blocker_id)
  with check (auth.uid() = blocker_id);

-- ---------------------------------------------------------------------------
-- 5) Verified-only chat — a seller can choose to only hear from verified
-- students. The toggle lives on the verifications row so the rule is
-- enforced server-side by the app's startConversation check; the Settings
-- UI that flips it is wired separately.
-- ---------------------------------------------------------------------------
alter table public.verifications
  add column if not exists chat_verified_only boolean not null default false;
