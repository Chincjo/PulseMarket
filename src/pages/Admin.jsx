// Milestone 12 — Private team panel (route /admin, added by the
// coordinator). Accessible ONLY when the signed-in user's email is
// exactly pulsemarketsupport@gmail.com. Anyone else — including
// signed-out visitors — sees a plain "This page is not available."
// message and nothing else. There is NO link to this page anywhere
// in the user app.
//
// For the team it shows:
//   (a) open disputes, with a detail view (explanation, evidence
//       links, order summary) and a Resolve action. Resolving records
//       the outcome only — it does NOT move any money. Money moves
//       only through the existing manual release / refund steps.
//   (b) the security log (latest 100 rows, newest first).
//   (c) currently frozen orders (orders where frozen = true).
//
// All reads are owner-only in the database too (RLS, see
// supabase/milestone-12.sql); the helpers in src/lib/disputes.js
// also check the signed-in email before querying.
import { useCallback, useEffect, useRef, useState } from "react";
import { useAuth } from "../lib/auth";
import {
  cancelOrder,
  fetchHeldOrders,
  fetchOrder,
  fetchPaidOrders,
  fetchStaleShippedOrders,
  fetchStuckMoneyOrders,
  reconcileOrder,
  refundHeldOrder,
} from "../lib/orders";
import { sellerDebtAmount } from "../lib/shipping";
import { notifyUser } from "../lib/notifications";
import { fetchLockedHandoffs, unlockHandoff } from "../lib/handoff";
import { fetchEvidenceForOrder, useSignedEvidenceUrls } from "../lib/evidence";
import {
  fetchAllDisputes,
  fetchFrozenOrders,
  fetchSecurityLog,
  isOwnerUser,
  resolveDispute,
} from "../lib/disputes";
import {
  confirmBoostPurchase,
  fetchBoostRequests,
  fetchPendingVerifications,
  reviewVerification,
  verificationIdPhotoUrl,
} from "../lib/listings";
import { OWNER_EMAIL } from "../lib/payments";
import { GhostButton, PrimaryButton, inputCls } from "../components/ui";

