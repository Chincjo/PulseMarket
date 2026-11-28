// Milestone 12 — Disputes. A buyer reports a problem with an order
// and the PulseMarket team reviews it.
//
// Flow:
//   1. The buyer files a dispute from /dispute/:orderId. The report
//      needs a category, at least 20 characters of explanation, a
//      contact email, and at least one piece of in-app evidence for
//      the order (recorded with the Evidence Locker — never a gallery
//      video). A report with no evidence is refused, never filed.
//   2. Filing freezes the money: orders.frozen is set to true, so the
//      48-hour auto-release (Milestone 10, patched in
//      supabase/milestone-12.sql) skips the order while it is under
//      review. A security_log row ('dispute_filed') records the freeze.
//   3. The buyer sees ONLY "Report sent — under review" plus the
//      ticket ID (PM-TKT-####). The ticket number comes from the
//      Postgres sequence dispute_ticket_seq (see the SQL file — the
//      ticket_id column default builds it, so numbers are unique and
//      sequential and the app never invents one).
//   4. The team resolves disputes in the private /admin panel
//      (src/pages/Admin.jsx). Resolving a dispute does NOT move any
//      money by itself — money moves only through the existing manual
//      release / refund steps.
//
// The reporter can only ever see their own disputes, and only the
// ticket, status and category — never the team's internal notes.
// Those limits are enforced in the database (RLS, see
// supabase/milestone-12.sql) as well as here.
import { supabase } from "./supabase";
import { OWNER_EMAIL } from "./payments";
import { fetchEvidenceForOrder } from "./evidence";
import { logSecurityEvent } from "./handoff";

export const DISPUTE_CATEGORIES = [
  "Item not as described",
  "Item never arrived",
  "Item damaged",
  "Wrong item",
  "Seller unresponsive",
  "Payment problem",
  "Other",
];

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function dbError(err, where) {
  console.error(`[PulseMarket] ${where}:`, err?.message || err);
  return null;
}

export function isOwnerUser(user) {
  return Boolean(user?.email) && user.email === OWNER_EMAIL;
}

async function currentUser() {
  if (!supabase) return null;
  const { data, error } = await supabase.auth.getUser();
  if (error) {
    dbError(error, "get current user");
    return null;
  }
  return data?.user || null;
}

function isMissingTableError(error) {
  if (!error) return false;
  const code = String(error.code || "");
  const message = String(error.message || "");
  return (
    code === "42P01" ||
    code === "PGRST205" ||
    /relation .* does not exist|Could not find the table/i.test(message)
  );
}

// ---------------------------------------------------------------------------
// Filing a dispute (buyer only)
// ---------------------------------------------------------------------------

// Evidence gate — fails CLOSED. fetchEvidenceForOrder returns [] both
// when there is no evidence and when the evidence table does not exist
// yet, so an empty result is probed directly: a missing table is
// refused with the same "add evidence first" message instead of
// letting a report through with no proof behind it.
//
// The gate needs a VERIFIED dispute video (kind 'dispute',
// verified=true — a 10–20s clip recorded in the app). Before this fix
// ANY evidence row satisfied it: a handoff photo, a receipt photo, or
// the seller's packing video all let a dispute through with no video
// of the actual problem.
async function requireDisputeEvidence(orderId, buyerId) {
  const rows = await fetchEvidenceForOrder(orderId);
  // The dispute video must be the BUYER's — a seller's clip used
  // to satisfy the gate, because it checked kind + verified only.
  if (rows && rows.some((r) => r.kind === "dispute" && r.verified === true && (!buyerId || r.user_id === buyerId))) {
    return rows;
  }
  // No qualifying row — find out whether the table is missing or the
  // student simply has not recorded a dispute video yet. Filter by
  // the buyer when known, so a seller's video never satisfies it.
  let probeQuery = supabase
    .from("evidence")
    .select("id")
    .eq("order_id", orderId)
    .eq("kind", "dispute")
    .eq("verified", true);
  if (buyerId) probeQuery = probeQuery.eq("user_id", buyerId);
  const { data, error } = await probeQuery.limit(1);
  if (error && isMissingTableError(error)) {
    throw new Error(
      "Add evidence first — record a short video of the problem in the app (Evidence Locker, dispute evidence, 10–20 seconds) before reporting it. The evidence table is not set up yet, so a report cannot be filed."
    );
  }
  if (error) throw error;
  if (data && data.length > 0) return data;
  throw new Error(
    "Add evidence first — record a short video of the problem in the app (Evidence Locker, dispute evidence, 10–20 seconds) before reporting it. A report needs a verified dispute video, not just any photo or video on the order."
  );
}

