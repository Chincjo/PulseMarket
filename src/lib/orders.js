// Milestone 6 — Orders + manual escrow. Every function returns null / []
// and logs the error when the tables do not exist yet (owner has not run
// supabase/milestone-6.sql), so the app says so honestly instead of
// crashing. Money functions re-read the order first and refuse invalid
// transitions with a clear Error.
//
// Money model (manual escrow):
//   - Cash orders are settled face to face. No money ever touches the
//     ledger for them: reserved -> delivered (buyer confirms the meetup
//     happened) and the listing becomes sold. Nothing is held, nothing
//     is released.
//   - Held orders: buyer transfers to PulseMarket (reference = order
//     code). The owner confirms the transfer arrived: reserved -> paid
//     -> held, and one ledger entry puts the full total in the seller's
//     "held" bucket. Buyer confirms delivery: held/shipped -> delivered.
//     Release (buyer or owner, Milestone 17): delivered -> available
//     only — a held order cannot release, so money never moves
//     before the buyer confirms delivery. The seller's available
//     balance gains the item price + the shipping fee; the service and
//     secure fees stay with PulseMarket, so they never enter "available".
//     If a shipping advance was already released (Milestone 8), the
//     release subtracts it from both legs, so the seller is never paid
//     the advance twice — same math as the Milestone 10 SQL function
//     auto_release_overdue_orders(). A frozen order (open dispute,
//     Milestone 12) cannot be confirmed or released until the team
//     resolves it.
import { supabase } from "./supabase";
import { feeBreakdown } from "./fees";
import { updateListing } from "./listings";
import { handoffComplete, logSecurityEvent } from "./handoff";
import { notifyUser } from "./notifications";
import {
  OWNER_EMAIL,
  PAYMENTS_MODE,
  shippingZone,
} from "./payments";

export { PAYMENTS_MODE };

function dbError(err, where) {
  console.error(`[PulseMarket] ${where}:`, err?.message || err);
  return null;
}

// Order codes: PM-ORD- + 6 uppercase letters/digits. The buyer uses the
// code as the bank-transfer reference, so it must be unique and readable.
export function generateOrderCode() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = new Uint32Array(6);
  if (typeof crypto !== "undefined" && crypto.getRandomValues) {
    crypto.getRandomValues(bytes);
  } else {
    for (let i = 0; i < 6; i++) bytes[i] = Math.floor(Math.random() * 0xffffffff);
  }
  let code = "";
  for (let i = 0; i < 6; i++) {
    code += chars[bytes[i] % chars.length];
  }
  return `PM-ORD-${code}`;
}

function isOwner(user) {
  return user?.email === OWNER_EMAIL;
}

// Single internal helper for every ledger write. `moves` is an array of
// { userId, bucket, kind, amount, note } — paired entries (e.g. release:
// -total out of "held", +item+shipping into "available") are written in
// one insert so the ledger can never hold half a move.
async function recordLedgerMove(order, moves) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const rows = moves.map((m) => ({
    order_id: order.id,
    user_id: m.userId,
    bucket: m.bucket,
    kind: m.kind,
    amount: m.amount,
    note: m.note || null,
    created_by: order.buyer_id,
  }));
  const { error } = await supabase.from("wallet_ledger").insert(rows);
  if (error) throw error;
}

async function readOrder(id) {
  if (!supabase || !id) return null;
  const { data, error } = await supabase
    .from("orders")
    .select("*")
    .eq("id", id)
    .maybeSingle();
  if (error) return dbError(error, "fetch order");
  return data;
}

// Shipping advance already paid out for this order (Milestone 8:
// kind 'shipping_advance' in the seller's available bucket). The
// release subtracts it so the seller is never paid the same money
// twice. Returns 0 when the ledger table is missing.
async function advanceAlreadyReleased(orderId) {
  if (!supabase || !orderId) return 0;
  const { data, error } = await supabase
    .from("wallet_ledger")
    .select("amount")
    .eq("order_id", orderId)
    .eq("kind", "shipping_advance")
    .eq("bucket", "available");
  if (error) {
    dbError(error, "read shipping advance");
    return 0;
  }
  return (data || []).reduce((sum, r) => sum + (Number(r.amount) || 0), 0);
}

// Has a money move of this kind already been written for the order?
// The database also enforces it (one-per-order unique indexes in
// supabase/milestone-14.sql), but checking first gives the buyer a
// plain-English error instead of a database error, and stops a
// double-click from ever reaching the ledger.
async function ledgerMoveExists(orderId, kind, bucket) {
  if (!supabase || !orderId) return false;
  let query = supabase
    .from("wallet_ledger")
    .select("id")
    .eq("order_id", orderId)
    .eq("kind", kind)
    .limit(1);
  if (bucket) query = query.eq("bucket", bucket);
  const { data, error } = await query;
  if (error) {
    dbError(error, "check ledger move");
    return false;
  }
  return (data || []).length > 0;
}

async function updateOrder(id, patch) {
  const { data, error } = await supabase
    .from("orders")
    .update({ ...patch, updated_at: new Date().toISOString() })
    .eq("id", id)
    .select()
    .single();
  if (error) throw error;
  return data;
}

async function currentUserId() {
  if (!supabase) return null;
  const { data } = await supabase.auth.getUser();
  return data?.user?.id || null;
}