function timeAgo(iso) {
  if (!iso) return "";
  const seconds = Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 1000));
  if (seconds < 60) return "just now";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days}d ago`;
  return new Date(iso).toLocaleDateString("en-NG");
}

function formatMoney(naira) {
  const n = Number(naira || 0);
  return `₦${n.toLocaleString("en-NG")}`;
}

// Milestone 19, Decision 3 — fixed rejection reasons for the
// Pending verifications picker. The reason is required; the note
// is optional (max 280 chars). Values are the exact strings the
// review_verification RPC expects (Team B owns the RPC).
const REJECT_REASONS = [
  { value: "blurry", label: "Blurry photo" },
  { value: "wrong document", label: "Wrong document" },
  { value: "name mismatch", label: "Name doesn't match the ID" },
  { value: "expired", label: "Expired ID" },
  { value: "other", label: "Other" },
  // Milestone 25 — face-verification reasons (ordinary users).
  { value: "blurry selfie", label: "Blurry selfie" },
  { value: "face not clear", label: "Face not clear in the selfie" },
  { value: "face does not match ID", label: "Face does not match the ID" },
];

export default function Admin() {
  const { user, loading: authLoading } = useAuth();
  const [disputes, setDisputes] = useState([]);
  const [securityLog, setSecurityLog] = useState([]);
  const [frozenOrders, setFrozenOrders] = useState([]);
  const [heldOrders, setHeldOrders] = useState([]);
  const [lockedHandoffs, setLockedHandoffs] = useState([]);
  const [pendingVerifications, setPendingVerifications] = useState([]);
  const [pendingError, setPendingError] = useState("");
  const [photoUrls, setPhotoUrls] = useState({});
  const [viewingPhotos, setViewingPhotos] = useState(null);
  // Milestone 19 — Decision 5 (stuck shipped) + stuck money lists.
  const [staleShipped, setStaleShipped] = useState([]);
  const [staleError, setStaleError] = useState("");
  const [stuckMoney, setStuckMoney] = useState([]);
  const [stuckError, setStuckError] = useState("");
  // Milestone 19 — Decision 3 reject picker (row being rejected,
  // chosen reason, optional note).
  const [rejectFor, setRejectFor] = useState(null);
  const [rejectReason, setRejectReason] = useState("");
  const [rejectNote, setRejectNote] = useState("");
  // Milestone 19 — withdrawal debt check (seller user id -> amount owed).
  const [debtSellerId, setDebtSellerId] = useState("");
  const [debtResult, setDebtResult] = useState(null);
  const [busyAction, setBusyAction] = useState("");
  const [selectedId, setSelectedId] = useState(null);
  const [selectedOrder, setSelectedOrder] = useState(null);
  const [selectedEvidence, setSelectedEvidence] = useState([]);
  // Which openDispute() call is the latest — an older call that
  // lands late must not overwrite the dispute now on screen.
  const disputeRequest = useRef(0);
  const [loadingDispute, setLoadingDispute] = useState(false);
  // Orders already nudged once this visit — a nudge sends a real
  // notification, so the button must not send it twice.
  const [nudgedIds, setNudgedIds] = useState([]);
  const [resolutionNote, setResolutionNote] = useState("");
  const [resolving, setResolving] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  // Milestone 20 (APP-9): paid-but-unconfirmed orders, oldest first.
  const [paidOrders, setPaidOrders] = useState([]);
  const [paidError, setPaidError] = useState("");
  // Milestone 20 (M-2): pending boost purchase requests.
  const [boostRequests, setBoostRequests] = useState([]);
  const [boostError, setBoostError] = useState("");
  // Milestone 20 (M-6): dispute evidence links open through
  // short-lived signed URLs (the evidence-media bucket goes
  // private) — stored URLs are the fallback until then.
  const signedEvidenceUrls = useSignedEvidenceUrls(
    selectedEvidence.map((e) => e.url)
  );

  const isOwner = isOwnerUser(user);

  const load = useCallback(async () => {
    if (!isOwner) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError("");
    try {
      const [allDisputes, log, frozen, held, locked] = await Promise.all([
        fetchAllDisputes(),
        fetchSecurityLog(100),
        fetchFrozenOrders(),
        fetchHeldOrders(user),
        fetchLockedHandoffs(),
      ]);
      setDisputes(allDisputes || []);
      setSecurityLog(log || []);
      setFrozenOrders(frozen || []);
      setHeldOrders(held || []);
      setLockedHandoffs(locked || []);
    } catch (err) {
      setError(err?.message || "Could not load the team panel.");
    } finally {
      setLoading(false);
    }
    // Milestone 17: pending verifications load separately, so a
    // problem with them (e.g. the milestone-17.sql rules not run
    // yet) shows a note on that section instead of blanking the
    // whole team panel with an error.
    try {
      const pending = await fetchPendingVerifications();
      setPendingVerifications(pending || []);
      setPendingError("");
    } catch (err) {
      setPendingError(err?.message || "Could not load pending verifications.");
      setPendingVerifications([]);
    }
    // Milestone 19, Decision 5: stuck shipped orders load
    // separately too, for the same reason — a problem here must
    // not blank the rest of the panel.
    try {
      const stale = await fetchStaleShippedOrders(user);
      setStaleShipped(stale || []);
      setStaleError("");
    } catch (err) {
      setStaleError(err?.message || "Could not load stuck shipped orders.");
      setStaleShipped([]);
    }
    // Milestone 19 follow-up: stuck money orders, same pattern.
    try {
      const stuck = await fetchStuckMoneyOrders(user);
      setStuckMoney(stuck || []);
      setStuckError("");
    } catch (err) {
      setStuckError(err?.message || "Could not load stuck money orders.");
      setStuckMoney([]);
    }
    // Milestone 20 (APP-9): paid-but-unconfirmed orders, same
    // pattern — a problem here must not blank the rest of the panel.
    try {
      const paid = await fetchPaidOrders(user);
      setPaidOrders(paid || []);
      setPaidError("");
    } catch (err) {
      setPaidError(err?.message || "Could not load paid orders.");
      setPaidOrders([]);
    }
    // Milestone 20 (M-2): pending boost purchase requests, same
    // pattern. The table arrives with the Milestone 20 SQL; until
    // then this shows a plain note instead of a queue.
    try {
      const boosts = await fetchBoostRequests();
      setBoostRequests(boosts || []);
      setBoostError("");
    } catch (err) {
      setBoostError(err?.message || "Could not load boost requests.");
      setBoostRequests([]);
    }
  }, [isOwner, user]);

  useEffect(() => {
    load();
  }, [load]);

  async function openDispute(dispute) {
    // A second Review tap while the first is still loading used to
    // let the slower reply win — the detail could show the WRONG
    // order's evidence under this dispute. The token below drops
    // any reply that is no longer the latest tap.
    const request = ++disputeRequest.current;
    setSelectedId(dispute.id);
    setSelectedOrder(null);
    setSelectedEvidence([]);
    setResolutionNote("");
    setNotice("");
    setError("");
    setLoadingDispute(true);
    try {
      const [order, rows] = await Promise.all([
        fetchOrder(dispute.order_id),
        fetchEvidenceForOrder(dispute.order_id),
      ]);
      if (request !== disputeRequest.current) return;
      setSelectedOrder(order);
      setSelectedEvidence(rows || []);
    } catch (err) {
      if (request !== disputeRequest.current) return;
      setError(err?.message || "Could not load this dispute.");
    } finally {
      if (request === disputeRequest.current) setLoadingDispute(false);
    }
  }

  async function handleResolve(e) {
    e.preventDefault();
    if (!selectedId) return;
    // Entry guard: the button only disables after a re-render, so
    // a double-tap (or Enter while resolving) ran resolve twice.
    if (resolving) return;
    // Milestone 20 (APP-16): a resolution note is required — the
    // team must say how a dispute was decided. The lib refuses a
    // note under 5 characters too; this stops the click early with
    // the same plain words.
    if (resolutionNote.trim().length < 5) {
      setError("Write a short note saying how this was resolved (at least 5 characters).");
      return;
    }
    setError("");
    setNotice("");
    setResolving(true);
    try {
      await resolveDispute(selectedId, { resolutionNote });
      setNotice("Dispute marked resolved. No money moved — use the manual release or refund steps if money needs to move.");
      setSelectedId(null);
      setSelectedOrder(null);
      setSelectedEvidence([]);
      setResolutionNote("");
      await load();
    } catch (err) {
      setError(err?.message || "Could not resolve this dispute.");
    } finally {
      setResolving(false);
    }
  }

  // Milestone 20 (APP-9): cancel a paid-but-unconfirmed order by
  // hand. The buyer already transferred, so the team returns the
  // money by hand — cancelOrder() writes the manual return to the
  // security log. Confirm first: this cannot be undone.
  async function handleCancelPaid(order) {
    if (
      !window.confirm(
        `Cancel paid order ${order.code}? The buyer already transferred ${formatMoney(
          order.total
        )} — the team returns it to them by hand. The cancel is written to the security log.`
      )
    ) {
      return;
    }
    setError("");
    setNotice("");
    setBusyAction(`cancel-paid-${order.id}`);
    try {
      await cancelOrder(order.id, user);
      setNotice(`Paid order ${order.code} cancelled — return the transfer to the buyer by hand.`);
      await load();
    } catch (err) {
      setError(err?.message || "Could not cancel this order.");
    } finally {
      setBusyAction("");
    }
  }

  // Milestone 20 (M-2): confirm a boost purchase — the payment
  // arrived by hand, so mark the request paid and apply the boost
  // to the listing. No bank details anywhere: the team confirms
  // the payment outside the app.
  async function handleConfirmBoost(row) {
    if (
      !window.confirm(
        `Confirm boost for this listing? The payment has arrived by hand — this marks the request paid and applies the boost.`
      )
    ) {
      return;
    }
    setError("");
    setNotice("");
    setBusyAction(`boost-${row.id}`);
    try {
      await confirmBoostPurchase(row);
      setNotice("Boost confirmed — the listing is boosted now.");
      await load();
    } catch (err) {
      setError(err?.message || "Could not confirm this boost.");
    } finally {
      setBusyAction("");
    }
  }

  // Held order whose seller never ships (or shipped order whose
  // buyer never confirms): refund the buyer item + shipping (the
  // fees stay with PulseMarket — owner decision 2026-11-26) and
  // put the listing back to active. Needs the milestone-20
  // database rule — until it runs this reports the database error
  // and refunds nothing.
  async function handleRefundHeld(order, alreadyShipped = false) {
    if (
      !window.confirm(
        alreadyShipped
          ? `Refund order ${order.code}? This order already SHIPPED — the parcel may be with the buyer or the transport company. The buyer gets item + shipping back (${formatMoney(
              (order.item_price || 0) + (order.shipping_fee || 0)
            )}) — the fees stay with PulseMarket — and the listing goes back to active. Only refund if the parcel cannot still be delivered.`
          : `Refund order ${order.code}? The buyer gets item + shipping back (${formatMoney(
              (order.item_price || 0) + (order.shipping_fee || 0)
            )}) — the fees stay with PulseMarket — and the listing goes back to active.`
      )
    ) {
      return;
    }
    setError("");
    setNotice("");
    setBusyAction(`refund-${order.id}`);
    try {
      const { note } = await refundHeldOrder(order.id, user);
      setNotice(note || "Order refunded.");
      await load();
    } catch (err) {
      setError(err?.message || "Could not refund this order.");
    } finally {
      setBusyAction("");
    }
  }

  // Locked handoff: 5 wrong codes bricked the meetup, so the held
  // money can neither be delivered nor released. Unlocking resets
  // the attempt count; it does not unflag the buyer.
  async function handleUnlockHandoff(order) {
    setError("");
    setNotice("");
    setBusyAction(`unlock-${order.id}`);
    try {
      await unlockHandoff(order.id);
      setNotice(`Handoff unlocked for order ${order.code} — the buyer can try the seller code again.`);
      await load();
    } catch (err) {
      setError(err?.message || "Could not unlock this handoff.");
    } finally {
      setBusyAction("");
    }
  }

  // Milestone 17: open a student's ID photos. The bucket is private,
  // so the photos are fetched with short-lived signed URLs (one hour)
  // made from the storage paths on the verification row — never a
  // public link. Fresh links are reused for 50 minutes, then re-minted.
  // A student with no photos on file has nothing to open.
  async function handleViewPhotos(row) {
    if (viewingPhotos === row.user_id) {
      setViewingPhotos(null);
      return;
    }
    setViewingPhotos(row.user_id);
    // Signed URLs live for an hour: reuse a cached one only while
    // it is fresh (50 minutes), otherwise mint a new pair — reusing
    // an expired link used to show a broken image with no way to
    // refresh it except reloading the whole list.
    const cached = photoUrls[row.user_id];
    if (cached && Date.now() - (cached.mintedAt || 0) < 50 * 60 * 1000) return;
    // The cached links are stale: drop them BEFORE minting new
    // ones, or the screen keeps showing the expired images (broken
    // pictures) while the fresh links are still being made.
    if (cached) {
      setPhotoUrls((prev) => {
        const next = { ...prev };
        delete next[row.user_id];
        return next;
      });
    }
    setError("");
    setBusyAction(`photos-${row.user_id}`);
    try {
      // Milestone 25: ordinary users have a selfie (+ optional gov
      // ID); students have ID front/back. Same private bucket, same
      // signed-URL flow — only the paths differ.
      const isOrdinary = row.account_type === "ordinary";
      const [front, back] = await Promise.all([
        verificationIdPhotoUrl(isOrdinary ? row.face_photo_url : row.id_front_url),
        verificationIdPhotoUrl(isOrdinary ? row.gov_id_front_url : row.id_back_url),
      ]);
      setPhotoUrls((prev) => ({ ...prev, [row.user_id]: { front, back, mintedAt: Date.now() } }));
    } catch (err) {
      setError(err?.message || "Could not open the ID photos. Try again.");
      setViewingPhotos(null);
    } finally {
      setBusyAction("");
    }
  }

  // Milestone 17: team decision on one student — APPROVE only.
  // Approving lets them post and chat at once. Rejecting goes
  // through the reason picker below (Decision 3), never through
  // this path, so a rejection always carries a reason.
  async function handleApproveVerification(row) {
    // Approving is one-way — it lets the student post and chat at
    // once — so it needs the same confirm step as refunds and
    // cancels. A single stray tap used to approve with no check.
    // Milestone 25: the confirm names whoever is being approved —
    // a student by university + student ID, an ordinary user by
    // full name + country.
    const who =
      row.account_type === "ordinary"
        ? `${row.full_name || "this user"} (${row.country || "no country"}${row.currency ? ` · ${row.currency}` : ""})`
        : `${row.student_id} (${row.university})`;
    if (
      !window.confirm(
        `Approve verification for ${who}? They will be able to post and chat at once.`
      )
    ) {
      return;
    }
    setError("");
    setNotice("");
    setBusyAction(`approved-${row.user_id}`);
    try {
      await reviewVerification(row.user_id, "approved");
      setNotice(`Verification approved for ${who}. They can now post and chat.`);
      setViewingPhotos(null);
      await load();
    } catch (err) {
      setError(err?.message || "Could not update this verification.");
    } finally {
      setBusyAction("");
    }
  }

  // Milestone 19, Decision 3: reject with a REQUIRED reason from
  // the fixed list plus an optional short note (max 280 chars).
  // reviewVerification() (src/lib/listings.js) passes them to
  // review_verification(p_user_id, p_status, p_reason, p_note) —
  // Team B's RPC in supabase/m19/02-verification.sql, which also
  // refuses a rejection without a reason server-side. This page
  // does not re-implement the RPC. If the Milestone 19 SQL has not
  // been run yet, the call fails with a plain message and NOTHING
  // is rejected — the page never falls back to a reason-less
  // reject, or the reason the student is owed would be lost.
  async function handleConfirmReject() {
    if (!rejectFor || !rejectReason) return;
    // Entry guard: the button only disables after a re-render, so
    // a double-tap rejected the same student twice.
    if (busyAction) return;
    setError("");
    setNotice("");
    setBusyAction(`rejected-${rejectFor.user_id}`);
    try {
      await reviewVerification(
        rejectFor.user_id,
        "rejected",
        rejectReason,
        rejectNote.trim() ? rejectNote.trim() : null
      );
      const reasonLabel =
        REJECT_REASONS.find((r) => r.value === rejectReason)?.label || rejectReason;
      const rejectWho =
        rejectFor.account_type === "ordinary"
          ? `${rejectFor.full_name || "this user"} (${rejectFor.country || "no country"})`
          : `${rejectFor.student_id} (${rejectFor.university})`;
      setNotice(
        `Verification rejected for ${rejectWho} (${reasonLabel}). They can submit again with new photos.`
      );
      setRejectFor(null);
      setRejectReason("");
      setRejectNote("");
      setViewingPhotos(null);
      await load();
    } catch (err) {
      const message = String(err?.message || "");
      const rpcMissing =
        err?.code === "PGRST202" ||
        /could not find the function/i.test(message) ||
        /function .*review_verification.* does not exist/i.test(message);
      setError(
        rpcMissing
          ? "Rejection reasons are not switched on yet — the 4-argument review_verification RPC (Team B's Milestone 19 SQL) has not been run. Nothing was rejected. Run that SQL first, then reject again."
          : err?.message || "Could not update this verification."
      );
    } finally {
      setBusyAction("");
    }
  }

  // Milestone 19, Decision 5: nudge the buyer of a stuck shipped
  // order — a plain notification, nothing more. There is NO
  // auto-confirm anywhere on this page: a shipped order the buyer
  // has not confirmed never releases money by itself. After the
  // nudge, either the buyer confirms delivery, or the team resolves
  // it by hand (open dispute above, or the buyer opens a return
  // and the team resolves it on the tracking page).
  async function handleNudgeBuyer(order) {
    // Entry guard: the button only disables after a re-render, so
    // a double-tap sent the same nudge notification twice.
    if (busyAction) return;
    setError("");
    setNotice("");
    setBusyAction(`nudge-${order.id}`);
    try {
      const sent = await notifyUser(order.buyer_id, {
        kind: "order",
        title: "Delivery check — did your parcel arrive?",
        body: `Order ${order.code} shipped ${order.daysWaiting ?? "several"} days ago and delivery is still not confirmed. If the item arrived, confirm delivery on the order page; if it did not arrive, open a return or tell the PulseMarket team.`,
        link: `/order/${order.id}`,
        orderId: order.id,
      });
      if (!sent) {
        throw new Error("The nudge could not be sent — the notification was refused. Try again.");
      }
      setNudgedIds((prev) => (prev.includes(order.id) ? prev : [...prev, order.id]));
      setNotice(`Nudge sent to the buyer of order ${order.code}. No money moved — the order still waits for the buyer to confirm delivery.`);
    } catch (err) {
      setError(err?.message || "Could not send the nudge.");
    } finally {
      setBusyAction("");
    }
  }

  // Milestone 19 follow-up: finish one stuck order's half-written
  // money move. reconcileOrder() re-runs the matching idempotent
  // action — the money is never moved twice.
  async function handleReconcile(order) {
    setError("");
    setNotice("");
    setBusyAction(`reconcile-${order.id}`);
    try {
      const { note } = await reconcileOrder(order.id, user);
      setNotice(note || "Order reconciled.");
      await load();
    } catch (err) {
      setError(err?.message || "Could not reconcile this order.");
    } finally {
      setBusyAction("");
    }
  }

  // Milestone 19 follow-up: check a seller's outstanding debt
  // BEFORE paying a manual withdrawal by hand. Withdrawals are paid
  // outside the app (Wallet.jsx: the seller emails the team), so
  // this check refuses the payout in plain words while debt is
  // owed — it does not pay anything itself.
  async function handleDebtCheck(e) {
    e.preventDefault();
    const sellerId = debtSellerId.trim();
    if (!sellerId) {
      setError("Enter the seller's user ID first — it is shown on their pending verification row and on their orders.");
      return;
    }
    setError("");
    setNotice("");
    setBusyAction("debt-check");
    try {
      const amount = await sellerDebtAmount(sellerId);
      setDebtResult({ sellerId, amount });
    } catch (err) {
      setError(err?.message || "Could not check that seller's debt.");
      setDebtResult(null);
    } finally {
      setBusyAction("");
    }
  }

  if (authLoading) {
    return (
      <div className="mx-auto max-w-3xl px-4 py-6">
        <p className="text-sm text-neutral-500">Loading…</p>
      </div>
    );
  }

  // No mention of admin, no links, no hints for anyone else.
  if (!user || !isOwner) {
    return (
      <div className="mx-auto max-w-3xl px-4 py-6">
        <p className="text-sm text-neutral-500">This page is not available.</p>
      </div>
    );
  }

  const openDisputes = disputes.filter((d) => d.status === "open" || d.status === "under_review");
  const resolvedDisputes = disputes.filter((d) => d.status === "resolved");
  const selected = disputes.find((d) => d.id === selectedId) || null;

  return (
    <div className="mx-auto max-w-3xl px-4 py-6">
      <h1 className="text-xl font-bold">PulseMarket team</h1>
      <p className="mt-1 text-sm text-neutral-500">Signed in as {OWNER_EMAIL}</p>

      {loading ? (
        <p className="mt-6 text-sm text-neutral-500">Loading…</p>
      ) : (
        <>
          {error ? <p className="mt-4 text-sm text-red-600">{error}</p> : null}
          {notice ? <p className="mt-4 text-sm font-semibold text-brown-dark">{notice}</p> : null}

          {/* Milestone 17 — Pending verifications */}
          <section className="mt-6">
            <h2 className="font-semibold">Pending verifications ({pendingVerifications.length})</h2>
            <p className="mt-1 text-xs text-neutral-500">
              Students and ordinary users waiting for approval. Check both
              sides of a student ID — or the selfie (and government ID, if
              any) for an ordinary user — before deciding. Approving lets
              them post and chat, rejecting sends them back to submit again
              with new photos. Photo links work for an hour, then expire.
            </p>
            {pendingError ? <p className="mt-2 text-sm text-red-600">{pendingError}</p> : null}
            {pendingVerifications.length === 0 ? (
              <p className="mt-2 text-sm text-neutral-500">No verifications waiting.</p>
            ) : (
              <ul className="mt-2 space-y-2">
                {pendingVerifications.map((v) => (
                  <li
                    key={v.user_id}
                    className="rounded-xl border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950"
                  >
                    <span className="inline-block rounded-full bg-brown-soft px-2 py-0.5 text-xs font-bold text-brown-dark">
                      {v.account_type === "ordinary" ? "Ordinary" : "Student"}
                    </span>
                    {v.account_type === "ordinary" ? (
                      <>
                        <p className="mt-1 text-sm font-bold">{v.full_name || "No name"}</p>
                        <p className="text-sm">
                          {v.country || "No country"} · {v.currency || "NGN"}
                        </p>
                      </>
                    ) : (
                      <>
                        <p className="mt-1 text-sm font-bold">{v.university}</p>
                        <p className="text-sm">Student ID: {v.student_id}</p>
                      </>
                    )}
                    <p className="text-xs text-neutral-500">
                      {v.account_type === "ordinary"
                        ? ""
                        : `${v.student_email || "No student email"} · `}
                      {timeAgo(v.created_at)}
                    </p>
                    <p className="mt-1 text-xs text-neutral-500">User: {v.user_id}</p>
                    {v.account_type === "ordinary" ? (
                      !v.face_photo_url ? (
                        <p className="mt-2 text-sm text-red-600">
                          No selfie on file — reject so they can submit one.
                        </p>
                      ) : null
                    ) : !v.id_front_url && !v.id_back_url ? (
                      <p className="mt-2 text-sm text-red-600">
                        No ID photo on file — this student verified before photos
                        were collected. Approve only if you know this student, or
                        reject so they can submit photos.
                      </p>
                    ) : null}
                    <div className="mt-2 flex flex-wrap gap-2">
                      <GhostButton
                        type="button"
                        disabled={busyAction !== ""}
                        onClick={() => handleViewPhotos(v)}
                      >
                        {busyAction === `photos-${v.user_id}`
                          ? "Opening…"
                          : viewingPhotos === v.user_id
                            ? v.account_type === "ordinary"
                              ? "Hide photos"
                              : "Hide ID photos"
                            : v.account_type === "ordinary"
                              ? "View selfie + ID"
                              : "View ID photos"}
                      </GhostButton>
                      <GhostButton
                        type="button"
                        disabled={busyAction !== ""}
                        onClick={() => handleApproveVerification(v)}
                      >
                        {busyAction === `approved-${v.user_id}` ? "Approving…" : "Approve"}
                      </GhostButton>
                      <GhostButton
                        type="button"
                        disabled={busyAction !== ""}
                        onClick={() => {
                          setRejectFor(v);
                          setRejectReason("");
                          setRejectNote("");
                          setError("");
                        }}
                      >
                        Reject
                      </GhostButton>
                    </div>
                    {/* Milestone 19, Decision 3 — rejection reason picker.
                        A reason is required before the Reject call goes
                        through; the note is optional (max 280 chars). */}
                    {rejectFor?.user_id === v.user_id ? (
                      <div className="mt-3 rounded-xl border border-neutral-200 p-3 dark:border-neutral-800">
                        <p className="text-sm font-bold">
                          Why are you rejecting {v.account_type === "ordinary" ? "this user" : "this student"}?
                        </p>
                        <p className="mt-1 text-xs text-neutral-500">
                          They see this reason, so pick the one that
                          matches — they resubmit with new photos.
                        </p>
                        <div className="mt-2 space-y-1">
                          {REJECT_REASONS.map((r) => (
                            <label key={r.value} className="flex items-center gap-2 text-sm">
                              <input
                                type="radio"
                                name={`reject-reason-${v.user_id}`}
                                checked={rejectReason === r.value}
                                onChange={() => setRejectReason(r.value)}
                              />
                              {r.label}
                            </label>
                          ))}
                        </div>
                        <label className="mt-2 block text-sm font-semibold">
                          Note for the student (optional)
                          <textarea
                            className={`${inputCls} mt-1 min-h-16`}
                            value={rejectNote}
                            onChange={(e) => setRejectNote(e.target.value.slice(0, 280))}
                            placeholder="One short line, e.g. which photo was blurry."
                            maxLength={280}
                          />
                        </label>
                        <p className="mt-1 text-xs text-neutral-500">{rejectNote.length}/280</p>
                        <div className="mt-2 flex flex-wrap gap-2">
                          <GhostButton
                            type="button"
                            disabled={busyAction !== "" || !rejectReason}
                            onClick={handleConfirmReject}
                          >
                            {busyAction === `rejected-${v.user_id}` ? "Rejecting…" : "Confirm reject"}
                          </GhostButton>
                          <GhostButton
                            type="button"
                            disabled={busyAction !== ""}
                            onClick={() => {
                              setRejectFor(null);
                              setRejectReason("");
                              setRejectNote("");
                            }}
                          >
                            Cancel
                          </GhostButton>
                        </div>
                        {!rejectReason ? (
                          <p className="mt-2 text-xs text-neutral-500">Pick a reason first — a rejection needs one.</p>
                        ) : null}
                      </div>
                    ) : null}
                    {viewingPhotos === v.user_id && photoUrls[v.user_id] ? (
                      <div className="mt-3 grid grid-cols-2 gap-2">
                        <div>
                          <p className="text-xs font-semibold text-neutral-500">
                            {v.account_type === "ordinary" ? "Selfie" : "ID front"}
                          </p>
                          {photoUrls[v.user_id].front ? (
                            <img src={photoUrls[v.user_id].front} alt={v.account_type === "ordinary" ? "Selfie" : "Student ID front"} className="mt-1 w-full rounded-lg object-contain" />
                          ) : (
                            <p className="mt-1 text-sm text-neutral-500">No photo on file.</p>
                          )}
                        </div>
                        <div>
                          <p className="text-xs font-semibold text-neutral-500">
                            {v.account_type === "ordinary" ? "Government ID" : "ID back"}
                          </p>
                          {photoUrls[v.user_id].back ? (
                            <img src={photoUrls[v.user_id].back} alt={v.account_type === "ordinary" ? "Government ID" : "Student ID back"} className="mt-1 w-full rounded-lg object-contain" />
                          ) : (
                            <p className="mt-1 text-sm text-neutral-500">
                              {v.account_type === "ordinary" ? "No government ID on file (optional)." : "No back photo on file."}
                            </p>
                          )}
                        </div>
                      </div>
                    ) : null}
                  </li>
                ))}
              </ul>
            )}
          </section>

          {/* (a) Open disputes */}
          <section className="mt-6">
            <h2 className="font-semibold">Open disputes ({openDisputes.length})</h2>
            {openDisputes.length === 0 ? (
              <p className="mt-2 text-sm text-neutral-500">No open disputes.</p>
            ) : (
              <ul className="mt-2 space-y-2">
                {openDisputes.map((d) => (
                  <li
                    key={d.id}
                    className="rounded-xl border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950"
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0">
                        <p className="text-sm font-bold">{d.ticket_id}</p>
                        <p className="text-sm">{d.category}</p>
                        <p className="text-xs text-neutral-500">
                          {d.email} · {timeAgo(d.created_at)} · {d.status}
                        </p>
                      </div>
                      <GhostButton type="button" onClick={() => openDispute(d)}>
                        {selectedId === d.id ? "Open" : "Review"}
                      </GhostButton>
                    </div>

                    {selected && selected.id === d.id ? (
                      <div className="mt-3 border-t border-neutral-200 pt-3 dark:border-neutral-800">
                        <p className="text-xs font-semibold text-neutral-500">What the buyer said</p>
                        <p className="mt-1 whitespace-pre-wrap text-sm">{d.explanation}</p>

                        <p className="mt-3 text-xs font-semibold text-neutral-500">Order</p>
                        {loadingDispute ? (
                          <p className="mt-1 text-sm text-neutral-500">Loading order…</p>
                        ) : selectedOrder ? (
                          <p className="mt-1 text-sm">
                            {selectedOrder.code} · {selectedOrder.status} ·{" "}
                            {formatMoney(selectedOrder.total)} · {selectedOrder.payment_method} ·{" "}
                            {selectedOrder.delivery_method}
                            {selectedOrder.frozen ? " · Frozen" : ""}
                          </p>
                        ) : (
                          <p className="mt-1 text-sm text-neutral-500">Order could not be loaded.</p>
                        )}

                        <p className="mt-3 text-xs font-semibold text-neutral-500">Evidence</p>
                        {loadingDispute ? (
                          <p className="mt-1 text-sm text-neutral-500">Loading evidence…</p>
                        ) : selectedEvidence.length === 0 ? (
                          <p className="mt-1 text-sm text-neutral-500">No evidence on this order.</p>
                        ) : (
                          <ul className="mt-1 space-y-1">
                            {selectedEvidence.map((item) => (
                              <li key={item.id} className="text-sm">
                                <a
                                  href={signedEvidenceUrls.get(item.url) || item.url}
                                  target="_blank"
                                  rel="noreferrer"
                                  className="font-semibold text-brown-dark underline"
                                >
                                  {item.kind} — {item.media_type}
                                  {item.media_type === "video" ? ` · ${item.duration_seconds ?? "?"}s` : ""}
                                </a>{" "}
                                <span className="text-xs text-neutral-500">
                                  {item.verified ? "Verified ✓" : `Not verified — ${item.verified_reason || ""}`}
                                  {" · "}
                                  {timeAgo(item.created_at)}
                                </span>
                              </li>
                            ))}
                          </ul>
                        )}

                        <form onSubmit={handleResolve} className="mt-4">
                          <label className="text-xs font-semibold text-neutral-500" htmlFor="resolution-note">
                            Resolution note
                          </label>
                          <textarea
                            id="resolution-note"
                            className={`${inputCls} mt-1 min-h-20`}
                            value={resolutionNote}
                            onChange={(e) => setResolutionNote(e.target.value)}
                            placeholder="Say how this was decided, in one or two lines."
                            maxLength={1000}
                            disabled={resolving}
                          />
                          <p className="mt-1 text-xs text-neutral-500">
                            Outcome: resolved. Resolving does not move any money — money moves
                            only through the manual release or refund steps.
                          </p>
                          {resolutionNote.trim().length < 5 ? (
                            <p className="mt-1 text-xs text-neutral-500">
                              A note is required — write a short line (at least 5 characters) saying how this was decided.
                            </p>
                          ) : null}
                          <div className="mt-2">
                            <PrimaryButton type="submit" disabled={resolving || resolutionNote.trim().length < 5}>
                              {resolving ? "Resolving…" : "Mark resolved"}
                            </PrimaryButton>
                          </div>
                        </form>
                      </div>
                    ) : null}
                  </li>
                ))}
              </ul>
            )}

            {resolvedDisputes.length > 0 ? (
              <>
                <h3 className="mt-4 text-sm font-semibold">Resolved ({resolvedDisputes.length})</h3>
                <ul className="mt-2 space-y-1">
                  {resolvedDisputes.map((d) => (
                    <li key={d.id} className="text-sm text-neutral-500">
                      {d.ticket_id} · {d.category} · resolved {timeAgo(d.resolved_at)}
                    </li>
                  ))}
                </ul>
              </>
            ) : null}
          </section>

          {/* (c) Frozen orders */}
          <section className="mt-8">
            <h2 className="font-semibold">Frozen orders ({frozenOrders.length})</h2>
            <p className="mt-1 text-xs text-neutral-500">
              Money on these orders is frozen while a dispute is open. The 48-hour
              auto-release skips frozen orders.
            </p>
            {frozenOrders.length === 0 ? (
              <p className="mt-2 text-sm text-neutral-500">No frozen orders.</p>
            ) : (
              <ul className="mt-2 space-y-2">
                {frozenOrders.map((o) => (
                  <li
                    key={o.id}
                    className="rounded-xl border border-neutral-200 bg-white p-3 text-sm dark:border-neutral-800 dark:bg-neutral-950"
                  >
                    <span className="font-bold">{o.code}</span> · {o.status} ·{" "}
                    {formatMoney(o.total)} · {o.payment_method} · {timeAgo(o.created_at)}
                  </li>
                ))}
              </ul>
            )}
          </section>

          {/* (d) Held orders — seller never ships */}
          <section className="mt-8">
            <h2 className="font-semibold">Held orders ({heldOrders.length})</h2>
            <p className="mt-1 text-xs text-neutral-500">
              Money is held for these orders. If the seller never ships, refund the buyer
              here — the buyer gets item + shipping back (the fees stay with PulseMarket) and the listing goes
              back to active. Refunds need the milestone-20 database rule; until it runs
              this reports the database error and refunds nothing.
            </p>
            {heldOrders.length === 0 ? (
              <p className="mt-2 text-sm text-neutral-500">No held orders.</p>
            ) : (
              <ul className="mt-2 space-y-2">
                {heldOrders.map((o) => (
                  <li
                    key={o.id}
                    className="rounded-xl border border-neutral-200 bg-white p-3 text-sm dark:border-neutral-800 dark:bg-neutral-950"
                  >
                    <span className="font-bold">{o.code}</span> · {o.status} ·{" "}
                    {formatMoney(o.total)} · {o.delivery_method} · {timeAgo(o.created_at)}
                    <div className="mt-2">
                      <GhostButton
                        disabled={busyAction !== ""}
                        onClick={() => handleRefundHeld(o)}
                      >
                        {busyAction === `refund-${o.id}` ? "Refunding…" : "Refund buyer — seller never shipped"}
                      </GhostButton>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </section>

          {/* Milestone 20 (APP-9) — Paid orders: the buyer says they
              transferred, the team has not confirmed the money
              arrived yet. Oldest first. Cancelling one is a manual
              return of real money: the team returns the transfer by
              hand, and the cancel is written to the security log. */}
          <section className="mt-8">
            <h2 className="font-semibold">Paid orders ({paidOrders.length})</h2>
            <p className="mt-1 text-xs text-neutral-500">
              Buyers who marked their order paid, waiting for the team to confirm the transfer
              arrived. Oldest first — check the longest wait first. If the money never arrived
              or the order cannot go ahead, cancel it here and return the transfer by hand.
            </p>
            {paidError ? <p className="mt-2 text-sm text-red-600">{paidError}</p> : null}
            {paidOrders.length === 0 ? (
              <p className="mt-2 text-sm text-neutral-500">No paid orders waiting.</p>
            ) : (
              <ul className="mt-2 space-y-2">
                {paidOrders.map((o) => (
                  <li
                    key={o.id}
                    className="rounded-xl border border-neutral-200 bg-white p-3 text-sm dark:border-neutral-800 dark:bg-neutral-950"
                  >
                    <span className="font-bold">{o.code}</span> · {o.status} ·{" "}
                    {formatMoney(o.total)} · {o.delivery_method} · {timeAgo(o.created_at)}
                    <div className="mt-2">
                      <GhostButton
                        disabled={busyAction !== ""}
                        onClick={() => handleCancelPaid(o)}
                      >
                        {busyAction === `cancel-paid-${o.id}` ? "Cancelling…" : "Cancel — return the transfer by hand"}
                      </GhostButton>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </section>

          {/* Milestone 20 (M-2) — Boost requests: sellers asked for a
              boost and the team confirms the payment arrived by hand.
              Confirming marks the request paid and applies the boost
              to the listing. No bank details anywhere — payment is
              confirmed outside the app. */}
          <section className="mt-8">
            <h2 className="font-semibold">Boost requests ({boostRequests.length})</h2>
            <p className="mt-1 text-xs text-neutral-500">
              Sellers who asked for a boost. Confirm only after the payment has arrived by hand —
              confirming marks the request paid and boosts the listing.
            </p>
            {boostError ? <p className="mt-2 text-sm text-red-600">{boostError}</p> : null}
            {boostRequests.length === 0 && !boostError ? (
              <p className="mt-2 text-sm text-neutral-500">No boost requests waiting.</p>
            ) : null}
            {boostRequests.length > 0 ? (
              <ul className="mt-2 space-y-2">
                {boostRequests.map((r) => (
                  <li
                    key={r.id}
                    className="rounded-xl border border-neutral-200 bg-white p-3 text-sm dark:border-neutral-800 dark:bg-neutral-950"
                  >
                    <span className="font-bold">{r.listing_id || "Listing"}</span>
                    {" · "}
                    {r.boost_tier ?? r.tier ?? r.amount
                      ? formatMoney(r.boost_tier ?? r.tier ?? r.amount)
                      : "Boost"}
                    {" · "}
                    {timeAgo(r.created_at)}
                    <div className="mt-2">
                      <GhostButton
                        disabled={busyAction !== ""}
                        onClick={() => handleConfirmBoost(r)}
                      >
                        {busyAction === `boost-${r.id}` ? "Confirming…" : "Confirm — payment received"}
                      </GhostButton>
                    </div>
                  </li>
                ))}
              </ul>
            ) : null}
          </section>

          {/* Milestone 19, Decision 5 — shipped orders stuck with no
              auto-exit. NO auto-confirm: a shipped order never
              releases money by itself, because the buyer may never
              have received the parcel. The team nudges the buyer;
              then either the buyer confirms delivery, or the team
              resolves it by hand — an open dispute in "Open disputes"
              above, or a return the buyer opened, resolved on the
              tracking page. */}
          <section className="mt-8">
            <h2 className="font-semibold">Shipped orders waiting for the buyer ({staleShipped.length})</h2>
            <p className="mt-1 text-xs text-neutral-500">
              Held orders that shipped more than 7 days ago and the buyer still
              has not confirmed delivery. Nothing here confirms or releases
              anything on its own — nudge the buyer, then resolve by hand.
            </p>
            {staleError ? <p className="mt-2 text-sm text-red-600">{staleError}</p> : null}
            {staleShipped.length === 0 ? (
              <p className="mt-2 text-sm text-neutral-500">No shipped orders stuck waiting.</p>
            ) : (
              <ul className="mt-2 space-y-2">
                {staleShipped.map((o) => (
                  <li
                    key={o.id}
                    className="rounded-xl border border-neutral-200 bg-white p-3 text-sm dark:border-neutral-800 dark:bg-neutral-950"
                  >
                    <span className="font-bold">{o.code}</span> · {formatMoney(o.total)} ·{" "}
                    {o.delivery_method} · Sent with {o.courier || "transport to be agreed"}{o.transport_ref ? ` · Plate / flight: ${o.transport_ref}` : ""} · shipped{" "}
                    {o.daysWaiting} day{o.daysWaiting === 1 ? "" : "s"} ago · {timeAgo(o.shipping_proof_at || o.updated_at)}
                    <div className="mt-2 flex flex-wrap gap-2">
                      <GhostButton
                        disabled={busyAction !== "" || nudgedIds.includes(o.id)}
                        onClick={() => handleNudgeBuyer(o)}
                      >
                        {busyAction === `nudge-${o.id}`
                          ? "Nudging…"
                          : nudgedIds.includes(o.id)
                            ? "Nudge sent ✓"
                            : "Nudge buyer"}
                      </GhostButton>
                      <GhostButton
                        disabled={busyAction !== ""}
                        onClick={() => handleRefundHeld(o, true)}
                      >
                        {busyAction === `refund-${o.id}` ? "Refunding…" : "Refund buyer — buyer never confirmed"}
                      </GhostButton>
                      <a
                        href={`/order/${o.id}`}
                        target="_blank"
                        rel="noreferrer"
                        className="rounded-full border border-neutral-300 px-3 py-1 text-sm font-semibold dark:border-neutral-700"
                      >
                        Open order
                      </a>
                    </div>
                    <p className="mt-2 text-xs text-neutral-500">
                      Hand-resolve only: if the buyer opens a dispute, resolve it in
                      Open disputes above; if the buyer opens a return, resolve it
                      on the tracking page. Never release money for a shipped order
                      the buyer has not confirmed. If the buyer has ghosted for good,
                      refund the buyer here — item + shipping comes back (the fees
                      stay with PulseMarket) and the listing goes live again.
                    </p>
                  </li>
                ))}
              </ul>
            )}
          </section>

          {/* Milestone 19 follow-up — stuck money: the money moved, the
              status update never landed. Reconciling re-runs the matching
              idempotent action and finishes the status update; the money
              is never moved twice. */}
          <section className="mt-8">
            <h2 className="font-semibold">Stuck money ({stuckMoney.length})</h2>
            <p className="mt-1 text-xs text-neutral-500">
              Orders where the ledger and the status disagree — a hold, refund
              or release was written but the order still says paid, held or
              delivered. Reconciling finishes the half-written move.
            </p>
            {stuckError ? <p className="mt-2 text-sm text-red-600">{stuckError}</p> : null}
            {stuckMoney.length === 0 ? (
              <p className="mt-2 text-sm text-neutral-500">No stuck money orders.</p>
            ) : (
              <ul className="mt-2 space-y-2">
                {stuckMoney.map(({ order, problem, action }) => (
                  <li
                    key={order.id}
                    className="rounded-xl border border-neutral-200 bg-white p-3 text-sm dark:border-neutral-800 dark:bg-neutral-950"
                  >
                    <span className="font-bold">{order.code}</span> · {order.status} ·{" "}
                    {formatMoney(order.total)} · {timeAgo(order.created_at)}
                    <p className="mt-1">{problem}</p>
                    <p className="text-xs text-neutral-500">Fix: {action}</p>
                    <div className="mt-2">
                      <GhostButton
                        disabled={busyAction !== ""}
                        onClick={() => handleReconcile(order)}
                      >
                        {busyAction === `reconcile-${order.id}` ? "Reconciling…" : "Reconcile — finish the move"}
                      </GhostButton>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </section>

          {/* Milestone 19 follow-up — debt check before a manual
              withdrawal payout. Withdrawals are paid by hand by the team
              (the seller emails the team), so this check is the gate:
              while the seller owes money, the payout is refused in plain
              words. This section pays nothing itself. */}
          <section className="mt-8">
            <h2 className="font-semibold">Withdrawal check — seller debt</h2>
            <p className="mt-1 text-xs text-neutral-500">
              Before paying any withdrawal by hand, check what the seller owes
              from earlier orders (unpaid shipping advances from seller-fault
              returns, minus repayments). If debt is owed, do NOT pay.
            </p>
            <form onSubmit={handleDebtCheck} className="mt-2 space-y-2">
              <label className="block text-sm font-semibold">
                Seller user ID
                <input
                  className={`${inputCls} mt-1`}
                  placeholder="Seller's user ID (from their verification row or an order)"
                  value={debtSellerId}
                  onChange={(e) => setDebtSellerId(e.target.value)}
                />
              </label>
              <div>
                <PrimaryButton type="submit" disabled={busyAction !== ""}>
                  {busyAction === "debt-check" ? "Checking…" : "Check debt before payout"}
                </PrimaryButton>
              </div>
            </form>
            {debtResult ? (
              debtResult.amount > 0 ? (
                <p className="mt-2 rounded-xl bg-red-50 px-3 py-2 text-sm font-semibold text-red-700">
                  Do NOT pay this withdrawal — this seller owes {formatMoney(debtResult.amount)} back to
                  PulseMarket. Settle the debt first, then pay.
                </p>
              ) : (
                <p className="mt-2 rounded-xl bg-neutral-100 px-3 py-2 text-sm dark:bg-neutral-900">
                  No debt owed — a manual payout may go ahead. Pay by hand as usual; this page
                  does not move any money.
                </p>
              )
            ) : null}
          </section>

          {/* (e) Locked handoffs */}
          <section className="mt-8">
            <h2 className="font-semibold">Locked handoffs ({lockedHandoffs.length})</h2>
            <p className="mt-1 text-xs text-neutral-500">
              Five wrong seller codes locked these meetups — the held money can neither be
              delivered nor released until the handoff is unlocked. Unlocking resets the
              attempt count; it does not unflag the buyer.
            </p>
            {lockedHandoffs.length === 0 ? (
              <p className="mt-2 text-sm text-neutral-500">No locked handoffs.</p>
            ) : (
              <ul className="mt-2 space-y-2">
                {lockedHandoffs.map((o) => (
                  <li
                    key={o.id}
                    className="rounded-xl border border-neutral-200 bg-white p-3 text-sm dark:border-neutral-800 dark:bg-neutral-950"
                  >
                    <span className="font-bold">{o.code}</span> · {o.status} ·{" "}
                    {formatMoney(o.total)} · {o.code_attempts || 5} wrong codes · {timeAgo(o.created_at)}
                    <div className="mt-2">
                      <GhostButton
                        disabled={busyAction !== ""}
                        onClick={() => handleUnlockHandoff(o)}
                      >
                        {busyAction === `unlock-${o.id}` ? "Unlocking…" : "Unlock handoff"}
                      </GhostButton>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </section>

          {/* (b) Security log */}
          <section className="mt-8">
            <h2 className="font-semibold">Security log (latest {securityLog.length})</h2>
            {securityLog.length === 0 ? (
              <p className="mt-2 text-sm text-neutral-500">No security events yet.</p>
            ) : (
              <ul className="mt-2 space-y-2">
                {securityLog.map((row) => (
                  <li
                    key={row.id}
                    className="rounded-xl border border-neutral-200 bg-white p-3 text-sm dark:border-neutral-800 dark:bg-neutral-950"
                  >
                    <p className="font-semibold">{row.action}</p>
                    {row.detail ? <p className="text-neutral-600 dark:text-neutral-400">{row.detail}</p> : null}
                    <p className="mt-1 text-xs text-neutral-500">{timeAgo(row.created_at)}</p>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </>
      )}
    </div>
  );
}