export async function fileDispute(orderId, { category, explanation, email }) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!orderId) throw new Error("Missing order.");

  const cleanCategory = String(category || "").trim();
  if (!DISPUTE_CATEGORIES.includes(cleanCategory)) {
    throw new Error("Choose what went wrong from the list.");
  }
  const cleanExplanation = String(explanation || "").trim();
  if (cleanExplanation.length < 20) {
    throw new Error("Explain what happened in at least 20 characters.");
  }
  if (cleanExplanation.length > 2000) {
    throw new Error("Keep your explanation under 2,000 characters.");
  }
  const cleanEmail = String(email || "").trim();
  if (cleanEmail.length > 120) {
    throw new Error("That email address is too long.");
  }
  if (!EMAIL_RE.test(cleanEmail)) {
    throw new Error("Enter a valid email address so the team can reach you.");
  }

  const user = await currentUser();
  if (!user) throw new Error("Sign in first to report a problem.");

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("id, code, buyer_id, seller_id, status, frozen, return_status")
    .eq("id", orderId)
    .maybeSingle();
  if (orderError) throw orderError;
  if (!order) throw new Error("Order not found.");
  if (order.buyer_id !== user.id) {
    throw new Error("Only the buyer of this order can report a problem with it.");
  }

  // A dispute freezes money, so there has to be money to freeze. On a
  // 'reserved' order nothing has been paid yet — the buyer cancels
  // instead of reporting — and filing on one would freeze it so it
  // could never even be cancelled. On a released / refunded /
  // cancelled order the money has already moved (or never moved), so
  // freezing achieves nothing; those go to the team by email.
  if (!["paid", "held", "shipped", "delivered"].includes(order.status)) {
    if (order.status === "reserved") {
      throw new Error("This order has not started yet — cancel it from the order page if you no longer want it.");
    }
    throw new Error("This order is already closed — email pulsemarketsupport@gmail.com with the order code and the team will look into it.");
  }

  // One open case at a time: a dispute freezes the order, and
  // resolveReturn refuses frozen orders — so a team that opened a
  // dispute first could not resolve the return until the dispute
  // closed, and the two cases could disagree about the same money.
  // Finish (or close) the return first, then file a dispute if
  // something is still wrong.
  if (order.return_status === "opened") {
    throw new Error("A return is already open on this order — the PulseMarket team resolves the return first. File a dispute after that if something is still wrong.");
  }

  // One open report per order — a second report for the same order
  // just points at the ticket that already exists.
  const { data: existing, error: existingError } = await supabase
    .from("disputes")
    .select("ticket_id, status")
    .eq("order_id", orderId)
    .eq("reporter_id", user.id)
    .in("status", ["open", "under_review"])
    .order("created_at", { ascending: false })
    .limit(1);
  if (existingError) {
    if (isMissingTableError(existingError)) {
      throw new Error(
        "Reports are not set up yet — ask the PulseMarket team to run supabase/milestone-12.sql, then try again."
      );
    }
    throw existingError;
  }
  if (existing && existing.length > 0) {
    throw new Error(
      `This order already has a report under review — ${existing[0].ticket_id}.`
    );
  }

  // Evidence first: no proof, no report. Never fails open.
  await requireDisputeEvidence(orderId, order.buyer_id);

  // The ticket number is built by the database (ticket_id default in
  // supabase/milestone-12.sql: 'PM-TKT-' + the dispute_ticket_seq
  // sequence), so it is unique and sequential. The insert returns it.
  const { data: dispute, error: insertError } = await supabase
    .from("disputes")
    .insert({
      order_id: orderId,
      reporter_id: user.id,
      category: cleanCategory,
      explanation: cleanExplanation,
      email: cleanEmail,
      status: "open",
    })
    .select("ticket_id")
    .single();
  if (insertError) {
    if (isMissingTableError(insertError)) {
      throw new Error(
        "Reports are not set up yet — ask the PulseMarket team to run supabase/milestone-12.sql, then try again."
      );
    }
    // Night deep check 2026-11-27: a double-submit from two tabs
    // can both pass the open-dispute check above, then the second
    // insert hits the M16 partial unique index (one open dispute
    // per order — disputes_one_open_per_order_idx). The report IS
    // filed, so return the ticket that already exists instead of
    // showing a raw database error. (The race itself is already
    // closed server-side; this is only the user-facing path.)
    if (insertError.code === "23505") {
      const { data: raced } = await supabase
        .from("disputes")
        .select("ticket_id")
        .eq("order_id", orderId)
        .eq("reporter_id", user.id)
        .in("status", ["open", "under_review"])
        .order("created_at", { ascending: false })
        .limit(1);
      if (raced && raced.length > 0) {
        return { ticketId: raced[0].ticket_id };
      }
    }
    throw insertError;
  }

  // Freeze the money so nothing releases while the report is open.
  // If the freeze fails, remove the report again rather than leaving
  // an open report on unfrozen money — UNLESS the order is already
  // frozen. Milestone 21 freezes the order in the same transaction
  // as the dispute insert, so the follow-up freeze update can fail
  // while the order is already frozen: deleting the report then
  // would leave a frozen order with no dispute to resolve, and the
  // money would sit frozen until someone intervened by hand.
  const { error: freezeError } = await supabase
    .from("orders")
    .update({ frozen: true, updated_at: new Date().toISOString() })
    .eq("id", orderId);
  if (freezeError) {
    const { data: fresh } = await supabase
      .from("orders")
      .select("frozen")
      .eq("id", orderId)
      .maybeSingle();
    if (!fresh?.frozen) {
      await supabase.from("disputes").delete().eq("order_id", orderId).eq("reporter_id", user.id).eq("ticket_id", dispute.ticket_id);
      throw freezeError;
    }
    // Already frozen — the report stands; fall through to the audit
    // log below and return the ticket.
  }

  // Audit trail. Best effort — a logging failure must not undo a
  // report that is already filed and frozen.
  await logSecurityEvent(
    orderId,
    user.id,
    "dispute_filed",
    `Dispute ${dispute.ticket_id} filed (${cleanCategory}) for order ${order.code} — money frozen.`
  );

  return { ticketId: dispute.ticket_id };
}