// The delivery PIN belongs to the buyer only (they share it with the
// courier at handover). Page-facing reads strip it from any order
// the signed-in user did not buy — the PIN never sits in a seller's
// or the team's page state. Internal money functions keep using
// readOrder() (full row); only the buyer-only PIN check
// (confirmDeliveryWithPin, in shipping.js) ever reads the PIN, and
// it reads it through its own readOrder(). A direct API call still
// returns the full row (see the coordinator's report: hiding it
// from a determined caller needs a server-side fetch), and the
// order-update trigger already refuses any delivery confirmation
// that is not the buyer's.
function withoutPin(order, viewerId) {
  if (!order || !("delivery_pin" in order)) return order;
  if (viewerId && order.buyer_id === viewerId) return order;
  const { delivery_pin: _delivery_pin, ...rest } = order;
  return rest;
}

// ---------------------------------------------------------------------------
// Create + read
// ---------------------------------------------------------------------------

// buyerState comes from the buyer's verification record (their
// university's state) and decides the shipping zone. Pass "" when it is
// unknown — the zone then defaults to same-state and the team confirms
// the real shipping fee when the parcel is booked.
export async function createOrder({
  listing,
  buyerId,
  paymentMethod,
  deliveryMethod,
  meetupSpot,
  shipToState,
  courier,
  buyerState,
}) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!listing || !buyerId) throw new Error("Missing listing or buyer.");
  if (listing.seller_id === buyerId) {
    throw new Error("You cannot buy your own listing.");
  }
  if (listing.status !== "active") {
    throw new Error("This item is no longer available.");
  }
  if (!["cash", "held"].includes(paymentMethod)) {
    throw new Error("Choose cash or pay through the app.");
  }
  // Cash is paid face to face, so it always means meeting in
  // person: the app has no shipped path for a cash order (shipping
  // proof needs status 'held', which a cash order never reaches),
  // so a cash + shipping order could never ship or complete.
  if (paymentMethod === "cash" && deliveryMethod === "shipping") {
    throw new Error("Cash is paid face to face — choose meet in person for cash orders.");
  }
  if (!["meetup", "shipping"].includes(deliveryMethod)) {
    throw new Error("Choose meet in person or shipping.");
  }
  if (deliveryMethod === "meetup" && !meetupSpot) {
    throw new Error("Choose a safe meetup spot.");
  }
  if (deliveryMethod === "shipping" && !shipToState) {
    throw new Error("Choose the state to ship to.");
  }
  // The delivery method must be one the seller actually offers — a
  // direct call used to be able to order shipping on a meetup-only
  // listing (and vice versa).
  if (Array.isArray(listing.delivery_methods) && listing.delivery_methods.length > 0) {
    if (!listing.delivery_methods.includes(deliveryMethod)) {
      throw new Error(
        deliveryMethod === "shipping"
          ? "This seller does not ship this item — meet in person instead."
          : "This seller does not offer meet-in-person for this item — choose shipping instead."
      );
    }
  }
  // A same-state-only listing never leaves the seller's state, and a
  // meetup only makes sense in the seller's state either.
  if (listing.ships_to === "same_state" && listing.state) {
    if (deliveryMethod === "shipping" && shipToState && shipToState !== listing.state) {
      throw new Error(`This item only ships within ${listing.state}.`);
    }
    if (deliveryMethod === "meetup" && buyerState && buyerState !== listing.state) {
      throw new Error(`This item is only for students in ${listing.state}.`);
    }
  }

  const fees = feeBreakdown(
    listing.price,
    paymentMethod === "cash" ? "cash" : "held"
  );
  // The shipping zone is priced from the ship-to state — the parcel
  // goes where ship_to_state says, not where the buyer's university
  // is. (Pricing it from buyerState charged the wrong zone whenever
  // the two differed, and the total shown at checkout did not match
  // the total charged. The server re-derives the same fee in
  // supabase/milestone-15.sql.) Fall back to buyerState only when
  // no ship-to state was picked, matching the checkout display.
  const zone =
    deliveryMethod === "shipping"
      ? shippingZone(shipToState || buyerState, listing.state)
      : null;
  const shippingFee = zone ? zone.fee : 0;
  const total = fees.total + shippingFee;

  const { data, error } = await supabase
    .from("orders")
    .insert({
      code: generateOrderCode(),
      listing_id: listing.id,
      buyer_id: buyerId,
      seller_id: listing.seller_id,
      item_price: fees.price,
      service_fee: fees.serviceFee,
      secure_fee: fees.secureFee,
      shipping_fee: shippingFee,
      total,
      payment_method: paymentMethod,
      delivery_method: deliveryMethod,
      status: "reserved",
      meetup_spot: deliveryMethod === "meetup" ? meetupSpot : null,
      ship_to_state: deliveryMethod === "shipping" ? shipToState : null,
      courier: deliveryMethod === "shipping" ? courier || null : null,
    })
    .select()
    .single();
  if (error) {
    // Two buyers reserving the same item at the same time: the
    // second insert hits the one-open-order-per-listing index
    // (supabase/milestone-15.sql) — say so plainly.
    if (
      error?.code === "23505" &&
      String(error.message || "").includes("orders_one_open_order_per_listing_idx")
    ) {
      throw new Error("This item was just reserved by someone else — try another item.");
    }
    throw error;
  }

  // Hold the listing so nobody else can buy it while this order is open.
  // If that fails, remove the order again rather than leaving a stray.
  // There is no DELETE policy on orders, so a direct delete is refused
  // by the database — fall back to cancelling the order instead, which
  // the order rules do allow (reserved -> cancelled, buyer).
  try {
    await updateListing(listing.id, { status: "reserved" });
  } catch (err) {
    try {
      const { error: delError } = await supabase
        .from("orders")
        .delete()
        .eq("id", data.id);
      if (delError) {
        await supabase
          .from("orders")
          .update({ status: "cancelled", updated_at: new Date().toISOString() })
          .eq("id", data.id);
      }
    } catch {
      // Best effort only — the order is still 'reserved' and the
      // listing was never held, so the buyer sees the error and the
      // team can cancel the stray order by hand.
    }
    throw err;
  }
  return data;
}

