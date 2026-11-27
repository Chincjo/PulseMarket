// Milestone 5 — real chat (Supabase-backed, polling-based, no realtime
// dependency). Every function returns null / [] / false and logs the error
// when Supabase is not configured or the tables do not exist yet (owner
// has not run supabase/milestone-5.sql), so the app shows an honest
// "not switched on yet" message instead of crashing.
//
// startConversation() returns { conversation, error } so the caller can
// show the exact reason a chat was refused (not verified, blocked, own
// listing, seller only chats with verified students). The other
// functions follow the listings.js style: data or null/[] on failure.
//
// Rules enforced here (and again by RLS in milestone-5.sql):
// - Only verified students chat: the sender must have an APPROVED
//   verifications row — a row under review or a rejected row is not
//   verified (Milestone 17).
// - You cannot message yourself about your own listing.
// - If the seller set chat_verified_only, the buyer must be verified.
// - If either side blocked the other, no new chat can start.
// - Messages are capped at 1000 characters and a student cannot send
//   more than one message every 2 seconds (spam throttle, client-side).
// - Offers are capped at ₦50,000,000 (MAX_OFFER_NAIRA, enforced in
//   sendOffer as well as in the ChatThread form).
// - A blocked student cannot message in an existing chat either:
//   sendMessage / sendOffer / schedulePickup refuse when either side
//   blocked the other (startConversation only stops NEW chats).
// - A flagged account (5 wrong handoff codes) cannot start a new chat.
// - Milestone 19: a student whose verification is LATER rejected (or
//   who becomes flagged) cannot start NEW activity in an EXISTING
//   chat either — sendMessage / sendOffer / respondOffer /
//   schedulePickup refuse when either side is no longer approved or
//   is flagged (verificationGateRefusal, backed by the Milestone 19
//   database triggers in supabase/m19/01-chat-gates.sql). Existing
//   orders are never frozen or cancelled by this — an order already
//   placed runs to completion.
// - Only the two participants can read a conversation or its messages —
//   that is enforced by RLS in milestone-5.sql, not here. There is no
//   end-to-end encryption by design: the owner must be able to read chats
//   to settle disputes. No IP blocking is possible inside the app: the
//   platform never exposes a visitor's IP address.
import { supabase } from "./supabase";
import { notifyUser } from "./notifications";
import { SAFE_MEETUP_SPOTS } from "./data";

// Longest message the app will send. Longer text is refused, never cut.
export const MAX_MESSAGE_LENGTH = 1000;

// Highest offer the app will send (₦). ChatThread enforces the same cap
// in the UI, but sendOffer() is also callable from anywhere else, so the
// cap lives here too — an offer above this used to sail through the lib
// (the database only checks offer_amount >= 0). Milestone 19, Decision 7:
// raised from ₦10,000,000 to ₦50,000,000. The cap stays — it is not
// removed — and the database check (messages_offer_amount_max) was
// raised to match in supabase/m19/01-chat-gates.sql.
export const MAX_OFFER_NAIRA = 50000000;

// Minimum gap between two sends from the same device (spam throttle).
const SEND_THROTTLE_MS = 2000;
let lastSendAt = 0;

// The plain reason the last chat write was refused by the
// verification gate (Milestone 19), if any. ChatThread reads it
// with getLastChatError() so the student sees WHY the send failed
// instead of a generic "could not send". Cleared on read and on
// every successful send; never holds a secret, only a sentence.
let lastGateError = "";

export function getLastChatError() {
  const msg = lastGateError;
  lastGateError = "";
  return msg;
}

export const QUICK_REPLIES = [
  "Still available?",
  "Can we meet on campus?",
  "Last price?",
];

function dbError(err, where) {
  console.error(`[PulseMarket] ${where}:`, err?.message || err);
  return null;
}

async function currentUserId() {
  if (!supabase) return null;
  const { data, error } = await supabase.auth.getUser();
  if (error) {
    dbError(error, "get current user");
    return null;
  }
  return data?.user?.id || null;
}

// The server verification row for a student, or null if they have none
// (or the verifications table / chat_verified_only column is not there yet).
async function fetchVerification(userId) {
  if (!supabase || !userId) return null;
  const { data, error } = await supabase
    .from("verifications")
    .select("user_id, status, chat_verified_only, flagged")
    .eq("user_id", userId)
    .maybeSingle();
  if (error) return dbError(error, "fetch verification for chat");
  return data;
}

