// Milestone 10 — Notifications data layer.
//
// Every function returns null / [] / 0 / false and logs the error when
// Supabase is not configured or the notifications table does not exist
// yet (owner has not run supabase/milestone-10.sql), so the app says so
// honestly instead of crashing. notifyUser() NEVER throws: a failed
// notification must never break the chat message, checkpoint, payment
// or release that triggered it.
//
// ---------------------------------------------------------------------------
// NOTIFY() CALL SITES — FOR THE COORDINATOR TO WIRE (this file does NOT
// call notifyUser() from anywhere else; the wiring below is the whole
// integration). Each site: call notifyUser() AFTER the main action
// succeeds, and NEVER await it in a way that blocks the action —
// notifyUser() already swallows its own failures, so `notifyUser(...)`
// without await is fine, or `void notifyUser(...)`.
// ---------------------------------------------------------------------------
// 1. sendMessage (src/lib/chat.js) — after the message is inserted:
//      const conv = await fetchConversation(conversationId);
//      const otherId = conv.buyer_id === senderId ? conv.seller_id : conv.buyer_id;
//      notifyUser(otherId, { kind: 'message', title: 'New message',
//        body: text.slice(0, 120), link: `/chat/${conversationId}`,
//        conversationId });
//    NOTE: sendMessage() today does not return the sender id — the
//    coordinator needs the sender (current user) id to work out the
//    other participant; fetchConversation() gives both ids.
// 2. sendOffer / respondOffer (src/lib/chat.js) — same pattern, kind
//    'message', link `/chat/${conversationId}`:
//      sendOffer:    title 'New offer', body `Offer: ₦${amount}`.
//      respondOffer: title 'Offer accepted' / 'Offer declined', body
//        `Your offer of ₦${amount} was accepted.` (notify the offer
//        sender — the other participant, not the responder).
// 3. addCheckpoint (src/lib/shipping.js) — after the checkpoint row is
//    inserted, notify the BUYER (kind 'checkpoint'):
//      notifyUser(order.buyer_id, { kind: 'checkpoint',
//        title: 'Parcel update', body: `${CHECKPOINT_LABELS[status]}${location ? ' — ' + location : ''}`,
//        link: `/tracking/${order.id}`, orderId: order.id });
//    Respects the buyer's checkpoints toggle (see toggle note below).
// 4. markPaid (src/lib/orders.js) — SKIP. The owner (PulseMarket team)
//    has no user row, so there is nobody to notify in-app. The owner
//    learns about a paid order from the order itself. Do not invent a
//    notification for the owner email.
// 5. confirmReceipt (src/lib/orders.js) — notify buyer + seller
//    (kind 'order', link `/order/${order.id}`):
//      buyer:  title 'Payment confirmed', body `Your transfer for order ${order.code} arrived — the money is now held.`;
//      seller: title 'Money held', body `The buyer paid for order ${order.code} — the money is held until delivery.`.
// 6. releaseOrder (src/lib/orders.js) — notify buyer + seller
//    (kind 'release', link `/order/${order.id}`):
//      buyer:  title 'Money released', body `The held money for order ${order.code} was released to the seller.`;
//      seller: title 'Money released', body `The held money for order ${order.code} is now in your available balance.`.
//    This covers manual releases AND the app-side auto-release, since
//    runAutoReleaseCheck() (src/lib/autoRelease.js) releases through
//    releaseOrder() and notifies both parties itself.
// 7. openReturn / resolveReturn (src/lib/shipping.js) — notify BOTH
//    parties (kind 'dispute', link `/order/${order.id}`):
//      openReturn:    title 'Return opened', body `A return was opened for order ${order.code}: ${reason}.`;
//      resolveReturn: title 'Return resolved', body `The return for order ${order.code} was resolved (${fault} fault).`.
//    Respects the disputes toggle (see below).
// 8. Boost ending — NO call site. "Boost ending soon" is derived on
//    the Notifications page from listings.boosted_until, not a stored
//    row. (A 'boost' kind exists for a future "boost bought"
//    notification if one is ever wanted.)
//
// ---------------------------------------------------------------------------
// HOW CROSS-USER NOTIFICATIONS LAND — insert_notification RPC
// (added by the coordinator in supabase/milestone-10.sql)
// ---------------------------------------------------------------------------
// A plain insert into notifications is refused by RLS unless the
// acting user IS the recipient (or the PulseMarket team account), so
// notifyUser() does NOT insert directly: it calls the SECURITY
// DEFINER function insert_notification() through supabase.rpc().
// The function only inserts when the caller is the recipient, a
// participant of the order/conversation the event belongs to, or the
// team account — so pass orderId (for order events) or
// conversationId (for chat events) in the options, or the insert is
// refused and notifyUser() returns null. Milestone 19 adds the
// recipient's server-side prefs (notification_prefs) as a second
// gate inside the same function: when the recipient turned that
// kind off, the insert is silently dropped and notifyUser()
// returns null. If the milestone-10.sql
// migration has not been run yet, the RPC does not exist and
// notifyUser() returns null — the action that triggered it is never
// affected.
// SETTINGS TOGGLES — Milestone 19: the RECIPIENT's server-side
// prefs (notification_prefs, read through get_notification_prefs()
// below and written from Settings) are the real gate, enforced
// inside insert_notification() itself. The device toggles in
// src/lib/store.js getSettings().notifications are only a display
// fallback now: Settings keeps a device copy in sync so the
// Notifications page hint still reads correctly, but notifyUser()
// NO LONGER checks the acting device's settings — a buyer
// messaging from their phone must never be able to silence the
// seller's notifications, and the old check did exactly that (it
// read the sender's device, not the recipient's). Kinds with no
// server row default to on, so a student who never touched
// Settings gets every notification, exactly as before.
import { supabase } from "./supabase";