export async function fetchOrder(id) {
  const order = await readOrder(id);
  if (!order) return null;
  return withoutPin(order, await currentUserId());
}

// Newest first, at most 200 rows per page. Pass `before` (a
// created_at value from the last row) to fetch the next page —
// without it a student with more than 200 orders silently sees
// only the newest 200. The returned array carries `hasMore`
// (true when a full page came back, so another page may exist).
export async function fetchMyOrders(userId, { before } = {}) {
  if (!supabase || !userId) return [];
  let query = supabase
    .from("orders")
    .select("*")
    .or(`buyer_id.eq.${userId},seller_id.eq.${userId}`)
    .order("created_at", { ascending: false });
  if (before) query = query.lt("created_at", before);
  const { data, error } = await query.limit(200);
  if (error) {
    dbError(error, "fetch my orders");
    return [];
  }
  const rows = (data || []).map((o) => withoutPin(o, userId));
  rows.hasMore = (data || []).length === 200;
  return rows;
}

export async function fetchOrdersForListing(listingId) {
  if (!supabase || !listingId) return [];
  const { data, error } = await supabase
    .from("orders")
    .select("*")
    .eq("listing_id", listingId)
    .order("created_at", { ascending: false })
    .limit(100);
  if (error) {
    dbError(error, "fetch orders for listing");
    return [];
  }
  const viewerId = await currentUserId();
  return (data || []).map((o) => withoutPin(o, viewerId));
}

// ---------------------------------------------------------------------------
// Money transitions — each re-reads the order and refuses bad transitions.
// ---------------------------------------------------------------------------

// Buyer says "I have transferred" (held orders only). The money is NOT
// held yet — the owner must still confirm the transfer arrived.
export async function markPaid(orderId, userId) {
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
  if (order.payment_method === "cash") {
    throw new Error("Cash orders are paid face to face — nothing to transfer.");
  }
  if (userId && order.buyer_id !== userId) {
    throw new Error("Only the buyer can mark this order as paid.");
  }
  if (order.status !== "reserved") {
    throw new Error(`This order is ${order.status} — it cannot be marked as paid.`);
  }
  return updateOrder(orderId, { status: "paid", paid_at: new Date().toISOString() });
}

// Owner only: the bank transfer arrived, so the money is now HELD for
// the seller. One ledger entry puts the full total in the seller's
// "held" bucket.
export async function confirmReceipt(orderId, user) {
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (!isOwner(user)) {
    throw new Error("Only the PulseMarket team can confirm a bank transfer arrived.");
  }
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
  // The double-confirm check comes before the status check on purpose:
  // a retry after a completed confirm (status already 'held', hold row
  // already written) must return the order, not throw "there is no
  // transfer to confirm" for a transfer that was already confirmed.
  if (await ledgerMoveExists(order.id, "hold", "held")) {
    return finishHeld();
  }
  if (order.status !== "paid") {
    throw new Error(`This order is ${order.status} — there is no transfer to confirm.`);
  }
  // Double-confirm guard: the money must enter hold exactly once.
  // The database refuses a second hold row too (unique index in
  // supabase/milestone-14.sql); this check gives the plain error.
  // BUT a hold row can exist while the order still says 'paid' — the
  // money moved, then the status update never landed (network
  // dropped). Throwing "already confirmed" then would leave the
  // order stuck in 'paid' for ever, so finish the move instead.
  async function finishHeld() {
    if (order.status === "held") return order;
    if (order.status !== "paid") {
      throw new Error("This transfer was already confirmed — the money is already held.");
    }
    const updated = await updateOrder(orderId, { status: "held", held_at: new Date().toISOString() });
    // The first attempt moved the money but never sent these (it died
    // before the status update), so send them on the recovery run.
    notifyUser(order.buyer_id, {
      kind: "order",
      title: "Payment confirmed",
      body: `Your transfer for order ${order.code} arrived — the money is now held.`,
      link: `/order/${order.id}`,
      orderId: order.id,
    });
    notifyUser(order.seller_id, {
      kind: "order",
      title: "Money held",
      body: `The buyer paid for order ${order.code} — the money is held until delivery.`,
      link: `/order/${order.id}`,
      orderId: order.id,
    });
    return updated;
  }
  try {
    await recordLedgerMove(order, [
      {
        userId: order.seller_id,
        bucket: "held",
        kind: "hold",
        amount: order.total,
        note: `Held for order ${order.code}`,
      },
    ]);
  } catch (err) {
    if (err?.code === "23505") {
      return finishHeld();
    }
    throw err;
  }
  const updated = await updateOrder(orderId, { status: "held", held_at: new Date().toISOString() });
  notifyUser(order.buyer_id, {
    kind: "order",
    title: "Payment confirmed",
    body: `Your transfer for order ${order.code} arrived — the money is now held.`,
    link: `/order/${order.id}`,
    orderId: order.id,
  });
  notifyUser(order.seller_id, {
    kind: "order",
    title: "Money held",
    body: `The buyer paid for order ${order.code} — the money is held until delivery.`,
    link: `/order/${order.id}`,
    orderId: order.id,
  });
  return updated;
}

