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
import { supabase } from "./supabase";
import { notifyUser } from "./notifications";

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
    .select("user_id, chat_verified_only")
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
  // Last message preview + unread count per conversation.
  const enriched = await Promise.all(
    list.map(async (c) => {
      const isBuyer = c.buyer_id === userId;
      const lastRead = isBuyer ? c.buyer_last_read_at : c.seller_last_read_at;
      const { data: lastMsg } = await supabase
        .from("messages")
        .select("body, kind, offer_amount, sender_id, created_at")
        .eq("conversation_id", c.id)
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();
      let unread = 0;
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
      return { ...c, lastMessage: lastMsg || null, unreadCount: unread };
    })
  );
  return enriched;
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

export async function fetchMessages(conversationId) {
  if (!supabase || !conversationId) return [];
  const { data, error } = await supabase
    .from("messages")
    .select("*")
    .eq("conversation_id", conversationId)
    .order("created_at", { ascending: true });
  if (error) {
    dbError(error, "fetch messages");
    return [];
  }
  return data || [];
}

async function insertMessage(conversationId, row) {
  const senderId = await currentUserId();
  if (!senderId) return null;
  const { data, error } = await supabase
    .from("messages")
    .insert({ conversation_id: conversationId, sender_id: senderId, ...row })
    .select()
    .single();
  if (error) {
    dbError(error, "send message");
    return null;
  }
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
  const sent = await insertMessage(conversationId, { body: text, kind: "text" });
  if (sent) {
    // Milestone 10: tell the other participant (never blocks the send).
    const senderId = await currentUserId();
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

export async function sendOffer(conversationId, amount) {
  if (!supabase || !conversationId) return null;
  const n = Math.round(Number(amount) || 0);
  if (n <= 0) return null;
  const sent = await insertMessage(conversationId, {
    body: `Offer: ₦${n.toLocaleString("en-NG")}`,
    kind: "offer",
    offer_amount: n,
    offer_status: "pending",
  });
  if (sent) {
    const senderId = await currentUserId();
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