async function isBlockedBetween(a, b, { failClosed = false } = {}) {
  if (!supabase || !a || !b) return false;
  const { data, error } = await supabase
    .from("blocked_users")
    .select("blocker_id")
    .or(`and(blocker_id.eq.${a},blocked_id.eq.${b}),and(blocker_id.eq.${b},blocked_id.eq.${a})`);
  if (error) {
    dbError(error, "check blocked users");
    // Fail OPEN by default: the database triggers refuse the write
    // anyway (pm_validate_message_insert, pm_validate_pickup_insert
    // and pm_validate_conversation_insert all re-check the block
    // list), so a failed check here only costs a refused write and
    // a plain error — chats keep working through a blip in this
    // one table. The ONE path with no database backstop is
    // answering an offer (pm_validate_message_update never checks
    // the block list), so respondOffer() calls this fail-CLOSED.
    return failClosed;
  }
  return (data || []).length > 0;
}

// Whether each listed student is still a verified student
// (approved, unflagged verifications row), from the Milestone 19
// RPC pm_chat_participant_verified. Returns a plain object
// { userId: true/false }; a user the caller shares no conversation
// with simply has no entry. This is the ONLY way to learn the
// OTHER side's status: the verifications SELECT policy only lets
// a student read their own row, so fetchVerification(otherId)
// always comes back empty (see startConversation). Fails OPEN
// ({}): if the RPC is missing (SQL not run yet) or errors, the
// caller carries on and the database triggers refuse the write
// instead — chats keep working through a blip, and a refused
// write still shows its plain server reason.
export async function fetchParticipantsVerified(userIds) {
  const ids = [...new Set((userIds || []).filter(Boolean))];
  if (!supabase || ids.length === 0) return {};
  const { data, error } = await supabase.rpc("pm_chat_participant_verified", {
    p_user_ids: ids,
  });
  if (error) {
    dbError(error, "fetch participant verification");
    return {};
  }
  const out = {};
  for (const row of data || []) {
    if (row?.user_id) out[row.user_id] = row.is_verified === true;
  }
  return out;
}

// Milestone 20 (D-1): is there an OPEN order between these two
// students for this conversation's listing? Open = reserved, paid,
// held, shipped or delivered — an order already placed, in either
// direction (the buyer/seller roles are fixed per order, but the
// caller may be either side). RLS lets a participant read their own
// orders, so this query only ever sees orders the caller is part of.
// Used by the verification gate (plain messages stay open) and by
// ChatThread (the note + the message box) — never for offers,
// offer answers or pickup tickets, which stay blocked.
export const OPEN_ORDER_STATUSES = [
  "reserved",
  "paid",
  "held",
  "shipped",
  "delivered",
];

export async function hasOpenOrderForConversation(conversationId, userId) {
  if (!supabase || !conversationId || !userId) return false;
  const conv = await fetchConversation(conversationId);
  if (!conv || !conv.listing_id) return false;
  const otherId =
    conv.buyer_id === userId ? conv.seller_id : conv.buyer_id;
  if (!otherId || otherId === userId) return false;
  const { data, error } = await supabase
    .from("orders")
    .select("id")
    .eq("listing_id", conv.listing_id)
    .in("status", OPEN_ORDER_STATUSES)
    .or(
      `and(buyer_id.eq.${userId},seller_id.eq.${otherId}),and(buyer_id.eq.${otherId},seller_id.eq.${userId})`
    )
    .limit(1);
  if (error) {
    dbError(error, "check open order for chat");
    return false;
  }
  return (data || []).length > 0;
}

// Milestone 19 gate: the plain reason new activity in this
// conversation must stop, or null when it may go ahead. Refuses
// when EITHER participant's verification is not status='approved'
// or is flagged — including a student whose verification was
// rejected AFTER the chat started. The sender's own row is read
// directly (fetchVerification works for your own row); the other
// side goes through fetchParticipantsVerified (RLS hides their
// row). A side the RPC cannot answer (missing row, RPC not run
// yet) does NOT refuse here — the database triggers are the
// backstop for that side, and refusing on "unknown" would block
// every chat until the Milestone 19 SQL runs.
//
// Milestone 20 (D-1): when `plainMessage` is true (a kind='text'
// message only — never an offer) AND an open order exists between
// the two participants for this conversation's listing, the gate
// does NOT refuse: the buyer and seller still need to coordinate
// delivery of an order already placed. Offers, offer answers and
// pickup tickets never pass plainMessage, so they stay blocked.
async function verificationGateRefusal(
  conversationId,
  userId,
  { plainMessage = false } = {}
) {
  if (!conversationId || !userId) return null;
  const conv = await fetchConversation(conversationId);
  if (!conv) return null;
  const otherId =
    conv.buyer_id === userId ? conv.seller_id : conv.buyer_id;
  if (!otherId || otherId === userId) return null;
  if (plainMessage && (await hasOpenOrderForConversation(conversationId, userId))) {
    return null;
  }
  const mine = await fetchVerification(userId);
  if (!mine) {
    return "Only verified students can chat. Get verified first.";
  }
  if (mine.status === "rejected") {
    return "Your verification was not approved — submit it again with clear ID photos to chat.";
  }
  if (mine.status !== "approved") {
    return "Your verification is under review — you can chat once the team approves it.";
  }
  if (mine.flagged) {
    return "Your account is under review — contact support before starting a new chat.";
  }
  const others = await fetchParticipantsVerified([otherId]);
  if (otherId in others && others[otherId] !== true) {
    return "This student is no longer verified — new messages, offers and meetups are paused for this chat.";
  }
  return null;
}