// Milestone 9 gate: a shipping order is confirmed delivered only
// when the buyer has a verified unboxing video for it (kind
// 'unboxing', media_type 'video', verified=true). Meet-in-person
// orders are gated by the Milestone 7 handoff instead, so this
// helper does nothing for them. If the evidence table does not exist
// yet (the owner has not run supabase/milestone-9.sql), delivery
// FAILS OPEN with a console warning — a missing table must not block
// a real delivery.
async function requireUnboxingEvidence(order) {
  if (!order || order.delivery_method !== "shipping") return;
  if (!supabase) return;
  const { data, error } = await supabase
    .from("evidence")
    .select("id")
    .eq("order_id", order.id)
    .eq("kind", "unboxing")
    .eq("media_type", "video")
    .eq("verified", true)
    .limit(1);
  if (error) {
    const code = String(error.code || "");
    const message = String(error.message || "");
    const missingTable =
      code === "42P01" ||
      code === "PGRST205" ||
      /relation .* does not exist|Could not find the table/i.test(message);
    if (missingTable) {
      console.warn(
        "[PulseMarket] Evidence table not found — delivery gate skipped. Run supabase/milestone-9.sql to switch on the Evidence Locker."
      );
      return;
    }
    dbError(error, "check unboxing evidence");
    throw new Error(
      "Add your unboxing video first — it must be recorded in the app and no longer than 60 seconds."
    );
  }
  if (!data || data.length === 0) {
    throw new Error(
      "Add your unboxing video first — it must be recorded in the app and no longer than 60 seconds."
    );
  }
}

// Buyer confirms the item arrived. NOTE: Milestone 9 adds the photo/video
// evidence requirement to this step. Milestone 7 gate: for meet-in-person
// orders the buyer confirms delivery only after the handoff — the code
// scanned, both handover photos taken and both sides confirmed.
export async function confirmDelivery(orderId, userId) {
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (userId && order.buyer_id !== userId) {
    throw new Error("Only the buyer can confirm delivery.");
  }
  // A frozen order (open dispute) cannot be confirmed delivered
  // until the PulseMarket team resolves it — same rule as release.
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
  const now = new Date().toISOString();
  if (order.payment_method === "cash") {
    // Cash was settled face to face, so there is no held money to
    // release. Confirming the meetup closes the order and sells the item.
    if (order.status !== "reserved") {
      throw new Error(`This order is ${order.status} — delivery cannot be confirmed.`);
    }
    if (order.delivery_method === "meetup" && !handoffComplete(order)) {
      await logSecurityEvent(orderId, userId, "delivery_blocked", `Delivery confirmation blocked — handoff not complete for order ${order.code}.`);
      throw new Error("Handoff not complete — the buyer must scan the seller code and both sides must confirm with photos.");
    }
    await requireUnboxingEvidence(order);
    const updated = await updateOrder(orderId, { status: "delivered", delivered_at: now });
    try {
      await updateListing(order.listing_id, { status: "sold" });
    } catch (err) {
      console.error("[PulseMarket] delivery: could not mark listing sold:", err?.message || err);
    }
    return updated;
  }
  if (!["held", "shipped"].includes(order.status)) {
    throw new Error(`This order is ${order.status} — delivery cannot be confirmed yet.`);
  }
  if (order.delivery_method === "meetup" && !handoffComplete(order)) {
    await logSecurityEvent(orderId, userId, "delivery_blocked", `Delivery confirmation blocked — handoff not complete for order ${order.code}.`);
    throw new Error("Handoff not complete — the buyer must scan the seller code and both sides must confirm with photos.");
  }
  await requireUnboxingEvidence(order);
  return updateOrder(orderId, { status: "delivered", delivered_at: now });
}