export const NOTIFICATION_KINDS = [
  "order",
  "message",
  "checkpoint",
  "dispute",
  "rating",
  "boost",
  "release",
  "system",
];

export const KIND_LABELS = {
  order: "Order",
  message: "Message",
  checkpoint: "Delivery update",
  dispute: "Return / dispute",
  rating: "Rating",
  boost: "Boost",
  release: "Money released",
  system: "PulseMarket",
};

function dbError(err, where) {
  console.error(`[PulseMarket] ${where}:`, err?.message || err);
  return null;
}

// Server-side notification prefs (Milestone 19, table
// notification_prefs + RPCs in supabase/m19/04-notifications-release.sql).
// The RPCs take no user id: they always read/write the CALLER's own
// row, so a caller can never touch another student's prefs. A prefs
// object is { <kind>: boolean } for the 8 kinds in NOTIFICATION_KINDS.
// The server row stores <kind>_enabled columns; convert both ways
// here so the rest of the app only ever sees kind -> boolean.
// Both helpers return null (never throw) when the Milestone 19 SQL
// has not been run yet, so Settings falls back to the device
// toggles until then.
function prefsRowToMap(row) {
  if (!row) return null;
  const map = {};
  for (const kind of NOTIFICATION_KINDS) {
    map[kind] = row[`${kind}_enabled`] !== false;
  }
  return map;
}

export async function getNotificationPrefs() {
  if (!supabase) return null;
  const { data, error } = await supabase.rpc("get_notification_prefs");
  if (error) {
    dbError(error, "fetch notification prefs");
    return null;
  }
  return prefsRowToMap(data);
}

export async function setNotificationPrefs(patch) {
  if (!supabase || !patch) return null;
  const args = {};
  for (const kind of NOTIFICATION_KINDS) {
    if (Object.prototype.hasOwnProperty.call(patch, kind)) {
      args[`p_${kind}`] = patch[kind] !== false;
    }
  }
  if (Object.keys(args).length === 0) return null;
  const { data, error } = await supabase.rpc("set_notification_prefs", args);
  if (error) {
    dbError(error, "save notification prefs");
    return null;
  }
  return prefsRowToMap(data);
}

// Insert one notification for userId, through the insert_notification
// RPC (see the header note). Returns the inserted row id, or null when
// it was skipped (the recipient turned this kind off in their server
// prefs — the RPC returns null silently), not configured, or refused
// (including by the RPC's participant check). Never throws.
// The recipient's prefs are enforced server-side inside the RPC;
// this function no longer checks any device toggle (see header).
// Options: kind, title, body, link, plus orderId (order events) or
// conversationId (chat events) so the RPC can check the caller is a
// participant of that order/conversation.
export async function notifyUser(userId, { kind, title, body, link, orderId, conversationId } = {}) {
  if (!supabase || !userId) return null;
  if (!NOTIFICATION_KINDS.includes(kind)) {
    console.error(`[PulseMarket] notify user: unknown kind "${kind}".`);
    return null;
  }
  if (!title || !String(title).trim()) return null;
  // Clamp to the insert_notification RPC's caps (title 200, body 500,
  // link 500) instead of sending an overlong payload the server
  // rejects whole — a long checkpoint location used to drop the entire
  // notification. Links stay in-app only: the Notifications page
  // navigates to item.link, so an external URL stored here must never
  // be passed through.
  const cleanTitle = String(title).trim().slice(0, 200);
  const cleanBody = body ? String(body).trim().slice(0, 500) || null : null;
  const cleanLink =
    link && String(link).trim().startsWith("/") && !String(link).trim().startsWith("//")
      ? String(link).trim().slice(0, 500)
      : null;
  const { data, error } = await supabase.rpc("insert_notification", {
    p_user_id: userId,
    p_kind: kind,
    p_title: cleanTitle,
    p_body: cleanBody,
    p_link: cleanLink,
    p_order_id: orderId || null,
    p_conversation_id: conversationId || null,
  });
  if (error) return dbError(error, "notify user");
  return data ? { id: data } : null;
}

// Newest first, at most 100 rows per page. Pass `before` (a
// created_at value from the last row) to fetch the next page —
// without it a student with more than 100 notifications silently
// sees only the newest 100. The returned array carries `hasMore`.
export async function fetchNotifications(userId, { before } = {}) {
  if (!supabase || !userId) return [];
  let query = supabase
    .from("notifications")
    .select("*")
    .eq("user_id", userId)
    .order("created_at", { ascending: false });
  if (before) query = query.lt("created_at", before);
  const { data, error } = await query.limit(100);
  if (error) {
    dbError(error, "fetch notifications");
    return [];
  }
  const rows = data || [];
  rows.hasMore = rows.length === 100;
  return rows;
}

export async function fetchUnreadCount(userId) {
  if (!supabase || !userId) return 0;
  const { count, error } = await supabase
    .from("notifications")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .eq("is_read", false);
  if (error) {
    dbError(error, "fetch unread count");
    return 0;
  }
  return count || 0;
}

export async function markRead(id, userId) {
  if (!supabase || !id || !userId) return false;
  const { error } = await supabase
    .from("notifications")
    .update({ is_read: true })
    .eq("id", id)
    .eq("user_id", userId);
  if (error) {
    dbError(error, "mark notification read");
    return false;
  }
  return true;
}

export async function markAllRead(userId) {
  if (!supabase || !userId) return false;
  const { error } = await supabase
    .from("notifications")
    .update({ is_read: true })
    .eq("user_id", userId)
    .eq("is_read", false);
  if (error) {
    dbError(error, "mark all notifications read");
    return false;
  }
  return true;
}
