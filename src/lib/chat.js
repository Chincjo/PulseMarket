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
// - Only verified students chat: the sender must have a verifications row.
// - You cannot message yourself about your own listing.
// - If the seller set chat_verified_only, the buyer must be verified.
// - If either side blocked the other, no new chat can start.
// - Messages are capped at 1000 characters and a student cannot send
//   more than one message every 2 seconds (spam throttle, client-side).
// - Offers are capped at ₦10,000,000 (MAX_OFFER_NAIRA, enforced in
//   sendOffer as well as in the ChatThread form).
// - A blocked student cannot message in an existing chat either:
//   sendMessage / sendOffer / schedulePickup refuse when either side
//   blocked the other (startConversation only stops NEW chats).
// - A flagged account (5 wrong handoff codes) cannot start a new chat.
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
// (the database only checks offer_amount >= 0).
export const MAX_OFFER_NAIRA = 10000000;

// Minimum gap between two sends from the same device (spam throttle).
const SEND_THROTTLE_MS = 2000;
let lastSendAt = 0;

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
    .select("user_id, chat_verified_only, flagged")
    .eq("user_id", userId)
    .maybeSingle();
  if (error) return dbError(error, "fetch verification for chat");
  return data;
}

async function isBlockedBetween(a, b) {
  if (!supabase || !a || !b) return false;
  const { data, error } = await supabase
    .from("blocked_users")
    .select("blocker_id")
    .or(`and(blocker_id.eq.${a},blocked_id.eq.${b}),and(blocker_id.eq.${b},blocked_id.eq.${a})`);
  if (error) {
    dbError(error, "check blocked users");
    return false;
  }
  return (data || []).length > 0;
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

  // Only verified students chat.
  const buyerVerification = await fetchVerification(buyerId);
  if (!buyerVerification) {
    return {
      conversation: null,
      error: "Only verified students can chat. Get verified first.",
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
  // (The buyer is verified by the check above, but keep the rule explicit
  // so it still holds if the checks are ever reordered.)
  const sellerVerification = await fetchVerification(listing.seller_id);
  if (sellerVerification?.chat_verified_only && !buyerVerification) {
    return {
      conversation: null,
      error: "This seller only chats with verified students.",
    };
  }

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
export async function fetchConversations(userId) {
  if (!supabase || !userId) return [];
  const { data, error } = await supabase
    .from("conversations")
    .select("*")
    .or(`buyer_id.eq.${userId},seller_id.eq.${userId}`)
    .order("last_message_at", { ascending: false, nullsFirst: false });
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
  return enriched;
}

// The conversation for one listing and one student, if any — a single
// query, for pages (e.g. Tracking) that only need the chat link for
// one order instead of the whole chat list with previews.
export async function fetchConversationForListing(listingId, userId) {
  if (!supabase || !listingId || !userId) return null;
  const { data, error } = await supabase
    .from("conversations")
    .select("id")
    .eq("listing_id", listingId)
    .or(`buyer_id.eq.${userId},seller_id.eq.${userId}`)
    .order("last_message_at", { ascending: false, nullsFirst: false })
    .limit(1)
    .maybeSingle();
  if (error) return dbError(error, "fetch conversation for listing");
  return data || null;
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

export async function fetchMessages(conversationId) {
  if (!supabase || !conversationId) return [];
  // Newest 500, then back to oldest-first for the thread. Fetching
  // every message ever sent in a long chat, on every 10-second poll,
  // made old threads slower and slower.
  const { data, error } = await supabase
    .from("messages")
    .select("*")
    .eq("conversation_id", conversationId)
    .order("created_at", { ascending: false })
    .limit(500);
  if (error) {
    dbError(error, "fetch messages");
    return [];
  }
  return (data || []).reverse();
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
  // Spam throttle: one send per device every 2 seconds. The clock only
  // moves after a send succeeds, so a failed send never blocks a retry.
  if (Date.now() - lastSendAt < SEND_THROTTLE_MS) {
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
  if (await blockedWithOther(conversationId, senderId)) {
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
async function blockedWithOther(conversationId, userId) {
  if (!conversationId || !userId) return false;
  const conv = await fetchConversation(conversationId);
  if (!conv) return false;
  const otherId =
    conv.buyer_id === userId ? conv.seller_id : conv.buyer_id;
  if (!otherId || otherId === userId) return false;
  return isBlockedBetween(userId, otherId);
}

export async function sendOffer(conversationId, amount) {
  if (!supabase || !conversationId) return null;
  const n = Math.round(Number(amount) || 0);
  if (n <= 0) return null;
  if (n > 10000000) {
    console.error("[PulseMarket] send offer: offer is too high — keep it under ₦10,000,000.");
    return null;
  }
  // The ChatThread form caps offers at this amount, but sendOffer()
  // is callable from anywhere — without the cap here an offer of
  // ₦999,999,999 went straight through (the database only checks
  // offer_amount >= 0), and accepting it set that agreed price.
  if (n > MAX_OFFER_NAIRA) {
    return dbError(
      `Offer is too high — keep it under ₦${MAX_OFFER_NAIRA.toLocaleString("en-NG")}.`,
      "send offer"
    );
  }
  const senderId = await currentUserId();
  if (!senderId) return null;
  if (await blockedWithOther(conversationId, senderId)) {
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
  const { error } = await supabase
    .from("messages")
    .update({ offer_status: decision })
    .eq("id", messageId);
  if (error) {
    dbError(error, "respond to offer");
    return false;
  }
  if (decision === "accepted" && msg.offer_amount) {
    const { error: convError } = await supabase
      .from("conversations")
      .update({ agreed_price: msg.offer_amount })
      .eq("id", msg.conversation_id);
    if (convError) {
      dbError(convError, "set agreed price");
      return false;
    }
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
    return dbError("You cannot message this student.", "schedule pickup");
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
  return data;
}

export async function fetchPickupTickets(conversationId) {
  if (!supabase || !conversationId) return [];
  const { data, error } = await supabase
    .from("pickup_tickets")
    .select("*")
    .eq("conversation_id", conversationId)
    .order("created_at", { ascending: false });
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