// Buyer confirming, or the owner: release the held money to the seller.
// Milestone 17: only from 'delivered' — a held order cannot release,
// so money never moves before the buyer confirms delivery.
// Two ledger entries: the full total leaves "held", and the item price +
// shipping fee enters "available". The service and secure fees stay with
// PulseMarket and never enter the seller's available balance.
export async function releaseOrder(orderId, user) {
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.payment_method === "cash") {
    throw new Error("Cash orders are settled face to face — there is no held money to release.");
  }
  const allowed =
    (user && order.buyer_id === user.id) || isOwner(user);
  if (!allowed) {
    throw new Error("Only the buyer or the PulseMarket team can release this order.");
  }
  // The double-release check comes before the status / frozen /
  // handoff gates on purpose: a retry after a completed release
  // (money moved, order already 'released') must finish quietly —
  // including marking the listing sold — not throw "there is no held
  // money to release" for money that was already released.
  if (await ledgerMoveExists(order.id, "release", "held")) {
    return finishRelease();
  }
  // Milestone 17: release opens only after delivery is confirmed.
  // A held order cannot release — the money stays held until the
  // buyer confirms the item arrived, so a buyer can never release
  // before the item ships. The buyer is told what to do next
  // instead of getting a cryptic refusal.
  if (order.status === "held") {
    throw new Error(
      "The money is still held — release opens once delivery is confirmed. Confirm delivery first, then release the money to the seller."
    );
  }
  if (order.status !== "delivered") {
    throw new Error(`This order is ${order.status} — there is no held money to release.`);
  }
  // Milestone 12 gate: a frozen order (open dispute) cannot release
  // until the PulseMarket team resolves it. `frozen` is undefined
  // until supabase/milestone-12.sql is run, which is safely falsy.
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
  // A return that is open stops any release: the money must stay
  // put until the team resolves the return, or the refund would
  // have nothing left to pay from.
  if (order.return_status === "opened") {
    throw new Error("A return is open for this order — the PulseMarket team resolves it first.");
  }
  // Milestone 7 gate: a meet-in-person order releases only after the
  // handoff is complete — code scanned, both photos, both confirmations.
  if (order.delivery_method === "meetup" && !handoffComplete(order)) {
    await logSecurityEvent(orderId, user?.id, "release_blocked", `Release blocked — handoff not complete for order ${order.code}.`);
    throw new Error("Handoff not complete — the buyer must scan the seller code and both sides must confirm with photos.");
  }
  // Milestone 8 advance: part of the shipping fee may already sit in
  // the seller's available bucket. Release only what is still held,
  // so the seller is never paid the advance twice — same math as the
  // Milestone 10 SQL function auto_release_overdue_orders().
  const advance = await advanceAlreadyReleased(order.id);
  const heldAmount = -Math.max(0, order.total - advance);
  const availableAmount = Math.max(
    0,
    order.item_price + ((order.shipping_fee || 0) - advance)
  );
  // Double-release guard: the money must leave hold exactly once.
  // The database refuses a second release pair too (unique indexes
  // in supabase/milestone-14.sql); this check gives the plain error
  // and stops a double-click or two racing devices from paying twice.
  // BUT a release pair can exist while the order still says
  // 'delivered' — the money moved, then the status update never
  // landed (network dropped). Throwing "already released" then would
  // leave the order stuck for ever, so finish the move instead.
  // (A pair with the order still 'held' is a pre-Milestone-17
  // leftover — finishRelease refuses it in plain words; the team
  // closes it out by hand.)
  async function finishRelease() {
    // A frozen order never completes its release — same rule as
    // the first attempt. Without this check a retry after a
    // completed release (money moved, status not updated) would
    // surface the database's frozen error instead of a plain one.
    if (order.frozen) {
      throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
    }
    // A return opened after the money moved still stops the
    // release from completing — the team resolves the return first.
    if (order.return_status === "opened") {
      throw new Error("A return is open for this order — the PulseMarket team resolves it first.");
    }
    // The listing flip is best effort: if it fails the money has
    // still moved and the order is still closed out — the seller can
    // mark the listing sold by hand, and the next load retries it.
    async function markSold() {
      try {
        await updateListing(order.listing_id, { status: "sold" });
      } catch (err) {
        console.error("[PulseMarket] release: could not mark listing sold:", err?.message || err);
      }
    }
    if (order.status === "released") {
      await markSold();
      return order;
    }
    // Milestone 17: same rule as the first attempt — only a
    // delivered order completes its release. A held order with a
    // release pair is a leftover from before this rule (the money
    // already moved, but the status update never landed); it cannot
    // close out here, because the database refuses held -> released
    // — the team closes it out by hand instead of stranding it
    // silently, and the buyer is told so in plain words.
    if (order.status === "held") {
      throw new Error(
        "This order's release already went through while it was held — the PulseMarket team will close the order out. Nothing more was charged."
      );
    }
    if (order.status !== "delivered") {
      throw new Error("This order was already released — the money moved once.");
    }
    const updated = await updateOrder(orderId, {
      status: "released",
      released_at: new Date().toISOString(),
    });
    await markSold();
    notifyUser(order.buyer_id, {
      kind: "release",
      title: "Money released",
      body: `The held money for order ${order.code} was released to the seller.`,
      link: `/order/${order.id}`,
      orderId: order.id,
    });
    notifyUser(order.seller_id, {
      kind: "release",
      title: "Money released",
      body: `The held money for order ${order.code} is now in your available balance.`,
      link: `/order/${order.id}`,
      orderId: order.id,
    });
    return updated;
  }
  try {
    await recordLedgerMove(order, [
      {
        userId: order.seller_id,
        bucket: "held",
        kind: "release",
        amount: heldAmount,
        note: `Released from hold for order ${order.code}`,
      },
      {
        userId: order.seller_id,
        bucket: "available",
        kind: "release",
        amount: availableAmount,
        note: `Released to seller for order ${order.code}`,
      },
    ]);
  } catch (err) {
    if (err?.code === "23505") {
      return finishRelease();
    }
    throw err;
  }
  const updated = await updateOrder(orderId, {
    status: "released",
    released_at: new Date().toISOString(),
  });
  try {
    await updateListing(order.listing_id, { status: "sold" });
  } catch (err) {
    console.error("[PulseMarket] release: could not mark listing sold:", err?.message || err);
  }
  notifyUser(order.buyer_id, {
    kind: "release",
    title: "Money released",
    body: `The held money for order ${order.code} was released to the seller.`,
    link: `/order/${order.id}`,
    orderId: order.id,
  });
  notifyUser(order.seller_id, {
    kind: "release",
    title: "Money released",
    body: `The held money for order ${order.code} is now in your available balance.`,
    link: `/order/${order.id}`,
    orderId: order.id,
  });
  return updated;
}

