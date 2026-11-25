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
import { fetchOrder } from "../lib/orders";
import { fetchEvidenceForOrder } from "../lib/evidence";
import {
  fetchAllDisputes,
  fetchFrozenOrders,
  fetchSecurityLog,
  isOwnerUser,
  resolveDispute,
} from "../lib/disputes";
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
      const [allDisputes, log, frozen] = await Promise.all([
        fetchAllDisputes(),
        fetchSecurityLog(100),
        fetchFrozenOrders(),
      ]);
      setDisputes(allDisputes || []);
      setSecurityLog(log || []);
      setFrozenOrders(frozen || []);
    } catch (err) {
      setError(err?.message || "Could not load the team panel.");
    } finally {
      setLoading(false);
    }
  }, [isOwner]);

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
