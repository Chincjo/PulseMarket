// Milestone 10 — App-side 48h auto-release.
//
// HOW THIS RUNS (coordinator wiring): call runAutoReleaseCheck() on
// app open, AFTER sign-in — e.g. once in App.jsx when the user becomes
// available. Held money then releases even without pg_cron, because
// the check runs on the buyer's / seller's own device whenever they
// open the app. The SQL function auto_release_overdue_orders()
// (supabase/milestone-10.sql) is the server-side path for the same
// release, for when pg_cron is enabled — the two must never both be
// relied on blindly: each guards against double-release (this file by
// re-reading the order through releaseOrder, which (Milestone 17)
// refuses any order that is not 'delivered'; the SQL function by checking
// for an existing 'release' ledger entry). If pg_cron is live, this
// check is a harmless backup — it finds nothing due, because the
// server already released it.
//
// SYSTEM CALLER — read this: releaseOrder(orderId, user) in
// src/lib/orders.js only allows the BUYER of the order or the
// PulseMarket team (user.email === 'pulsemarketsupport@gmail.com').
// The timed release is the team acting, not the buyer, so this file
// calls releaseOrder() with a minimal system caller carrying the
// owner email: { email: OWNER_EMAIL }. No id is passed (there is no
// real signed-in user behind a timed release), and no password, key
// or session is involved — the database writes still happen under the
// signed-in user's own session and RLS, which allow any order
// participant to update the order and write its ledger rows. The
// handoff gate inside releaseOrder() still applies: a meet-in-person
// order whose handoff is incomplete is NOT released by this check —
// it is skipped and retried on the next app open.
//
// SKIPPED, NEVER RELEASED by this check:
//   - cash orders (settled face to face — no held money);
//   - orders with an open return (return_status 'opened') — the
//     PulseMarket team resolves the return first;
//   - orders whose delivered_at is less than 48 hours ago;
//   - orders that are not 'delivered' at all.
import { supabase } from "./supabase";
import { cancelOrder, fetchMyOrders, releaseOrder } from "./orders";
import { logSecurityEvent } from "./handoff";
import { notifyUser } from "./notifications";
import { OWNER_EMAIL } from "./payments";

export const AUTO_RELEASE_HOURS = 48;

// The system caller for releaseOrder(): the PulseMarket team, not a
// real user. releaseOrder() accepts it because its email matches the
// owner email (see the header note).
const SYSTEM_CALLER = { email: OWNER_EMAIL };

// Pure helper: is this order due for auto-release, and how long is
// left? Used by the Notifications page countdown and by
// runAutoReleaseCheck(). Never touches the network.
//   { due: boolean, hoursLeft: number | null }
// hoursLeft is the whole hours remaining until the 48h mark (null
// when delivered_at is missing). Cash orders are never due — there
// is no held money to release.
export function autoReleaseDue(order) {
  if (!order || order.status !== "delivered") {
    return { due: false, hoursLeft: null };
  }
  if (order.payment_method === "cash") {
    return { due: false, hoursLeft: null };
  }
  if (!order.delivered_at) {
    return { due: false, hoursLeft: null };
  }
  const deliveredAt = new Date(order.delivered_at).getTime();
  if (Number.isNaN(deliveredAt)) {
    return { due: false, hoursLeft: null };
  }
  const elapsedMs = Date.now() - deliveredAt;
  const totalMs = AUTO_RELEASE_HOURS * 60 * 60 * 1000;
  const remainingMs = totalMs - elapsedMs;
  return {
    due: remainingMs <= 0,
    hoursLeft: Math.max(0, Math.ceil(remainingMs / (60 * 60 * 1000))),
  };
}