// Owner only: refund a HELD order whose seller never ships.
// Until now a held order had no exit at all when the seller went
// quiet: cancel only works from reserved/paid, a return needs the
// order shipped/delivered, and resolving a dispute only unfreezes
// — so the buyer's money sat in hold for ever. The buyer gets the
// item price + shipping back (same as a seller-fault return; the
// service and secure fees stay with PulseMarket) and the listing
// goes back to active. No shipping advance can exist while the
// order is still held (an advance is only paid after held ->
// shipped), so no seller debt is recorded.
// NOTE: this needs supabase/milestone-16.sql — until it runs, the
// database refuses a refund from a held order with no open return
// (pm_validate_ledger_insert + pm_validate_order_update), and this
// throws that database error. The team resolves any open dispute
// first: a frozen order cannot be refunded.
export async function refundHeldOrder(orderId, user) {
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (!isOwner(user)) {
    throw new Error("Only the PulseMarket team can refund a held order.");
  }
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
  if (order.payment_method !== "held") {
    throw new Error("Only held orders can be refunded this way — cash orders are settled face to face.");
  }
  if (order.return_status === "opened") {
    throw new Error("A return is open for this order — resolve the return instead.");
  }
  if (order.status !== "held") {
    throw new Error(`This order is ${order.status} — only a held order can be refunded this way.`);
  }
  // Double-refund guard: the refund must move exactly once. A
  // refund row can exist while the order still says 'held' — the
  // money moved, then the status update never landed. Close the
  // order out instead of moving money again.
  async function closeOut(note) {
    const closed = await updateOrder(orderId, { status: "refunded" });
    try {
      await updateListing(order.listing_id, { status: "active" });
    } catch (err) {
      console.error("[PulseMarket] refund: could not put listing back to active:", err?.message || err);
    }
    notifyUser(order.buyer_id, {
      kind: "dispute",
      title: "Order refunded",
      body: `Order ${order.code} was refunded — the seller never shipped it.`,
      link: `/order/${order.id}`,
      orderId: order.id,
    });
    notifyUser(order.seller_id, {
      kind: "dispute",
      title: "Order refunded",
      body: `Order ${order.code} was refunded — the item never shipped.`,
      link: `/order/${order.id}`,
      orderId: order.id,
    });
    return { order: closed, note };
  }
  if (supabase) {
    const { data: existingRefund } = await supabase
      .from("wallet_ledger")
      .select("id")
      .eq("order_id", order.id)
      .eq("kind", "refund")
      .eq("bucket", "held")
      .limit(1);
    if (existingRefund && existingRefund.length > 0) {
      return closeOut("This order was already refunded — the refund moved once, so this just closes the order out.");
    }
  }
  const advance = await advanceAlreadyReleased(order.id);
  const remainingHeld = Math.max(0, Number(order.total || 0) - advance);
  const refundToBuyer =
    Number(order.item_price || 0) + Number(order.shipping_fee || 0);
  try {
    await recordLedgerMove(order, [
      {
        userId: order.seller_id,
        bucket: "held",
        kind: "refund",
        amount: -remainingHeld,
        note: `Refund — seller never shipped, order ${order.code}`,
      },
      {
        userId: order.buyer_id,
        bucket: "available",
        kind: "refund",
        amount: refundToBuyer,
        note: `Refund — seller never shipped, order ${order.code}`,
      },
    ]);
  } catch (err) {
    if (err?.code === "23505") {
      return closeOut("This order was already refunded — the refund moved once, so this just closes the order out.");
    }
    throw err;
  }
  return closeOut(
    `Refunded — the buyer gets ${refundToBuyer} naira back (item price + shipping). The listing is active again.`
  );
}

// Team-only read: every order still sitting in 'held', for the
// /admin panel's refund step above.
export async function fetchHeldOrders(user) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!isOwner(user)) {
    throw new Error("This page is not available.");
  }
  const { data, error } = await supabase
    .from("orders")
    .select("*")
    .eq("status", "held")
    .order("created_at", { ascending: false });
  if (error) throw error;
  return data || [];
}

// Team-only read: held orders that shipped more than `olderThanDays`
// ago and whose buyer still has not confirmed delivery — the
// shipped-with-no-exit case. Nothing auto-releases or auto-refunds
// them: auto_release_overdue_orders() and runAutoReleaseCheck()
// only ever touch 'delivered' orders, and a shipped order has no
// auto-exit by design (auto-confirming would pay the seller for a
// parcel the buyer may never have received; auto-refunding would
// pay the buyer for a parcel the seller did ship). The team sees
// the list, nudges the buyer, and then either the buyer confirms
// or the team resolves it by hand. The buyer can already force an
// exit themselves by opening a return once the order has shipped.
// Wiring for the coordinator: render this in /admin next to
// fetchHeldOrders, and the owner decides the nudge-then-what rule
// (see the report). Each row carries `daysWaiting`.
export const STALE_SHIPPED_DAYS = 7;

