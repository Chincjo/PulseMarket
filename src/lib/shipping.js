// Milestone 8 — Shipping: couriers, Waybill Snap proof, 50% shipping
// advance, checkpoints, delivery PIN, returns. Every read function
// returns null / [] and logs the error when the tables do not exist yet
// (owner has not run supabase/milestone-8.sql), so the app says so
// honestly instead of crashing. Write functions throw a clear Error
// when the caller is not allowed or the order is in the wrong state.
//
// Money model (manual escrow, same ledger as Milestone 6):
//   - The buyer pays the full total up front; the owner confirms the
//     transfer and the total sits in the seller's "held" bucket.
//   - Shipping proof: when the proof is COMPLETE (courier is GIG, GUO,
//     DHL, Peace or ABC AND a waybill number AND a receipt photo are
//     present), half the shipping fee moves held -> available as a
//     'shipping_advance'. A bus-park waybill (driver phone only, no
//     receipt) ships the order but earns NO advance. A missing receipt
//     photo earns no advance either.
//   - Returns are resolved by the PulseMarket team only (see
//     resolveReturn). Balances are SUM(amount) over wallet_ledger —
//     never stored.
import { supabase } from "./supabase";
import { confirmDelivery } from "./orders";
import { OWNER_EMAIL } from "./payments";
import { notifyUser } from "./notifications";

// Evidence photos (waybill, receipt, checkpoint) live in the
// evidence-media bucket created by Milestone 7, under <user-id>/,
// the same path pattern as listing photos.
export const EVIDENCE_BUCKET = "evidence-media";

export const COURIERS = [
  "GIG Logistics",
  "GUO Transport",
  "Chowdeck Relay",
  "Peace Logistics",
  "ABC Transport",
  "DHL Domestic",
  "Bus Park Waybill",
];

// Only these couriers can ever earn the 50% shipping advance, and only
// with a waybill number AND a receipt photo. Chowdeck Relay (same-city)
// and Bus Park Waybill never earn an advance.
export const ADVANCE_COURIERS = [
  "GIG Logistics",
  "GUO Transport",
  "DHL Domestic",
  "Peace Logistics",
  "ABC Transport",
];

export const CHECKPOINT_STATUSES = [
  { value: "picked_up", label: "Picked up" },
  { value: "left_origin", label: "Left origin" },
  { value: "stopped", label: "Stopped on the way" },
  { value: "arrived_terminal", label: "Arrived at terminal" },
  { value: "out_for_delivery", label: "Out for delivery" },
  { value: "ready_for_pickup", label: "Ready for pickup" },
  { value: "delivered", label: "Delivered" },
];

export const CHECKPOINT_LABELS = Object.fromEntries(
  CHECKPOINT_STATUSES.map((s) => [s.value, s.label])
);

export const RETURN_REASONS = [
  "Wrong item sent",
  "Item damaged",
  "Item not as described",
  "Item looks fake",
  "I changed my mind",
  "Item arrived too late",
  "Other",
];

function dbError(err, where) {
  console.error(`[PulseMarket] ${where}:`, err?.message || err);
  return null;
}

