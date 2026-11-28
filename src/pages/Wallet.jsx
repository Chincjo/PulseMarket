// Milestone 6 — Wallet (rewrite). Balances come only from the ledger:
// getBalances() sums wallet_ledger by bucket, so nothing here is a stored
// or demo number. Withdrawals are paid manually by the PulseMarket team —
// asking for one changes nothing in the ledger; money leaves only when
// the team actually pays.
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { formatNaira } from "../lib/fees";
import { fetchLedgerChecked, getBalancesChecked } from "../lib/wallet";
import { OWNER_EMAIL } from "../lib/payments";
import { useAuth } from "../lib/auth";
import { EmptyState, GhostButton, PrimaryButton } from "../components/ui";

const KIND_LABELS = {
  hold: "Held",
  release: "Released",
  refund: "Refund",
  shipping_advance: "Shipping advance",
  withdrawal: "Withdrawal",
  debt: "Debt",
  repayment: "Repayment",
};

export default function Wallet() {
  const { user } = useAuth();
  const [balances, setBalances] = useState({ held: 0, available: 0 });
  const [ledger, setLedger] = useState([]);
  const [ledgerHasMore, setLedgerHasMore] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [loading, setLoading] = useState(true);
  // Morning deep check 2026-11-28: a failed wallet read used to
  // look exactly like an empty wallet — ₦0 held, ₦0 available, no
  // error — so a funded seller could think they had nothing. The
  // checked reads below tell a failure apart from an empty wallet.
  const [loadFailed, setLoadFailed] = useState(false);
  // Bumped by the retry button so the load effect runs again.
  const [reloadKey, setReloadKey] = useState(0);
  const [showWithdraw, setShowWithdraw] = useState(false);
  const [copied, setCopied] = useState("");

  useEffect(() => {
    let cancelled = false;
    if (!user) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setLoadFailed(false);
    Promise.all([getBalancesChecked(user.id), fetchLedgerChecked(user.id)])
      .then(([b, l]) => {
        if (cancelled) return;
        setBalances(b.balances);
        setLedger(l.rows);
        setLedgerHasMore(l.rows.hasMore === true);
        // Either read failing means the numbers on screen cannot be
        // trusted — say so instead of showing ₦0.
        setLoadFailed(b.failed || l.failed);
        setLoading(false);
      })
      .catch(() => {
        if (!cancelled) {
          setLoadFailed(true);
          setLoading(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [user, reloadKey]);

  const total = balances.held + balances.available;

  // Next page of the ledger, from the last row's created_at.
  async function loadMoreLedger() {
    if (!user || loadingMore || !ledgerHasMore || ledger.length === 0) return;
    setLoadingMore(true);
    try {
      const { rows, failed } = await fetchLedgerChecked(user.id, {
        before: ledger[ledger.length - 1].createdAt,
      });
      if (failed) {
        setLoadFailed(true);
        return;
      }
      setLedger((prev) => [...prev, ...(rows || [])]);
      setLedgerHasMore(rows.hasMore === true);
    } finally {
      setLoadingMore(false);
    }
  }

  function copyEmail() {
    if (navigator.clipboard?.writeText) {
      navigator.clipboard
        .writeText(OWNER_EMAIL)
        .then(() => setCopied("Email copied."))
        .catch(() => setCopied("Copy failed — the email is " + OWNER_EMAIL));
    } else {
      setCopied("Copy failed — the email is " + OWNER_EMAIL);
    }
  }

  return (
    <div className="space-y-5">
      <h1 className="text-2xl font-bold">Wallet</h1>

      {loadFailed && (
        <div className="rounded-2xl border border-red-300 bg-red-50 p-4 dark:border-red-900 dark:bg-red-950">
          <p className="text-sm font-semibold">Could not load your wallet — the numbers below may be wrong.</p>
          <p className="mt-1 text-sm text-neutral-600 dark:text-neutral-300">
            Your money is safe — the read itself failed, so the wallet is showing ₦0 instead of your real balance.{" "}
            <button type="button" className="font-semibold text-brown underline" onClick={() => setReloadKey((k) => k + 1)}>
              Try again
            </button>
          </p>
        </div>
      )}

      <div className="rounded-2xl border border-neutral-200 p-4 text-center dark:border-neutral-800">
        <p className="text-3xl font-bold">{formatNaira(total)}</p>
        <p className="text-xs text-neutral-500">Total balance</p>
      </div>
      <div className="grid grid-cols-2 gap-2 text-center">
        <div className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
          <p className="text-xl font-bold">{formatNaira(balances.available)}</p>
          <p className="text-xs text-neutral-500">Available</p>
        </div>
        <div className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
          <p className="text-xl font-bold">{formatNaira(balances.held)}</p>
          <p className="text-xs text-neutral-500">In hold</p>
        </div>
      </div>
      <p className="text-xs text-neutral-500">
        “In hold” is money from orders waiting for the buyer to confirm delivery.
        “Available” is money released to you. Balances are added up from the
        ledger below — never stored.
      </p>

      <PrimaryButton
        className="w-full py-3"
        disabled={balances.available <= 0}
        onClick={() => setShowWithdraw(true)}
      >
        Withdraw
      </PrimaryButton>
      {balances.available <= 0 && (
        <p className="text-center text-xs text-neutral-500">
          Withdraw opens once you have available money.
        </p>
      )}

      {showWithdraw && (
        <div className="rounded-2xl border border-brown bg-brown-soft p-4">
          <h2 className="text-lg font-bold">Request a withdrawal — {formatNaira(balances.available)}</h2>
          <p className="mt-1 text-sm">
            Withdrawals are paid manually by the PulseMarket team. Email{" "}
            <span className="font-semibold underline">{OWNER_EMAIL}</span> with the
            amount ({formatNaira(balances.available)}) and your bank details (bank,
            account number, account name). Asking for a withdrawal does not move any
            money — it only leaves your wallet when the team actually pays you.
          </p>
          <div className="mt-3 flex gap-2">
            <GhostButton onClick={copyEmail}>Copy support email</GhostButton>
            <GhostButton onClick={() => setShowWithdraw(false)}>Close</GhostButton>
          </div>
          {copied && <p className="mt-2 text-sm text-neutral-500">{copied}</p>}
        </div>
      )}

      <h2 className="text-lg font-bold">Money in / out</h2>
      {loading ? (
        <p className="text-sm text-neutral-500">Loading wallet…</p>
      ) : ledger.length === 0 ? (
        <EmptyState
          title="No money movement yet"
          body="Held payments, releases and refunds will show here, computed from the ledger — never from a stored balance."
        />
      ) : (
        <>
          <p className="text-sm text-neutral-500">
            Showing the first {ledger.length} {ledger.length === 1 ? "entry" : "entries"}
            {ledgerHasMore ? " — older entries are below." : "."}
          </p>
          <ul className="space-y-2">
            {ledger.map((entry) => (
            <li
              key={entry.id}
              className="rounded-2xl border border-neutral-200 p-3 dark:border-neutral-800"
            >
              <div className="flex items-center justify-between gap-2">
                <p className="text-sm font-semibold">
                  {KIND_LABELS[entry.kind] || entry.kind}
                  <span className="ml-2 font-normal text-neutral-500">
                    · {entry.bucket === "held" ? "In hold" : "Available"}
                  </span>
                </p>
                <p className={`text-sm font-bold ${entry.amount < 0 ? "text-neutral-500" : ""}`}>
                  {entry.amount < 0 ? "−" : "+"}
                  {formatNaira(Math.abs(entry.amount))}
                </p>
              </div>
              <p className="mt-1 text-xs text-neutral-500">
                {entry.orderCode ? (
                  <Link to={`/order/${entry.orderId}`} className="font-semibold text-brown">
                    {entry.orderCode}
                  </Link>
                ) : (
                  "No order"
                )}
                {" · "}
                {new Date(entry.createdAt).toLocaleString("en-NG")}
              </p>
              {entry.note && <p className="mt-1 text-xs text-neutral-500">{entry.note}</p>}
            </li>
          ))}
          </ul>
          {ledgerHasMore && (
            <GhostButton className="w-full py-3" disabled={loadingMore} onClick={loadMoreLedger}>
              {loadingMore ? "Loading…" : "Load more"}
            </GhostButton>
          )}
        </>
      )}
    </div>
  );
}