export async function fetchStaleShippedOrders(user, olderThanDays = STALE_SHIPPED_DAYS) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!isOwner(user)) {
    throw new Error("This page is not available.");
  }
  const { data, error } = await supabase
    .from("orders")
    .select("*")
    .eq("status", "shipped")
    .eq("payment_method", "held")
    .order("shipping_proof_at", { ascending: true })
    .limit(200);
  if (error) throw error;
  const cutoff = Date.now() - olderThanDays * 24 * 60 * 60 * 1000;
  const rows = [];
  for (const order of data || []) {
    const shippedAt = new Date(
      order.shipping_proof_at || order.updated_at || order.created_at
    ).getTime();
    if (Number.isNaN(shippedAt) || shippedAt > cutoff) continue;
    rows.push({
      ...withoutPin(order, null),
      daysWaiting: Math.floor((Date.now() - shippedAt) / (24 * 60 * 60 * 1000)),
    });
  }
  return rows;
}

// ---------------------------------------------------------------------------
// Stuck money — app-side reconcile for the two-step money moves.
// Every money action writes the ledger first and updates the order
// status second, so a crash (or a dropped network) between the two
// leaves the money moved and the status behind. Each action already
// recovers when it is retried — confirmReceipt / releaseOrder /
// refundHeldOrder / resolveReturn all check for the half-written
// move first and finish it instead of moving money twice — but
// nobody went looking for stuck orders. These two helpers do:
// fetchStuckMoneyOrders lists them for the team; reconcileOrder
// finishes the one half-move it finds by re-running the same
// idempotent action. The full close is a server-side release RPC
// that writes both legs and the status in one transaction (see the
// coordinator's report) — this bounds the window to "until the
// team reconciles", it does not remove it.
// ---------------------------------------------------------------------------

// Team-only: orders whose ledger and status disagree — the money
// moved, the status update never landed. Three shapes, all
// recoverable by re-running the matching action:
//   paid + hold row     -> the transfer was confirmed, the order
//                          still says 'paid' (confirmReceipt);
//   held + refund row   -> the refund moved, the order still says
//                          'held' (refundHeldOrder);
//   delivered + release -> the release moved, the order still says
//                          'delivered' (releaseOrder — the app-side
//                          auto-release check already closes these
//                          on any participant's app open).
// Returns [{ order, problem, action }] with `problem` in plain words.
export async function fetchStuckMoneyOrders(user) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!isOwner(user)) {
    throw new Error("This page is not available.");
  }
  const { data: orders, error } = await supabase
    .from("orders")
    .select("*")
    .in("status", ["paid", "held", "delivered"])
    .eq("payment_method", "held")
    .order("created_at", { ascending: false })
    .limit(200);
  if (error) throw error;
  const list = orders || [];
  if (list.length === 0) return [];
  const ids = list.map((o) => o.id);
  const { data: legs } = await supabase
    .from("wallet_ledger")
    .select("order_id, kind, bucket")
    .in("order_id", ids)
    .in("kind", ["hold", "release", "refund"]);
  const kindsByOrder = new Map();
  for (const row of legs || []) {
    if (!kindsByOrder.has(row.order_id)) kindsByOrder.set(row.order_id, new Set());
    kindsByOrder.get(row.order_id).add(`${row.kind}:${row.bucket}`);
  }
  const stuck = [];
  for (const order of list) {
    const kinds = kindsByOrder.get(order.id) || new Set();
    if (order.status === "paid" && kinds.has("hold:held")) {
      stuck.push({
        order: withoutPin(order, null),
        problem: "The transfer was confirmed and the money is held, but the order still says 'paid'.",
        action: "confirm-receipt",
      });
    } else if (order.status === "held" && kinds.has("refund:held")) {
      stuck.push({
        order: withoutPin(order, null),
        problem: "The refund was already paid, but the order still says 'held'.",
        action: "refund-held",
      });
    } else if (order.status === "delivered" && kinds.has("release:held")) {
      stuck.push({
        order: withoutPin(order, null),
        problem: "The money was already released to the seller, but the order still says 'delivered'.",
        action: "release",
      });
    }
  }
  return stuck;
}

// Team-only: finish one stuck order's half-written money move by
// re-running the matching action, which is already idempotent —
// the money is never moved twice. Returns { order, action, note };
// action is 'none' when the order has no half-finished move.
// A stuck order behind an open return or a frozen dispute is
// refused in plain words: the team resolves that first.
export async function reconcileOrder(orderId, user) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!isOwner(user)) {
    throw new Error("Only the PulseMarket team can reconcile an order.");
  }
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.payment_method !== "held") {
    return {
      order: withoutPin(order, user?.id),
      action: "none",
      note: "Cash orders hold no money — there is nothing to reconcile.",
    };
  }
  const { data: legs } = await supabase
    .from("wallet_ledger")
    .select("kind, bucket")
    .eq("order_id", order.id)
    .in("kind", ["hold", "release", "refund"]);
  const has = (kind, bucket) =>
    (legs || []).some((r) => r.kind === kind && r.bucket === bucket);
  if (order.status === "paid" && has("hold", "held")) {
    const done = await confirmReceipt(orderId, user);
    return {
      order: withoutPin(done, user?.id),
      action: "confirm-receipt",
      note: "The hold was already written — this just finished the status update. No money moved twice.",
    };
  }
  if (order.status === "held" && has("refund", "held")) {
    const done = await refundHeldOrder(orderId, user);
    return {
      order: withoutPin(done.order || done, user?.id),
      action: "refund-held",
      note: "The refund was already paid — this just closed the order out. No money moved twice.",
    };
  }
  if (order.status === "delivered" && has("release", "held")) {
    const done = await releaseOrder(orderId, user);
    return {
      order: withoutPin(done, user?.id),
      action: "release",
      note: "The release was already paid — this just closed the order out. No money moved twice.",
    };
  }
  return {
    order: withoutPin(order, user?.id),
    action: "none",
    note: "No half-finished money move found for this order.",
  };
}