async function currentUser() {
  if (!supabase) return null;
  const { data } = await supabase.auth.getUser();
  return data?.user || null;
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

// Same paired-move shape as Milestone 6's ledger writes.
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

// How much shipping advance has already been released to the seller
// for this order (sum of the 'available' shipping_advance entries).
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

// ---------------------------------------------------------------------------
// Courier tiers
// ---------------------------------------------------------------------------
//
// Tier 1 — items above ₦20,000: GIG or GUO only. Expensive items travel
//   with the big interstate couriers, not a park loader.
// Tier 2 — items under ₦10,000: Peace or ABC are allowed (the cheaper
//   interstate options). GIG / GUO / DHL are also accepted but cost more.
// Between ₦10,000 and ₦20,000: any tracked courier (GIG, GUO, DHL,
//   Peace, ABC).
// Tier 3 — Bus Park Waybill: always available as a fallback, but a park
//   loader with only a driver phone and no receipt NEVER earns the 50%
//   shipping advance, whatever the item costs.
// Chowdeck Relay is same-city only, not an interstate tier.
export function courierTiers(itemPrice) {
  const price = Math.max(0, Math.round(Number(itemPrice) || 0));
  if (price > 20000) {
    return {
      tier: 1,
      label: "Tier 1 — GIG or GUO only",
      allowedCouriers: ["GIG Logistics", "GUO Transport"],
      note: "This item costs over ₦20,000, so it must travel with GIG Logistics or GUO Transport. A park loader is not allowed for items this valuable.",
    };
  }
  if (price < 10000) {
    return {
      tier: 2,
      label: "Tier 2 — Peace or ABC",
      allowedCouriers: ["Peace Logistics", "ABC Transport"],
      note: "This item costs under ₦10,000, so the cheaper interstate couriers Peace Logistics or ABC Transport are allowed. GIG, GUO and DHL are also accepted but cost more.",
    };
  }
  return {
    tier: 2,
    label: "Tier 2 — tracked interstate couriers",
    allowedCouriers: [
      "GIG Logistics",
      "GUO Transport",
      "DHL Domestic",
      "Peace Logistics",
      "ABC Transport",
    ],
    note: "Any tracked interstate courier is allowed: GIG, GUO, DHL, Peace or ABC.",
  };
}

export function courierEarnsAdvance(courier) {
  return ADVANCE_COURIERS.includes(courier);
}

// ---------------------------------------------------------------------------
// Delivery PIN
// ---------------------------------------------------------------------------

// 6 digits, leading zeros kept (it is stored and compared as text).
export function generateDeliveryPin() {
  let pin = "";
  for (let i = 0; i < 6; i++) {
    pin += Math.floor(Math.random() * 10);
  }
  return pin;
}

// ---------------------------------------------------------------------------
// Photo uploads (evidence-media bucket, Milestone 7)
// ---------------------------------------------------------------------------

// Accepts a File / Blob (from a camera capture input) or a data-URL
// string (from a FileReader preview). Returns the public URL.
async function toBlob(fileOrDataUrl) {
  if (typeof fileOrDataUrl === "string") {
    const res = await fetch(fileOrDataUrl);
    return res.blob();
  }
  return fileOrDataUrl;
}

export async function uploadEvidencePhoto(userId, orderId, fileOrDataUrl, label) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!fileOrDataUrl) return null;
  const blob = await toBlob(fileOrDataUrl);
  const path = `${userId}/shipping/${orderId}-${label}-${Date.now()}.jpg`;
  const { error } = await supabase.storage
    .from(EVIDENCE_BUCKET)
    .upload(path, blob, { contentType: "image/jpeg", upsert: false });
  if (error) throw error;
  const { data } = supabase.storage.from(EVIDENCE_BUCKET).getPublicUrl(path);
  return data.publicUrl;
}