// ---------------------------------------------------------------------------
// Conversations
// ---------------------------------------------------------------------------

export async function startConversation(listing) {
  if (!supabase) {
    return { conversation: null, error: "Chat is not switched on yet." };
  }
  if (!listing?.id || !listing?.seller_id) {
    return { conversation: null, error: "That listing is no longer available." };
  }
  const buyerId = await currentUserId();
  if (!buyerId) {
    return { conversation: null, error: "Sign in first to message a seller." };
  }
  if (buyerId === listing.seller_id) {
    return { conversation: null, error: "You cannot message yourself about your own listing." };
  }

  // Only verified students chat. A verifications row on its own is
  // not enough — Milestone 17: the row must be APPROVED. A student
  // under review waits; a rejected student is told to submit again
  // instead of being left wondering why chat never opens.
  const buyerVerification = await fetchVerification(buyerId);
  if (!buyerVerification) {
    return {
      conversation: null,
      error: "Only verified students can chat. Get verified first.",
    };
  }
  if (buyerVerification.status === "rejected") {
    return {
      conversation: null,
      error: "Your verification was not approved — submit it again with clear ID photos to chat.",
    };
  }
  if (buyerVerification.status !== "approved") {
    return {
      conversation: null,
      error: "Your verification is under review — you can chat once the team approves it.",
    };
  }

  // A flagged account (5 wrong handoff codes) is under team review:
  // no new chats until the team clears it. The flag is set by the
  // server-side handoff check and the student cannot clear it
  // themselves; existing chats are left alone so an open deal can
  // still be finished.
  if (buyerVerification.flagged) {
    return {
      conversation: null,
      error: "Your account is under review — contact support before starting a new chat.",
    };
  }

  // Seller chose verified-only chat: the buyer must be verified.
  // That is enforced by the approved check above (this function
  // already returned unless the buyer is approved), so there is no
  // separate check here — the old one tested !buyerVerification,
  // which is always truthy at this point and could never fire.
  // The seller's side (flagged / later-rejected) is enforced
  // server-side by the conversation-insert trigger — the app cannot
  // read another student's verification row at all (the SELECT
  // policy only lets a student read their own row, so
  // fetchVerification(seller) always comes back empty; the old
  // flagged check here could never fire either). Do not "fix" it
  // back in: use fetchParticipantsVerified() if the seller's status
  // is ever needed in the app.

  if (await isBlockedBetween(buyerId, listing.seller_id)) {
    return {
      conversation: null,
      error: "You cannot start a chat with this student.",
    };
  }

  // Reopen the existing chat for this (listing, buyer) if there is one.
  const { data: existing, error: findError } = await supabase
    .from("conversations")
    .select("*")
    .eq("listing_id", listing.id)
    .eq("buyer_id", buyerId)
    .maybeSingle();
  if (findError) {
    dbError(findError, "find conversation");
    return { conversation: null, error: "Could not open the chat. Try again." };
  }
  if (existing) return { conversation: existing, error: null };

  const now = new Date().toISOString();
  const { data, error } = await supabase
    .from("conversations")
    .insert({
      listing_id: listing.id,
      buyer_id: buyerId,
      seller_id: listing.seller_id,
      listing_title: listing.title || "",
      listing_price: listing.price || 0,
      seller_label: listing.seller_label || "Student",
      last_message_at: now,
    })
    .select()
    .single();
  if (error) {
    // A second tap racing the first hits the unique (listing, buyer)
    // index — just reopen the conversation that won the race.
    if (error.code === "23505") {
      const { data: raced } = await supabase
        .from("conversations")
        .select("*")
        .eq("listing_id", listing.id)
        .eq("buyer_id", buyerId)
        .maybeSingle();
      if (raced) return { conversation: raced, error: null };
    }
    // The database is the real verification gate for the SELLER's
    // side: the app cannot read another student's row (RLS returns
    // only your own verification), so a pending or rejected seller
    // is refused by the conversation trigger, not by the checks
    // above. Surface its plain reason instead of a generic failure
    // that leaves the buyer wondering why chat never opens.
    if (/approved|verification|under review/i.test(error.message || "")) {
      return { conversation: null, error: error.message };
    }
    dbError(error, "start conversation");
    return { conversation: null, error: "Could not open the chat. Try again." };
  }
  return { conversation: data, error: null };
}

export async function fetchConversation(id) {
  if (!supabase || !id) return null;
  const { data, error } = await supabase
    .from("conversations")
    .select("*")
    .eq("id", id)
    .maybeSingle();
  if (error) return dbError(error, "fetch conversation");
  return data;
}