// Cancel an order and put the listing back up for sale.
// Who may cancel, and from where:
//   - the BUYER, from 'reserved' or 'paid' (as before — the buyer
//     can change their mind before the money is held);
//   - the SELLER, from 'reserved' only. A reserved order is the
//     bricked-listing case: the buyer reserved the item and then
//     went quiet, and until now only the buyer could cancel, so the
//     listing sat reserved for ever. A seller must NOT cancel from
//     'paid' — the buyer may already have transferred the money,
//     and only the team can unwind a transfer;
//   - the PulseMarket TEAM (owner), from 'reserved' or 'paid' —
//     the team holds any transfer, so the team can cancel and
//     return it by hand. The buyer is told so in the notification.
// Pass the signed-in user object; a plain user id still works for
// the buyer-only legacy call (OrderDetail passes user.id today).
// The database trigger must allow the new moves too — until
// milestone-18 adds the seller / owner branches to
// pm_validate_order_update, the database refuses them (see the
// coordinator's report for the exact SQL). A frozen order (open
// dispute) still cannot be cancelled by anyone. In manual mode a
// 'paid' order has no hold entry yet, so cancelling it just
// cancels — but if a hold entry ever exists for this order it is
// reversed with a matching negative entry.
export async function cancelOrder(orderId, user) {
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  const userId = typeof user === "string" ? user : user?.id;
  const userEmail = typeof user === "object" && user ? user.email : null;
  const isBuyer = Boolean(userId) && order.buyer_id === userId;
  const isSeller = Boolean(userId) && order.seller_id === userId;
  const isTeam = userEmail === OWNER_EMAIL;
  if (!isBuyer && !isSeller && !isTeam) {
    throw new Error("Only the buyer, the seller or the PulseMarket team can cancel this order.");
  }
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
  // The seller can only cancel while nothing has been paid: once
  // the buyer has marked the order paid, only the team can cancel
  // (the team holds the transfer and returns it by hand).
  const allowedStatuses =
    isBuyer || isTeam ? ["reserved", "paid"] : ["reserved"];
  if (!allowedStatuses.includes(order.status)) {
    if (isSeller) {
      throw new Error(
        `This order is ${order.status} — the seller can only cancel while it is still reserved. The buyer has already paid, so only the PulseMarket team can cancel it now.`
      );
    }
    throw new Error(`This order is ${order.status} — it can no longer be cancelled.`);
  }
  if (supabase) {
    const { data } = await supabase
      .from("wallet_ledger")
      .select("amount")
      .eq("order_id", order.id)
      .eq("kind", "hold");
    const held = (data || []).reduce((sum, r) => sum + (r.amount || 0), 0);
    if (held !== 0) {
      // If a reversal was already written (the first cancel moved the
      // money back but the status update never landed), do not write
      // it again — the one-per-order refund index would refuse it and
      // the cancel could never complete.
      const { data: existingRefund } = await supabase
        .from("wallet_ledger")
        .select("id")
        .eq("order_id", order.id)
        .eq("kind", "refund")
        .eq("bucket", "held")
        .limit(1);
      if (!existingRefund || existingRefund.length === 0) {
        try {
          await recordLedgerMove(order, [
            {
              userId: order.seller_id,
              bucket: "held",
              kind: "refund",
              amount: -held,
              note: `Hold reversed — order ${order.code} cancelled`,
            },
          ]);
        } catch (err) {
          if (err?.code !== "23505") throw err;
          // Another device already wrote the reversal — carry on.
        }
      }
    }
  }
  const updated = await updateOrder(orderId, { status: "cancelled" });
  try {
    await updateListing(order.listing_id, { status: "active" });
  } catch (err) {
    console.error("[PulseMarket] cancel: could not put listing back to active:", err?.message || err);
  }
  // Tell the other side, in plain words. A team cancel of a paid
  // order must say the transfer is coming back — the buyer paid
  // real money and the team returns it by hand.
  if (isBuyer) {
    notifyUser(order.seller_id, {
      kind: "order",
      title: "Order cancelled",
      body: `The buyer cancelled order ${order.code} — the item is listed again.`,
      link: `/order/${order.id}`,
      orderId: order.id,
    });
  } else {
    notifyUser(order.buyer_id, {
      kind: "order",
      title: "Order cancelled",
      body:
        order.status === "paid" && isTeam
          ? `The PulseMarket team cancelled order ${order.code} — if you already transferred the money, the team will return it to you. Email ${OWNER_EMAIL} if it does not arrive.`
          : `The ${isTeam ? "PulseMarket team" : "seller"} cancelled order ${order.code} — the item is listed again.`,
      link: `/order/${order.id}`,
      orderId: order.id,
    });
  }
  return withoutPin(updated, userId);
}