// ---------------------------------------------------------------------------
// Shipping proof — seller only, order must be 'held'.
// ---------------------------------------------------------------------------
//
// Waybill Snap is guided capture only: the seller photographs the
// waybill and types the number in themselves. There is NO OCR and no
// auto-fill anywhere in this flow.
export async function submitShippingProof(
  orderId,
  { waybillNumber, waybillPhoto, receiptPhoto, driverPhone }
) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const user = await currentUser();
  if (!user) throw new Error("Sign in first.");
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.seller_id !== user.id) {
    throw new Error("Only the seller can submit shipping proof for this order.");
  }
  if (order.status !== "held") {
    throw new Error(
      `This order is ${order.status} — shipping proof can only be submitted once the money is held.`
    );
  }
  if (order.delivery_method !== "shipping") {
    throw new Error("This order is a meet-in-person order — there is nothing to ship.");
  }
  const waybill = String(waybillNumber || "").trim();
  if (!waybill) {
    throw new Error("Type in the waybill number from the paper waybill.");
  }
  if (!waybillPhoto) {
    throw new Error("Take a photo of the waybill — hold the paper steady, good light, all four corners visible.");
  }

  const waybillUrl = await uploadEvidencePhoto(user.id, order.id, waybillPhoto, "waybill");
  const receiptUrl = receiptPhoto
    ? await uploadEvidencePhoto(user.id, order.id, receiptPhoto, "receipt")
    : null;

  // The advance is earned only with a complete proof: a tracked courier
  // (GIG, GUO, DHL, Peace or ABC) AND a waybill number AND a receipt
  // photo. A bus-park waybill (driver phone only, no receipt) and a
  // missing receipt photo earn no advance — the order still ships.
  const proofComplete =
    courierEarnsAdvance(order.courier) && Boolean(waybill) && Boolean(receiptUrl);
  const advanceAmount = Math.floor((Number(order.shipping_fee) || 0) / 2);

  let advanceReleased = false;
  let reason;
  if (proofComplete && advanceAmount > 0) {
    await recordLedgerMove(order, [
      {
        userId: order.seller_id,
        bucket: "held",
        kind: "shipping_advance",
        amount: -advanceAmount,
        note: `Shipping advance (50%) for order ${order.code}`,
      },
      {
        userId: order.seller_id,
        bucket: "available",
        kind: "shipping_advance",
        amount: advanceAmount,
        note: `Shipping advance (50%) for order ${order.code}`,
      },
    ]);
    advanceReleased = true;
    reason = `Proof complete — 50% of the shipping fee (${advanceAmount.toLocaleString("en-NG")} naira) has been released to your available balance. The rest is released when the buyer confirms delivery.`;
  } else if (!courierEarnsAdvance(order.courier)) {
    reason =
      order.courier === "Bus Park Waybill"
        ? "Proof recorded and the order is now shipped — but a bus-park waybill (driver phone only, no receipt) never earns the 50% shipping advance. The full shipping fee is released when the buyer confirms delivery."
        : "Proof recorded and the order is now shipped — but this courier does not earn the 50% shipping advance. The full shipping fee is released when the buyer confirms delivery.";
  } else if (!receiptUrl) {
    reason =
      "Proof recorded and the order is now shipped — but there is no receipt photo, so no shipping advance was released. The full shipping fee is released when the buyer confirms delivery.";
  } else {
    reason =
      "Proof recorded and the order is now shipped. The shipping fee is released when the buyer confirms delivery.";
  }

  const updated = await updateOrder(orderId, {
    waybill_number: waybill,
    waybill_photo: waybillUrl,
    receipt_photo: receiptUrl,
    driver_phone: driverPhone ? String(driverPhone).trim() : null,
    shipping_proof_at: new Date().toISOString(),
    delivery_pin: generateDeliveryPin(),
    shipping_advance_released: advanceReleased,
    status: "shipped",
  });
  return { order: updated, advanceReleased, reason };
}

// ---------------------------------------------------------------------------
// Checkpoints — seller only.
// ---------------------------------------------------------------------------

export async function addCheckpoint(orderId, { status, location, note, photo }) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const user = await currentUser();
  if (!user) throw new Error("Sign in first.");
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.seller_id !== user.id) {
    throw new Error("Only the seller can add a checkpoint for this order.");
  }
  if (!CHECKPOINT_LABELS[status]) {
    throw new Error("Choose a checkpoint status.");
  }
  let photoUrl = null;
  if (photo) {
    photoUrl = await uploadEvidencePhoto(user.id, order.id, photo, "checkpoint");
  }
  const { data, error } = await supabase
    .from("shipping_checkpoints")
    .insert({
      order_id: order.id,
      status,
      location: location ? String(location).trim() : null,
      note: note ? String(note).trim() : null,
      photo: photoUrl,
    })
    .select()
    .single();
  if (error) throw error;
  // Milestone 10: tell the buyer the parcel moved.
  notifyUser(order.buyer_id, {
    kind: "checkpoint",
    title: "Parcel update",
    body: `${CHECKPOINT_LABELS[status]}${location ? " — " + location : ""}`,
    link: `/tracking/${order.id}`,
    orderId: order.id,
  });
  return data;
}

export async function fetchCheckpoints(orderId) {
  if (!supabase || !orderId) return [];
  const { data, error } = await supabase
    .from("shipping_checkpoints")
    .select("*")
    .eq("order_id", orderId)
    .order("created_at", { ascending: true });
  if (error) {
    dbError(error, "fetch checkpoints");
    return [];
  }
  return data || [];
}

// Order + checkpoints together, for the tracking page.
export async function fetchTracking(orderId) {
  const order = await readOrder(orderId);
  if (!order) return null;
  const checkpoints = await fetchCheckpoints(orderId);
  return { order, checkpoints };
}