// Release every due order the signed-in user is part of. `user` is the
// signed-in user object ({ id, ... }) — pass it when the caller has
// it, otherwise it is read from the session. Returns
//   { released: [orderCode, ...], skipped: [{ code, reason }, ...] }
// and never throws: a per-order failure (handoff incomplete, already
// released by the server, tables not switched on yet) is recorded in
// `skipped` and the rest still run.
export async function runAutoReleaseCheck(user) {
  const result = { released: [], skipped: [] };
  if (!supabase) return result;
  let currentUser = user || null;
  if (!currentUser) {
    const { data, error } = await supabase.auth.getUser();
    if (error || !data?.user) return result;
    currentUser = data.user;
  }
  if (!currentUser?.id) return result;

  // Loop every page of the user's orders (fetchMyOrders pages at
  // 200 rows with a { before } cursor + hasMore) instead of only
  // seeing the newest 200 — a delivered order past page 1 used to
  // never auto-release. Capped at 50 pages so a broken cursor can
  // never loop for ever.
  let orders = [];
  try {
    let before = null;
    for (let page = 0; page < 50; page++) {
      const rows = await fetchMyOrders(
        currentUser.id,
        before ? { before } : {}
      );
      orders = orders.concat(rows || []);
      if (rows?.hasMore !== true || rows.length === 0) break;
      before = rows[rows.length - 1]?.created_at || null;
      if (!before) break;
    }
  } catch (err) {
    console.error("[PulseMarket] auto-release check:", err?.message || err);
    return result;
  }

  for (const order of orders || []) {
    if (order.status !== "delivered") continue;
    if (order.payment_method === "cash") {
      result.skipped.push({
        code: order.code,
        reason: "Cash order — no held money to release.",
      });
      continue;
    }
    if (order.return_status === "opened") {
      result.skipped.push({
        code: order.code,
        reason: "A return is open — the PulseMarket team resolves it first.",
      });
      continue;
    }
    // Milestone 12: a frozen order (open dispute) never auto-releases.
    // `frozen` is undefined until supabase/milestone-12.sql is run,
    // which is safely falsy.
    if (order.frozen) {
      result.skipped.push({
        code: order.code,
        reason: "This order is frozen — a dispute is open.",
      });
      continue;
    }
    if (!autoReleaseDue(order).due) continue;
    try {
      await releaseOrder(order.id, SYSTEM_CALLER);
      result.released.push(order.code);
      // No notification here: releaseOrder's finishRelease already
      // tells both parties. Notifying again used to send every
      // auto-release twice (4 "Money released" rows per order).
    } catch (err) {
      result.skipped.push({
        code: order.code,
        reason: err?.message || "Release failed.",
      });
    }
  }
  return result;
}

// Milestone 20 (D-4): reservation expiry, app-side — cancel every
// 'reserved' order older than 48h and free the listing, so a buyer
// who ghosts after reserving can no longer brick the listing until
// someone cancels by hand. There is no pg_cron, so this sweep runs
// on sign-in and hourly next to runAutoReleaseCheck (see App.jsx).
//
// This is safe to run as the signed-in user: cancelOrder() lets the
// buyer or the seller cancel from 'reserved' (the seller only while
// still reserved) and puts the listing back to 'active', and a
// reserved order holds no money, so no ledger move is needed.
// A frozen order is skipped, never cancelled. Returns
//   { cancelled: [orderCode, ...], skipped: [{ code, reason }, ...] }
// and never throws: a per-order failure is recorded and the rest
// still run. Both parties are told: cancelOrder() notifies the
// OTHER side, and the sweep notifies the signed-in user too.
export const RESERVATION_EXPIRY_HOURS = 48;

export async function runReservationExpirySweep(user) {
  const result = { cancelled: [], skipped: [] };
  if (!supabase) return result;
  let currentUser = user || null;
  if (!currentUser) {
    const { data, error } = await supabase.auth.getUser();
    if (error || !data?.user) return result;
    currentUser = data.user;
  }
  if (!currentUser?.id) return result;

  // Same paging as runAutoReleaseCheck above: every page of the
  // user's orders, capped at 50 pages so a broken cursor can never
  // loop for ever.
  let orders = [];
  try {
    let before = null;
    for (let page = 0; page < 50; page++) {
      const rows = await fetchMyOrders(
        currentUser.id,
        before ? { before } : {}
      );
      orders = orders.concat(rows || []);
      if (rows?.hasMore !== true || rows.length === 0) break;
      before = rows[rows.length - 1]?.created_at || null;
      if (!before) break;
    }
  } catch (err) {
    console.error("[PulseMarket] reservation expiry sweep:", err?.message || err);
    return result;
  }

  const cutoff = Date.now() - RESERVATION_EXPIRY_HOURS * 60 * 60 * 1000;
  for (const order of orders || []) {
    if (order.status !== "reserved") continue;
    if (!order.created_at) continue;
    if (new Date(order.created_at).getTime() > cutoff) continue;
    if (order.frozen) {
      result.skipped.push({
        code: order.code,
        reason: "This order is frozen — a dispute is open.",
      });
      continue;
    }
    try {
      await cancelOrder(order.id, currentUser);
      // Milestone 22: a buyer can transfer the money off-app and
      // never tap "I have transferred", so a sweep-cancelled
      // 'reserved' order may already be paid for. Unlike cancelOrder
      // on a 'paid' order (which logs paid_order_cancelled), nothing
      // used to be logged here — the team had no prompt to check
      // whether a transfer arrived before treating it as unpaid.
      // Best effort: a logging failure must not undo the cancel.
      await logSecurityEvent(
        order.id,
        currentUser.id,
        "reserved_order_expired",
        `Reserved order ${order.code} expired after 48 hours without payment and was cancelled. Check whether the buyer transferred off-app before treating it as unpaid.`
      );
      await notifyUser(currentUser.id, {
        kind: "order",
        title: "Reserved order expired",
        body: `Order ${order.code} was reserved for more than 48 hours without payment, so it was cancelled and the item is listed again.`,
        link: `/order/${order.id}`,
        orderId: order.id,
      });
      result.cancelled.push(order.code);
    } catch (err) {
      result.skipped.push({
        code: order.code,
        reason: err?.message || "Cancel failed.",
      });
    }
  }
  return result;
}
