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
// re-reading the order through releaseOrder, which refuses any order
// that is no longer 'held'/'delivered'; the SQL function by checking
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
import { fetchMyOrders, releaseOrder } from "./orders";
import { OWNER_EMAIL } from "./payments";
import { notifyUser } from "./notifications";

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

  let orders = [];
  try {
    orders = await fetchMyOrders(currentUser.id);
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
      // Best-effort: tell both parties. notifyUser() goes through the
      // insert_notification RPC, which allows it because the caller
      // is a participant of this order. A refused insert returns null
      // and changes nothing here.
      notifyUser(order.buyer_id, {
        kind: "release",
        title: "Money released",
        body: `48 hours passed since delivery, so the held money for order ${order.code} was released to the seller.`,
        link: `/order/${order.id}`,
        orderId: order.id,
      });
      notifyUser(order.seller_id, {
        kind: "release",
        title: "Money released",
        body: `48 hours passed since delivery, so the held money for order ${order.code} is now in your available balance.`,
        link: `/order/${order.id}`,
        orderId: order.id,
      });
    } catch (err) {
      result.skipped.push({
        code: order.code,
        reason: err?.message || "Release failed.",
      });
    }
  }
  return result;
}