// ---------------------------------------------------------------------------
// Delivery PIN — buyer only. A wrong PIN throws and marks nothing.
// ---------------------------------------------------------------------------

export async function confirmDeliveryWithPin(orderId, pin, userId) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const user = userId ? { id: userId } : await currentUser();
  if (!user) throw new Error("Sign in first.");
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.buyer_id !== user.id) {
    throw new Error("Only the buyer can confirm delivery with the PIN.");
  }
  if (!order.delivery_pin) {
    throw new Error("This order has no delivery PIN yet — the seller has not submitted shipping proof.");
  }
  if (String(pin || "").trim() !== String(order.delivery_pin).trim()) {
    throw new Error("That PIN does not match. Check the PIN on this page and try again — nothing has been marked as delivered.");
  }
  return confirmDelivery(orderId, user.id);
}

// ---------------------------------------------------------------------------
// Returns — buyer opens, PulseMarket team resolves.
// ---------------------------------------------------------------------------

export async function openReturn(orderId, { reason, fault }) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const user = await currentUser();
  if (!user) throw new Error("Sign in first.");
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.buyer_id !== user.id) {
    throw new Error("Only the buyer can open a return for this order.");
  }
  if (!["shipped", "delivered"].includes(order.status)) {
    throw new Error(
      `This order is ${order.status} — a return can only be opened after the item has shipped.`
    );
  }
  if (order.return_status === "opened") {
    throw new Error("A return is already open for this order.");
  }
  if (!["seller", "buyer"].includes(fault)) {
    throw new Error("Say whose fault the return is: the seller's or yours.");
  }
  if (!reason) throw new Error("Choose a reason for the return.");
  const updated = await updateOrder(orderId, {
    return_status: "opened",
    return_reason: `${fault === "seller" ? "Seller fault" : "Buyer fault"}: ${reason}`,
  });
  // Milestone 10: tell both parties a return is open.
  notifyUser(order.buyer_id, {
    kind: "dispute",
    title: "Return opened",
    body: `A return was opened for order ${order.code}: ${reason}.`,
    link: `/order/${order.id}`,
    orderId: order.id,
  });
  notifyUser(order.seller_id, {
    kind: "dispute",
    title: "Return opened",
    body: `A return was opened for order ${order.code}: ${reason}.`,
    link: `/order/${order.id}`,
    orderId: order.id,
  });
  return updated;
}

