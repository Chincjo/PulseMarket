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
import { useCallback, useEffect, useState } from "react";
import { useAuth } from "../lib/auth";
import { fetchHeldOrders, fetchOrder, refundHeldOrder } from "../lib/orders";
import { fetchLockedHandoffs, unlockHandoff } from "../lib/handoff";
import { fetchEvidenceForOrder } from "../lib/evidence";
import {
  fetchAllDisputes,
  fetchFrozenOrders,
  fetchSecurityLog,
  isOwnerUser,
  resolveDispute,
} from "../lib/disputes";
import {
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
  const [busyAction, setBusyAction] = useState("");
  const [selectedId, setSelectedId] = useState(null);
  const [selectedOrder, setSelectedOrder] = useState(null);
  const [selectedEvidence, setSelectedEvidence] = useState([]);
  const [resolutionNote, setResolutionNote] = useState("");
  const [resolving, setResolving] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

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
  }, [isOwner, user]);

  useEffect(() => {
    load();
  }, [load]);

  async function openDispute(dispute) {
    setSelectedId(dispute.id);
    setSelectedOrder(null);
    setSelectedEvidence([]);
    setResolutionNote("");
    setNotice("");
    setError("");
    try {
      const [order, rows] = await Promise.all([
        fetchOrder(dispute.order_id),
        fetchEvidenceForOrder(dispute.order_id),
      ]);
      setSelectedOrder(order);
      setSelectedEvidence(rows || []);
    } catch (err) {
      setError(err?.message || "Could not load this dispute.");
    }
  }

  async function handleResolve(e) {
    e.preventDefault();
    if (!selectedId) return;
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

  // Held order whose seller never ships: refund the buyer (item
  // price + shipping) and put the listing back to active. Needs the
  // milestone-16 database rule — until it runs this reports the
  // database error and refunds nothing.
  async function handleRefundHeld(order) {
    if (
      !window.confirm(
        `Refund order ${order.code}? The buyer gets the item price + shipping back (${formatMoney(
          (order.item_price || 0) + (order.shipping_fee || 0)
        )}) and the listing goes back to active.`
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
  // public link. Already-opened links are reused until the list
  // refreshes. A student with no photos on file has nothing to open.
  async function handleViewPhotos(row) {
    if (viewingPhotos === row.user_id) {
      setViewingPhotos(null);
      return;
    }
    setViewingPhotos(row.user_id);
    if (photoUrls[row.user_id]) return;
    setError("");
    setBusyAction(`photos-${row.user_id}`);
    try {
      const [front, back] = await Promise.all([
        verificationIdPhotoUrl(row.id_front_url),
        verificationIdPhotoUrl(row.id_back_url),
      ]);
      setPhotoUrls((prev) => ({ ...prev, [row.user_id]: { front, back } }));
    } catch (err) {
      setError(err?.message || "Could not open the ID photos. Try again.");
      setViewingPhotos(null);
    } finally {
      setBusyAction("");
    }
  }

  // Milestone 17: team decision on one student. Approving lets them
  // post and chat at once; rejecting sends them back to submit again
  // with new photos — nothing about them is deleted. The list
  // refreshes after the action, so a decided student leaves the queue.
  async function handleReviewVerification(row, status) {
    if (
      status === "rejected" &&
      !window.confirm(
        `Reject the verification for ${row.student_id} (${row.university})? They will need to submit again with new ID photos.`
      )
    ) {
      return;
    }
    setError("");
    setNotice("");
    setBusyAction(`${status}-${row.user_id}`);
    try {
      await reviewVerification(row.user_id, status);
      setNotice(
        status === "approved"
          ? `Verification approved for ${row.student_id} (${row.university}). They can now post and chat.`
          : `Verification rejected for ${row.student_id}. They can submit again with new photos.`
      );
      setViewingPhotos(null);
      await load();
    } catch (err) {
      setError(err?.message || "Could not update this verification.");
    } finally {
      setBusyAction("");
    }
  }

  if (authLoading) {
    return (
      <main className="mx-auto max-w-3xl px-4 py-6">
        <p className="text-sm text-neutral-500">Loading…</p>
      </main>
    );
  }

  // No mention of admin, no links, no hints for anyone else.
  if (!user || !isOwner) {
    return (
      <main className="mx-auto max-w-3xl px-4 py-6">
        <p className="text-sm text-neutral-500">This page is not available.</p>
      </main>
    );
  }

  const openDisputes = disputes.filter((d) => d.status === "open" || d.status === "under_review");
  const resolvedDisputes = disputes.filter((d) => d.status === "resolved");
  const selected = disputes.find((d) => d.id === selectedId) || null;

  return (
    <main className="mx-auto max-w-3xl px-4 py-6">
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
              Students waiting for approval. Check both sides of their student
              ID before deciding — approving lets them post and chat, rejecting
              sends them back to submit again with new photos. Photo links
              work for an hour, then expire.
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
                    <p className="text-sm font-bold">{v.university}</p>
                    <p className="text-sm">Student ID: {v.student_id}</p>
                    <p className="text-xs text-neutral-500">
                      {v.student_email || "No student email"} · {timeAgo(v.created_at)}
                    </p>
                    <p className="mt-1 text-xs text-neutral-500">User: {v.user_id}</p>
                    {!v.id_front_url && !v.id_back_url ? (
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
                            ? "Hide ID photos"
                            : "View ID photos"}
                      </GhostButton>
                      <GhostButton
                        type="button"
                        disabled={busyAction !== ""}
                        onClick={() => handleReviewVerification(v, "approved")}
                      >
                        {busyAction === `approved-${v.user_id}` ? "Approving…" : "Approve"}
                      </GhostButton>
                      <GhostButton
                        type="button"
                        disabled={busyAction !== ""}
                        onClick={() => handleReviewVerification(v, "rejected")}
                      >
                        {busyAction === `rejected-${v.user_id}` ? "Rejecting…" : "Reject"}
                      </GhostButton>
                    </div>
                    {viewingPhotos === v.user_id && photoUrls[v.user_id] ? (
                      <div className="mt-3 grid grid-cols-2 gap-2">
                        <div>
                          <p className="text-xs font-semibold text-neutral-500">ID front</p>
                          {photoUrls[v.user_id].front ? (
                            <img src={photoUrls[v.user_id].front} alt="Student ID front" className="mt-1 w-full rounded-lg object-contain" />
                          ) : (
                            <p className="mt-1 text-sm text-neutral-500">No front photo on file.</p>
                          )}
                        </div>
                        <div>
                          <p className="text-xs font-semibold text-neutral-500">ID back</p>
                          {photoUrls[v.user_id].back ? (
                            <img src={photoUrls[v.user_id].back} alt="Student ID back" className="mt-1 w-full rounded-lg object-contain" />
                          ) : (
                            <p className="mt-1 text-sm text-neutral-500">No back photo on file.</p>
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
                        {selectedOrder ? (
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
                        {selectedEvidence.length === 0 ? (
                          <p className="mt-1 text-sm text-neutral-500">No evidence on this order.</p>
                        ) : (
                          <ul className="mt-1 space-y-1">
                            {selectedEvidence.map((item) => (
                              <li key={item.id} className="text-sm">
                                <a
                                  href={item.url}
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
                          <div className="mt-2">
                            <PrimaryButton type="submit" disabled={resolving}>
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
              here — the buyer gets the item price + shipping back and the listing goes
              back to active. Refunds need the milestone-16 database rule; until it runs
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
    </main>
  );
}