// ---------------------------------------------------------------------------
// Reporter's own disputes — ticket + status + category only. The
// team's internal notes (resolution_note) are never selected here.
// ---------------------------------------------------------------------------

const REPORTER_COLUMNS = "id, ticket_id, order_id, status, category, created_at";

export async function fetchMyDisputes(userId) {
  if (!supabase || !userId) return [];
  const { data, error } = await supabase
    .from("disputes")
    .select(REPORTER_COLUMNS)
    .eq("reporter_id", userId)
    .order("created_at", { ascending: false })
    .limit(100);
  if (error) {
    dbError(error, "fetch my disputes");
    return [];
  }
  return data || [];
}

export async function fetchDisputeByTicket(ticketId, userId) {
  if (!supabase || !ticketId || !userId) return null;
  const { data, error } = await supabase
    .from("disputes")
    .select(REPORTER_COLUMNS)
    .eq("ticket_id", String(ticketId).trim().toUpperCase())
    .eq("reporter_id", userId)
    .maybeSingle();
  if (error) {
    dbError(error, "fetch dispute by ticket");
    return null;
  }
  return data;
}

// ---------------------------------------------------------------------------
// Team-only reads (private /admin panel). RLS enforces owner-only
// access in the database too — these helpers also check the signed-in
// email first so a non-owner never even sends the query.
// ---------------------------------------------------------------------------

async function requireOwner() {
  const user = await currentUser();
  if (!isOwnerUser(user)) {
    throw new Error("This page is not available.");
  }
  return user;
}

export async function fetchAllDisputes() {
  if (!supabase) throw new Error("Supabase is not configured.");
  await requireOwner();
  const { data, error } = await supabase
    .from("disputes")
    .select("*")
    .order("created_at", { ascending: false })
    .limit(1000);
  if (error) throw error;
  return data || [];
}

export async function fetchOpenDisputes() {
  const all = await fetchAllDisputes();
  return all.filter((d) => d.status === "open" || d.status === "under_review");
}

export async function fetchDisputeDetail(disputeId) {
  if (!supabase) throw new Error("Supabase is not configured.");
  await requireOwner();
  const { data, error } = await supabase
    .from("disputes")
    .select("*")
    .eq("id", disputeId)
    .maybeSingle();
  if (error) throw error;
  return data;
}