// Owner only. The `fault` decides who pays:
//   - Seller fault (wrong / damaged / not as described / fake): the
//     buyer gets the item price + the shipping fee back. The seller
//     owes the shipping advance back — it is recorded as a 'debt'
//     ledger entry against the seller until they settle it, and the
//     seller pays the return shipping.
//   - Buyer fault (changed mind): the buyer gets the item price back
//     only. The seller keeps the shipping advance, and the rest of the
//     shipping fee is released to the seller. The buyer pays the return
//     shipping.
export async function resolveReturn(orderId, { fault }) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const user = await currentUser();
  if (!user) throw new Error("Sign in first.");
  if (user.email !== OWNER_EMAIL) {
    throw new Error("Only the PulseMarket team can resolve a return.");
  }
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.return_status !== "opened") {
    throw new Error("There is no open return for this order.");
  }
  if (!["seller", "buyer"].includes(fault)) {
    throw new Error("Resolve the return as seller fault or buyer fault.");
  }
  if (!["shipped", "delivered"].includes(order.status)) {
    throw new Error(
      `This order is ${order.status} — it can no longer be refunded this way.`
    );
  }

  const total = Number(order.total) || 0;
  const itemPrice = Number(order.item_price) || 0;
  const shippingFee = Number(order.shipping_fee) || 0;
  const advance = await advanceAlreadyReleased(order.id);
  // Money still sitting in the seller's held bucket for this order:
  // the full total, minus any advance already released.
  const remainingHeld = Math.max(0, total - advance);
  let note;

  if (fault === "seller") {
    const moves = [
      {
        userId: order.seller_id,
        bucket: "held",
        kind: "refund",
        amount: -remainingHeld,
        note: `Refund — seller fault return, order ${order.code}`,
      },
      {
        userId: order.buyer_id,
        bucket: "available",
        kind: "refund",
        amount: itemPrice + shippingFee,
        note: `Refund — seller fault return, order ${order.code}`,
      },
    ];
    await recordLedgerMove(order, moves);
    if (advance > 0) {
      await recordSellerDebt(
        order.id,
        advance,
        `Shipping advance to pay back — seller-fault return, order ${order.code}. The buyer was refunded in full, so the advance the seller already received has to come back.`
      );
    }
    note =
      `Seller fault: the buyer gets ${itemPrice + shippingFee} naira back (item price + shipping). ` +
      (advance > 0
        ? `The seller owes the ${advance} naira shipping advance back — it is recorded as a debt on the seller's wallet until they settle it, and the seller pays the return shipping.`
        : `No shipping advance was ever released, so the seller owes nothing back. The seller pays the return shipping.`);
  } else {
    const moves = [
      {
        userId: order.seller_id,
        bucket: "held",
        kind: "refund",
        amount: -remainingHeld,
        note: `Refund — buyer fault return, order ${order.code}`,
      },
      {
        userId: order.buyer_id,
        bucket: "available",
        kind: "refund",
        amount: itemPrice,
        note: `Refund — buyer fault return, order ${order.code}`,
      },
    ];
    const remainingShipping = Math.max(0, shippingFee - advance);
    if (remainingShipping > 0) {
      moves.push({
        userId: order.seller_id,
        bucket: "available",
        kind: "release",
        amount: remainingShipping,
        note: `Remaining shipping fee — buyer fault return, order ${order.code}`,
      });
    }
    await recordLedgerMove(order, moves);
    note =
      `Buyer fault: the buyer gets the item price back only (${itemPrice} naira). ` +
      `The seller keeps the shipping advance${advance > 0 ? ` (${advance} naira)` : ""} and the rest of the shipping fee, and the buyer pays the return shipping.`;
  }

  const updated = await updateOrder(orderId, {
    status: "refunded",
    return_status: "resolved",
  });
  // Milestone 10: tell both parties the return is resolved.
  notifyUser(order.buyer_id, {
    kind: "dispute",
    title: "Return resolved",
    body: `The return for order ${order.code} was resolved (${fault} fault).`,
    link: `/order/${order.id}`,
    orderId: order.id,
  });
  notifyUser(order.seller_id, {
    kind: "dispute",
    title: "Return resolved",
    body: `The return for order ${order.code} was resolved (${fault} fault).`,
    link: `/order/${order.id}`,
    orderId: order.id,
  });
  return { order: updated, note };
}

// Record that a seller owes money back (a negative 'available' entry).
// Used by resolveReturn for a seller-fault return, and by the team when
// a seller owes return shipping + advance and does not settle. The
// coordinator wires the "cannot list / cannot withdraw until cleared"
// gates — this helper only records the debt.
export async function recordSellerDebt(orderId, amount, note) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  const owed = Math.max(0, Math.round(Number(amount) || 0));
  if (owed <= 0) return null;
  const { data, error } = await supabase
    .from("wallet_ledger")
    .insert({
      order_id: order.id,
      user_id: order.seller_id,
      bucket: "available",
      kind: "debt",
      amount: -owed,
      note: note || `Seller debt for order ${order.code}`,
      created_by: order.buyer_id,
    })
    .select()
    .single();
  if (error) throw error;
  return data;
}

// True when the seller still owes money (unsettled 'debt' entries,
// minus any 'repayment' entries). The coordinator gates listing and
// withdrawals on this.
export async function hasSellerDebt(sellerId) {
  return (await sellerDebtAmount(sellerId)) > 0;
}

export async function sellerDebtAmount(sellerId) {
  if (!supabase || !sellerId) return 0;
  const { data, error } = await supabase
    .from("wallet_ledger")
    .select("kind, amount")
    .eq("user_id", sellerId)
    .in("kind", ["debt", "repayment"]);
  if (error) {
    dbError(error, "read seller debt");
    return 0;
  }
  let owed = 0;
  for (const row of data || []) {
    if (row.kind === "debt") owed += Math.abs(Number(row.amount) || 0);
    if (row.kind === "repayment") owed -= Number(row.amount) || 0;
  }
  return Math.max(0, owed);
}