// All conversations of one student, newest first, each with its
// last message preview and unread count. The last messages and the
// unread counts come from ONE query for all conversations, not one
// query per conversation — the old code ran two queries per chat,
// which made the chat list crawl with many conversations. For a
// conversation whose newest messages fall outside the batched fetch
// (a very long chat history), the last message is read on its own.
export async function fetchConversations(userId, { before } = {}) {
  if (!supabase || !userId) return [];
  let query = supabase
    .from("conversations")
    .select("*")
    .or(`buyer_id.eq.${userId},seller_id.eq.${userId}`)
    .order("last_message_at", { ascending: false, nullsFirst: false });
  // Pass `before` (a last_message_at value from the last row) to
  // fetch the next page — without it a student with more than 100
  // conversations silently sees only the newest 100. The returned
  // array carries `hasMore` (true when a full page came back).
  if (before) query = query.lt("last_message_at", before);
  const { data, error } = await query.limit(100); // Bound: the chat list was the last unbounded list fetch.
  if (error) {
    dbError(error, "fetch conversations");
    return [];
  }
  const list = data || [];
  if (list.length === 0) return [];
  const ids = list.map((c) => c.id);
  const { data: batched } = await supabase
    .from("messages")
    .select("conversation_id, body, kind, offer_amount, sender_id, created_at")
    .in("conversation_id", ids)
    .order("created_at", { ascending: false })
    .limit(1000);
  const byConv = new Map();
  for (const m of batched || []) {
    if (!byConv.has(m.conversation_id)) byConv.set(m.conversation_id, []);
    byConv.get(m.conversation_id).push(m);
  }
  const enriched = await Promise.all(
    list.map(async (c) => {
      const isBuyer = c.buyer_id === userId;
      const lastRead = isBuyer ? c.buyer_last_read_at : c.seller_last_read_at;
      let rows = byConv.get(c.id) || null;
      let unread = 0;
      let lastMsg = null;
      if (rows) {
        lastMsg = rows[0] || null;
        if (lastMsg) {
          unread = rows.filter(
            (m) => m.sender_id !== userId && (!lastRead || m.created_at > lastRead)
          ).length;
        }
      } else {
        // Nothing in the batch for this chat (its newest messages
        // fell outside the 1000-row window) — read its last message
        // and unread count on their own instead of showing a blank
        // preview and a wrong 0.
        const { data: one } = await supabase
          .from("messages")
          .select("body, kind, offer_amount, sender_id, created_at")
          .eq("conversation_id", c.id)
          .order("created_at", { ascending: false })
          .limit(1)
          .maybeSingle();
        lastMsg = one || null;
        if (lastMsg) {
          let q = supabase
            .from("messages")
            .select("id", { count: "exact", head: true })
            .eq("conversation_id", c.id)
            .neq("sender_id", userId);
          if (lastRead) q = q.gt("created_at", lastRead);
          const { count, error: countError } = await q;
          if (!countError) unread = count || 0;
        }
      }
      return { ...c, lastMessage: lastMsg, unreadCount: unread };
    })
  );
  enriched.hasMore = list.length === 100;
  return enriched;
}

// The conversation for one listing and one student, if any — a single
// query, for pages (e.g. Tracking) that only need the chat link for
// one order instead of the whole chat list with previews.
export async function fetchConversationForListing(listingId, userId) {
  if (!supabase || !listingId || !userId) return null;
  const { data, error } = await supabase
    .from("conversations")
    .select("id, agreed_price")
    .eq("listing_id", listingId)
    .or(`buyer_id.eq.${userId},seller_id.eq.${userId}`)
    .order("last_message_at", { ascending: false, nullsFirst: false })
    .limit(1)
    .maybeSingle();
  if (error) return dbError(error, "fetch conversation for listing");
  return data || null;
}