// Resolving a dispute records the outcome only. It does NOT move any
// money — money moves only through the existing manual release /
// refund steps, which the team runs separately. Resolving DOES unfreeze
// the order: the freeze exists to stop money moving WHILE the dispute
// is open, and the manual release/refund steps refuse a frozen order —
// so the freeze must be lifted here or the money could never move
// after a resolution.
export async function resolveDispute(disputeId, { resolutionNote }) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!disputeId) throw new Error("Missing dispute.");
  const note = String(resolutionNote || "").trim();
  if (note.length < 5) {
    throw new Error("Write a short note saying how this was resolved.");
  }
  if (note.length > 1000) {
    throw new Error("Keep the resolution note under 1,000 characters.");
  }
  const user = await requireOwner();
  // Resolving twice used to re-run the unfreeze and write a second
  // 'dispute_resolved' log row for a dispute that was already closed.
  const current = await fetchDisputeDetail(disputeId);
  if (!current) throw new Error("Report not found.");
  if (current.status === "resolved") {
    // A first resolve can leave the dispute resolved but the order
    // still frozen: the unfreeze below runs AFTER the dispute row
    // is saved, so if it failed the money was frozen with no open
    // dispute left to resolve. Refusing here would brick the money
    // for ever, so retry the unfreeze instead of throwing.
    const { data: ord } = await supabase
      .from("orders")
      .select("id, frozen")
      .eq("id", current.order_id)
      .maybeSingle();
    if (ord?.frozen) {
      const { error: unfreezeError } = await supabase
        .from("orders")
        .update({ frozen: false, updated_at: new Date().toISOString() })
        .eq("id", current.order_id);
      if (unfreezeError) throw unfreezeError;
    }
    return current;
  }
  const { data, error } = await supabase
    .from("disputes")
    .update({
      status: "resolved",
      resolution_note: note,
      resolved_at: new Date().toISOString(),
    })
    .eq("id", disputeId)
    .in("status", ["open", "under_review"])
    .select()
    .single();
  if (error) {
    // Morning deep check 2026-11-28: two admins resolving one
    // dispute at the same time used to end with the second admin
    // seeing a raw database error — the update matched 0 rows
    // because the first admin had already resolved it. Re-read:
    // if it is already resolved, return that row instead of failing.
    if (error.code === "PGRST116") {
      const { data: again } = await supabase
        .from("disputes")
        .select("*")
        .eq("id", disputeId)
        .maybeSingle();
      if (again && again.status === "resolved") return again;
    }
    throw error;
  }
  // Unfreeze the order so the manual release/refund can run. If this
  // fails, throw — the dispute row is already resolved, and the owner
  // can resolve again (the update is idempotent) to retry the unfreeze.
  const { error: unfreezeError } = await supabase
    .from("orders")
    .update({ frozen: false, updated_at: new Date().toISOString() })
    .eq("id", data.order_id);
  if (unfreezeError) throw unfreezeError;
  await logSecurityEvent(
    data.order_id,
    user.id,
    "dispute_resolved",
    `Dispute ${data.ticket_id} resolved — ${note}`
  );
  return data;
}

export async function fetchSecurityLog(limit = 100) {
  if (!supabase) throw new Error("Supabase is not configured.");
  await requireOwner();
  const { data, error } = await supabase
    .from("security_log")
    .select("id, action, order_id, user_id, detail, created_at")
    .order("created_at", { ascending: false })
    .limit(Math.max(1, Math.min(100, Number(limit) || 100)));
  if (error) throw error;
  return data || [];
}

export async function fetchFrozenOrders() {
  if (!supabase) throw new Error("Supabase is not configured.");
  await requireOwner();
  // Morning deep check 2026-11-28: the old read had no limit, so
  // PostgREST silently stopped at its 1000-row default and frozen
  // orders past that were invisible to the team. Page through
  // every frozen order.
  const out = [];
  const PAGE = 1000;
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await supabase
      .from("orders")
      .select("*")
      .eq("frozen", true)
      .order("created_at", { ascending: false })
      .range(from, from + PAGE - 1);
    if (error) {
      // The orders.frozen column comes from supabase/milestone-12.sql.
      // If it has not been run yet, there is nothing frozen to show.
      if (/column .*frozen.* does not exist/i.test(String(error.message || ""))) return [];
      throw error;
    }
    out.push(...(data || []));
    if (!data || data.length < PAGE) break;
  }
  return out;
}