// Night deep check 2026-11-27: same read as above, but a failed
// read THROWS instead of returning null. Checkout needs to tell
// "no conversation" apart from "the read failed" — the null
// version cannot, so a failed read used to look like no agreed
// price and the buyer silently paid full price. Callers that only
// need the row keep using fetchConversationForListing above.
export async function fetchConversationForListingOrThrow(listingId, userId) {
  if (!supabase || !listingId || !userId) return null;
  const { data, error } = await supabase
    .from("conversations")
    .select("id, agreed_price")
    .eq("listing_id", listingId)
    .or(`buyer_id.eq.${userId},seller_id.eq.${userId}`)
    .order("last_message_at", { ascending: false, nullsFirst: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  return data || null;
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

export async function fetchMessages(conversationId, { before } = {}) {
  if (!supabase || !conversationId) return [];
  // Newest 500, then back to oldest-first for the thread. Fetching
  // every message ever sent in a long chat, on every 10-second poll,
  // made old threads slower and slower. Pass `before` (a created_at
  // value from the oldest loaded message) to page back through a
  // very long thread; the returned array carries `hasMore`.
  let query = supabase
    .from("messages")
    .select("*")
    .eq("conversation_id", conversationId)
    .order("created_at", { ascending: false });
  if (before) query = query.lt("created_at", before);
  const { data, error } = await query.limit(500);
  if (error) {
    dbError(error, "fetch messages");
    return [];
  }
  const rows = (data || []).reverse();
  rows.hasMore = (data || []).length === 500;
  return rows;
}

async function insertMessage(conversationId, row) {
  const senderId = await currentUserId();
  if (!senderId) return null;
  // Blocking stops messages, not just new chats: a blocked student
  // used to keep messaging in an existing conversation, because only
  // startConversation checked the block list.
  const conv = await fetchConversation(conversationId);
  if (conv) {
    const otherId = conv.buyer_id === senderId ? conv.seller_id : conv.buyer_id;
    if (otherId && (await isBlockedBetween(senderId, otherId))) {
      console.error("[PulseMarket] send message: you cannot message this student.");
      return null;
    }
  }
  // Milestone 19: a student whose verification was rejected AFTER
  // the chat started (or who became flagged) cannot send new
  // messages — and neither can the other side in that chat. The
  // plain reason is kept for ChatThread (getLastChatError) and
  // logged, matching the blocked refusal above. The 1000-char cap
  // and the 2s throttle below are untouched. This is the shared
  // choke point for sendMessage AND sendOffer (both insert here).
  // Milestone 20 (D-1): a PLAIN text message (kind 'text') is
  // exempt from the gate while an open order exists between the two
  // participants for this conversation's listing, so delivery can
  // still be coordinated. Offers (kind 'offer') never get the
  // exemption — they stay blocked.
  const gateRefusal = await verificationGateRefusal(conversationId, senderId, {
    plainMessage: row.kind === "text",
  });
  if (gateRefusal) {
    lastGateError = gateRefusal;
    return dbError(gateRefusal, "send message");
  }
  // Spam throttle: one send per device every 2 seconds. The clock only
  // moves after a send succeeds, so a failed send never blocks a retry.
  // Milestone 20 (APP-15): the refusal is kept for ChatThread
  // (getLastChatError) like the gate refusal above, instead of only
  // being logged — a refused send used to show a generic failure.
  if (Date.now() - lastSendAt < SEND_THROTTLE_MS) {
    lastGateError = "Too fast — wait a moment before sending again.";
    console.error("[PulseMarket] send message: too fast — wait a moment before sending again.");
    return null;
  }
  const { data, error } = await supabase
    .from("messages")
    .insert({ conversation_id: conversationId, sender_id: senderId, ...row })
    .select()
    .single();
  if (error) {
    dbError(error, "send message");
    return null;
  }
  lastSendAt = Date.now();
  lastGateError = "";
  // Keep the conversation list ordered by the latest message.
  await supabase
    .from("conversations")
    .update({ last_message_at: new Date().toISOString() })
    .eq("id", conversationId);
  return data;
}

export async function sendMessage(conversationId, body) {
  if (!supabase || !conversationId) return null;
  const text = String(body || "").trim();
  if (!text) return null;
  if (text.length > MAX_MESSAGE_LENGTH) {
    // Milestone 20 (APP-15): keep the reason for ChatThread
    // (getLastChatError) — a too-long message used to show only a
    // generic "could not send".
    lastGateError = `Message is too long — keep it under ${MAX_MESSAGE_LENGTH} characters.`;
    return dbError(
      `Message is too long — keep it under ${MAX_MESSAGE_LENGTH} characters.`,
      "send message"
    );
  }
  const senderId = await currentUserId();
  if (!senderId) return null;
  // Blocked in either direction: startConversation() only stops NEW
  // chats, so without this a blocked student could keep messaging in
  // a chat that already exists. Refuse before anything is inserted.
  // Milestone 20 (APP-15): keep the reason for ChatThread.
  if (await blockedWithOther(conversationId, senderId)) {
    lastGateError = "You cannot message this student.";
    return dbError("You cannot message this student.", "send message");
  }
  const sent = await insertMessage(conversationId, { body: text, kind: "text" });
  if (sent) {
    // Milestone 10: tell the other participant (never blocks the send).
    const conv = await fetchConversation(conversationId);
    if (conv) {
      const otherId = conv.buyer_id === senderId ? conv.seller_id : conv.buyer_id;
      notifyUser(otherId, {
        kind: "message",
        title: "New message",
        body: text.slice(0, 120),
        link: `/chat/${conversationId}`,
        conversationId,
      });
    }
  }
  return sent;
}

// True when either side of the conversation blocked the other.
// Fails open (false) when the check itself errors, matching
// isBlockedBetween / startConversation — the database is the real
// enforcement for a direct API call (see the coordinator's list).
// Pass { failClosed: true } for the one write the database does
// NOT back up: answering an offer (pm_validate_message_update has
// no blocked check), where a failed check must refuse rather than
// let a blocked student set the agreed price.
async function blockedWithOther(conversationId, userId, opts) {
  if (!conversationId || !userId) return false;
  const conv = await fetchConversation(conversationId);
  if (!conv) return false;
  const otherId =
    conv.buyer_id === userId ? conv.seller_id : conv.buyer_id;
  if (!otherId || otherId === userId) return false;
  return isBlockedBetween(userId, otherId, opts);
}

export async function sendOffer(conversationId, amount) {
  if (!supabase || !conversationId) return null;
  const n = Math.round(Number(amount) || 0);
  if (n <= 0) return null;
  // The ChatThread form caps offers at this amount, but sendOffer()
  // is callable from anywhere — without the cap here an offer of
  // ₦999,999,999 went straight through (the database only checks
  // offer_amount >= 0), and accepting it set that agreed price.
  // (The old hardcoded ₦10,000,000 check that used to sit here is
  // gone: it would have silently re-imposed the old cap after
  // Decision 7 raised it to ₦50,000,000.)
  if (n > MAX_OFFER_NAIRA) {
    return dbError(
      `Offer is too high — keep it under ₦${MAX_OFFER_NAIRA.toLocaleString("en-NG")}.`,
      "send offer"
    );
  }
  // Night deep check 2026-11-27: an offer above the asking price
  // used to be sendable and acceptable — it set an agreed price
  // above the listing price, so the chat banner promised a price
  // checkout would never charge (checkout caps at the listing
  // price). Refuse it here; the database (M23 respond_offer)
  // refuses it too. A failed price read fails open — the accept
  // is still refused server-side, so no money is at risk.
  const convForPrice = await fetchConversation(conversationId);
  if (convForPrice?.listing_id) {
    const { data: listingRow } = await supabase
      .from("listings")
      .select("price")
      .eq("id", convForPrice.listing_id)
      .maybeSingle();
    const asking = Number(listingRow?.price);
    if (Number.isFinite(asking) && asking > 0 && n > asking) {
      lastGateError = `That is above the asking price of ₦${asking.toLocaleString("en-NG")} — offer that amount or less.`;
      return dbError(lastGateError, "send offer");
    }
  }
  const senderId = await currentUserId();
  if (!senderId) return null;
  if (await blockedWithOther(conversationId, senderId)) {
    lastGateError = "You cannot message this student.";
    return dbError("You cannot message this student.", "send offer");
  }
  const sent = await insertMessage(conversationId, {
    body: `Offer: ₦${n.toLocaleString("en-NG")}`,
    kind: "offer",
    offer_amount: n,
    offer_status: "pending",
  });
  if (sent) {
    const conv = await fetchConversation(conversationId);
    if (conv) {
      const otherId = conv.buyer_id === senderId ? conv.seller_id : conv.buyer_id;
      notifyUser(otherId, {
        kind: "message",
        title: "New offer",
        body: `Offer: ₦${n.toLocaleString("en-NG")}`,
        link: `/chat/${conversationId}`,
        conversationId,
      });
    }
  }
  return sent;
}

// Accepting an offer sets conversations.agreed_price to the offer amount.
export async function respondOffer(messageId, decision) {
  if (!supabase || !messageId) return false;
  if (decision !== "accepted" && decision !== "declined") return false;
  const { data: msg, error: fetchError } = await supabase
    .from("messages")
    .select("id, conversation_id, sender_id, offer_amount, offer_status")
    .eq("id", messageId)
    .maybeSingle();
  if (fetchError || !msg || msg.offer_status !== "pending") {
    if (fetchError) dbError(fetchError, "fetch offer");
    return false;
  }
  // Never even send the update for your own offer: the database
  // trigger refuses self-accepts, but the app should not ask it to.
  // (ChatThread already hides the buttons for your own offers; this
  // covers any other caller of respondOffer.)
  const me = await currentUserId();
  if (!me || msg.sender_id === me) {
    dbError("You cannot accept or decline your own offer.", "respond to offer");
    return false;
  }
  // A blocked student cannot answer offers in an old chat either:
  // sendMessage / sendOffer / schedulePickup all refuse when either
  // side blocked the other, and respondOffer was the one gap — the
  // database refuses the message write, but answering an offer also
  // sets the agreed price, so refuse here first. Fail CLOSED here
  // (unlike the other paths): pm_validate_message_update has no
  // blocked check, so this app-side check is the ONLY thing
  // stopping a blocked student from answering an offer — if the
  // check itself errors, refuse rather than let the answer through.
  if (await blockedWithOther(msg.conversation_id, me, { failClosed: true })) {
    lastGateError = "You cannot message this student.";
    dbError("You cannot message this student.", "respond to offer");
    return false;
  }
  // Milestone 19: an offer cannot be answered in a chat where
  // either side is no longer an approved, unflagged student — a
  // later-rejected seller's pending offer must not become the
  // agreed price. (The database refuses the message update too,
  // but answering also sets conversations.agreed_price, so refuse
  // here first — same reasoning as the blocked check above.)
  const gateRefusal = await verificationGateRefusal(msg.conversation_id, me);
  if (gateRefusal) {
    lastGateError = gateRefusal;
    dbError(gateRefusal, "respond to offer");
    return false;
  }
  // Milestone 20 (M-24): answer the offer in ONE database move —
  // the respond_offer RPC flips the offer and sets (or clears)
  // conversations.agreed_price in a single transaction, so an
  // accepted offer can never end up with no agreed price. The RPC
  // lives in the Milestone 20 SQL; until that SQL runs it does not
  // exist, so fall back to the legacy two-step path below — but
  // ONLY when the RPC is missing (PGRST202 / 42883). Any other
  // error — including a gate refusal from inside the RPC — is a
  // real refusal and is returned as-is, never retried as a legacy
  // write.
  let usedRpc = false;
  try {
    const { error: rpcError } = await supabase.rpc("respond_offer", {
      p_message_id: messageId,
      p_status: decision,
    });
    if (rpcError) throw rpcError;
    usedRpc = true;
  } catch (err) {
    const code = String(err?.code || "");
    const message = String(err?.message || "");
    const rpcMissing =
      code === "PGRST202" ||
      code === "42883" ||
      /could not find the function/i.test(message) ||
      /function .*respond_offer.* does not exist/i.test(message);
    if (!rpcMissing) {
      lastGateError = message || "Could not update the offer. Try again.";
      dbError(err, "respond to offer");
      return false;
    }
    // RPC not switched on yet — the legacy path below runs instead.
  }
  if (!usedRpc) {
    const legacyOk = await respondOfferLegacy(msg, decision);
    if (!legacyOk) return false;
  }
  // Milestone 10: tell the student who made the offer.
  if (msg.sender_id) {
    notifyUser(msg.sender_id, {
      kind: "message",
      title: decision === "accepted" ? "Offer accepted" : "Offer declined",
      body: `Your offer of ₦${Number(msg.offer_amount || 0).toLocaleString("en-NG")} was ${decision}.`,
      link: `/chat/${msg.conversation_id}`,
      conversationId: msg.conversation_id,
    });
  }
  lastGateError = "";
  return true;
}

// The pre-Milestone-20 two-step answer: flip the offer (guarded so
// only the first of two racing answers lands), then set or clear
// the agreed price. Used only while the respond_offer RPC does not
// exist yet — see respondOffer above.
async function respondOfferLegacy(msg, decision) {
  const messageId = msg.id;
  const { data: updated, error } = await supabase
    .from("messages")
    .update({ offer_status: decision })
    .eq("id", messageId)
    .eq("offer_status", "pending")
    .select("id");
  if (error) {
    dbError(error, "respond to offer");
    return false;
  }
  // The pending guard above is the race guard: two answers racing
  // each other — only the first one updates a row. Zero rows means
  // the offer was already answered (or withdrawn) before this tap.
  if (!updated || updated.length === 0) {
    dbError("This offer was already answered.", "respond to offer");
    return false;
  }
  if (decision === "accepted" && msg.offer_amount) {
    // The offer is accepted already — the agreed price must follow.
    // Retry the price write once: a single failed write used to
    // leave an accepted offer with no agreed price and no way to
    // retry (the offer is no longer pending). A still-failing write
    // is a real problem, so say so plainly instead of pretending
    // the price was set.
    let convError = null;
    for (let attempt = 0; attempt < 2; attempt++) {
      const res = await supabase
        .from("conversations")
        .update({ agreed_price: msg.offer_amount })
        .eq("id", msg.conversation_id);
      convError = res.error || null;
      if (!convError) break;
    }
    if (convError) {
      dbError(convError, "set agreed price");
      return false;
    }
  }
  // (M21 §13, legacy mirror of the respond_offer RPC) Accepting one
  // offer answers the other pending offers the other student sent
  // in this conversation, so only one offer can stand accepted at
  // a time. Best effort: the accept already landed, so a failed
  // cleanup is logged, never thrown. Only the other student's
  // offers are declined — the message trigger refuses answering
  // your own offer.
  if (decision === "accepted") {
    try {
      const {
        data: { user },
      } = await supabase.auth.getUser();
      if (user?.id) {
        await supabase
          .from("messages")
          .update({ offer_status: "declined" })
          .eq("conversation_id", msg.conversation_id)
          .eq("kind", "offer")
          .eq("offer_status", "pending")
          .neq("id", messageId)
          .neq("sender_id", user.id);
      }
    } catch (err) {
      console.error(
        "[PulseMarket] Could not decline other pending offers:",
        err?.message || err
      );
    }
  }
  // A decline flips the message only. A pending offer never set the
  // agreed price, so nothing is cleared: an agreed price equal to
  // this amount belongs to a different accepted offer and must stay.
  return true;
}

export async function markRead(conversationId, userId) {
  if (!supabase || !conversationId || !userId) return false;
  const conv = await fetchConversation(conversationId);
  if (!conv) return false;
  const patch =
    conv.buyer_id === userId
      ? { buyer_last_read_at: new Date().toISOString() }
      : conv.seller_id === userId
        ? { seller_last_read_at: new Date().toISOString() }
        : null;
  if (!patch) return false;
  const { error } = await supabase
    .from("conversations")
    .update(patch)
    .eq("id", conversationId);
  if (error) {
    dbError(error, "mark conversation read");
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Pickup tickets — agree where and when to meet in chat. This only plans
// the meetup; the seller-code handoff arrives in Milestone 7.
// ---------------------------------------------------------------------------

export async function schedulePickup(conversationId, { spot, date, time }) {
  if (!supabase || !conversationId) return null;
  if (!spot || !date || !time) return null;
  // ChatThread validates all of this in the form, but schedulePickup()
  // is callable from anywhere — without the checks here a pickup in
  // the past, a date a year out, an invented spot, or a garbage time
  // saved straight to the table (the database has no checks on
  // pickup_tickets at all).
  if (!SAFE_MEETUP_SPOTS.includes(spot)) {
    return dbError("Pick a safe meetup spot from the list.", "schedule pickup");
  }
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const picked = new Date(`${date}T00:00:00`);
  if (Number.isNaN(picked.getTime())) {
    return dbError("Pick a valid date for the meetup.", "schedule pickup");
  }
  if (picked < today) {
    return dbError("That date is in the past — pick a date from today onwards.", "schedule pickup");
  }
  if (picked.getTime() - today.getTime() > 90 * 24 * 60 * 60 * 1000) {
    return dbError("Pick a date within the next 90 days.", "schedule pickup");
  }
  if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(String(time))) {
    return dbError("Pick a valid time for the meetup.", "schedule pickup");
  }
  const me = await currentUserId();
  if (!me) return null;
  const conv = await fetchConversation(conversationId);
  if (!conv) return null;
  if (conv.buyer_id !== me && conv.seller_id !== me) {
    return dbError("You can only plan a meetup for your own chat.", "schedule pickup");
  }
  if (await blockedWithOther(conversationId, me)) {
    lastGateError = "You cannot message this student.";
    return dbError("You cannot message this student.", "schedule pickup");
  }
  // Milestone 19: a meetup cannot be planned in a chat where
  // either side is no longer an approved, unflagged student.
  // (There is no app-side update path for pickup tickets — only
  // this insert — so the update half of the gate lives in the
  // database trigger, pm_validate_pickup_update.)
  const gateRefusal = await verificationGateRefusal(conversationId, me);
  if (gateRefusal) {
    lastGateError = gateRefusal;
    return dbError(gateRefusal, "schedule pickup");
  }
  const { data, error } = await supabase
    .from("pickup_tickets")
    .insert({
      conversation_id: conversationId,
      meetup_spot: spot,
      date,
      time,
      status: "scheduled",
    })
    .select()
    .single();
  if (error) {
    dbError(error, "schedule pickup");
    return null;
  }
  lastGateError = "";
  return data;
}

export async function fetchPickupTickets(conversationId) {
  if (!supabase || !conversationId) return [];
  const { data, error } = await supabase
    .from("pickup_tickets")
    .select("*")
    .eq("conversation_id", conversationId)
    .order("created_at", { ascending: false })
    .limit(100); // Bound: one chat's pickup plans, newest first.
  if (error) {
    dbError(error, "fetch pickup tickets");
    return [];
  }
  return data || [];
}

// ---------------------------------------------------------------------------
// Blocking
// ---------------------------------------------------------------------------

export async function blockUser(blockerId, blockedId) {
  if (!supabase || !blockerId || !blockedId || blockerId === blockedId) return false;
  const { error } = await supabase
    .from("blocked_users")
    .insert({ blocker_id: blockerId, blocked_id: blockedId });
  if (error) {
    dbError(error, "block user");
    return false;
  }
  return true;
}

export async function unblockUser(blockerId, blockedId) {
  if (!supabase || !blockerId || !blockedId) return false;
  const { error } = await supabase
    .from("blocked_users")
    .delete()
    .eq("blocker_id", blockerId)
    .eq("blocked_id", blockedId);
  if (error) {
    dbError(error, "unblock user");
    return false;
  }
  return true;
}

export async function fetchBlockedIds(userId) {
  if (!supabase || !userId) return [];
  const { data, error } = await supabase
    .from("blocked_users")
    .select("blocked_id")
    .eq("blocker_id", userId);
  if (error) {
    dbError(error, "fetch blocked users");
    return [];
  }
  return (data || []).map((r) => r.blocked_id);
}
