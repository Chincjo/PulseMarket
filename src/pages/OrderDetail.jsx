// Milestone 6 — Order detail (route /order/:id, added by the
// coordinator). Shows the order code (the bank-transfer reference),
// the full fee breakdown, manual-escrow payment instructions, the
// status timeline, and the actions each role may take at each status.
import { useCallback, useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { formatNaira } from "../lib/fees";
import { autoReleaseDue } from "../lib/autoRelease";
import { fetchListing } from "../lib/listings";
import { fetchEvidenceForOrder } from "../lib/evidence";
import {
  cancelOrder,
  confirmDelivery,
  confirmReceipt,
  fetchOrder,
  markPaid,
  releaseOrder,
} from "../lib/orders";
import {
  OWNER_EMAIL,
  PULSEMARKET_BANK,
  bankDetailsReady,
} from "../lib/payments";
import { useAuth } from "../lib/auth";
import { EmptyState, GhostButton, PrimaryButton } from "../components/ui";
import RatingForm from "../components/RatingForm";

const HELD_STEPS = ["reserved", "paid", "held", "shipped", "delivered", "released"];
// Meet-in-person held orders never ship: their status goes held ->
// delivered directly, so showing a "Shipped" step left the progress
// sitting on a step that could never happen.
const MEETUP_STEPS = ["reserved", "paid", "held", "delivered", "released"];
const STEP_LABELS = {
  reserved: "Reserved",
  paid: "Paid — transfer sent",
  held: "Held by PulseMarket",
  shipped: "Shipped",
  delivered: "Delivered",
  released: "Released to seller",
};
const CASH_STEPS = ["reserved", "delivered"];

function copyText(text, done) {
  if (navigator.clipboard?.writeText) {
    navigator.clipboard.writeText(text).then(done).catch(() => done(false));
  } else {
    done(false);
  }
}

export default function OrderDetail() {
  const { id } = useParams();
  const { user } = useAuth();
  const [order, setOrder] = useState(null);
  const [listing, setListing] = useState(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState("");
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const [copied, setCopied] = useState("");
  // Whether the buyer has a verified unboxing video for this order
  // (see the Confirm delivery button below).
  const [hasVerifiedUnboxing, setHasVerifiedUnboxing] = useState(false);

  const isBuyer = user && order && order.buyer_id === user.id;
  const isSeller = user && order && order.seller_id === user.id;
  const isOwner = user?.email === OWNER_EMAIL;
  // A shipping order cannot be confirmed delivered without the
  // buyer's verified unboxing video (lib rule in orders.js) —
  // meet-in-person orders are gated by the handoff instead.
  const unboxingMissing =
    order?.delivery_method === "shipping" &&
    ["held", "shipped"].includes(order.status) &&
    !hasVerifiedUnboxing;

  const load = useCallback(async () => {
    try {
      const row = await fetchOrder(id);
      setOrder(row);
      if (row) {
        const item = await fetchListing(row.listing_id);
        setListing(item);
        // The lib's confirmDelivery refuses a shipping order without
        // the BUYER's verified unboxing video (kind 'unboxing',
        // media_type 'video', verified=true) — a seller's own clip
        // does not count. Check it here so the button is disabled
        // with a hint instead of failing on tap.
        const rows = await fetchEvidenceForOrder(row.id);
        setHasVerifiedUnboxing(
          (rows || []).some(
            (r) =>
              r.kind === "unboxing" &&
              r.media_type === "video" &&
              r.verified === true &&
              r.user_id === row.buyer_id
          )
        );
      }
    } finally {
      setLoading(false);
    }
  }, [id]);

  useEffect(() => {
    load();
  }, [load]);

  async function run(action, fn) {
    setError("");
    setNotice("");
    setBusy(action);
    try {
      const updated = await fn();
      setOrder(updated);
      setNotice("Done.");
    } catch (err) {
      setError(err?.message || "Something went wrong. Please try again.");
    } finally {
      setBusy("");
    }
  }

  if (loading) {
    return <p className="py-10 text-center text-sm text-neutral-500">Loading order…</p>;
  }
  if (!order) {
    return (
      <EmptyState
        title="Order not found"
        body="It may have been removed, or the payments tables have not been switched on yet."
        action={
          <Link to="/dashboard">
            <GhostButton>Back to dashboard</GhostButton>
          </Link>
        }
      />
    );
  }
  // The database already refuses this row to non-participants
  // (RLS: buyer, seller or the team), but the page used to render
  // the order code, fee breakdown and bank details to anyone who
  // reached it, with only a small "not part of this order" line at
  // the bottom. Stop before any of it renders — same as Handoff
  // and Tracking.
  if (!isBuyer && !isSeller && !isOwner) {
    return (
      <EmptyState
        title="This order is not yours"
        body="Order details are only visible to the buyer, the seller and the PulseMarket team."
        action={
          <Link to="/dashboard">
            <GhostButton>Back to dashboard</GhostButton>
          </Link>
        }
      />
    );
  }

  const steps =
    order.payment_method === "cash"
      ? CASH_STEPS
      : order.delivery_method === "meetup"
        ? MEETUP_STEPS
        : HELD_STEPS;
  const stepIndex = steps.indexOf(order.status);
  const ended = ["cancelled", "refunded", "disputed"].includes(order.status);
  // Countdown to the 48h auto-release, for a delivered held order —
  // the page used to show the Release button with no word that the
  // money moves on its own 48 hours after delivery.
  const releaseCountdown =
    order.payment_method === "held" && order.status === "delivered"
      ? autoReleaseDue(order)
      : null;
  const copyEmail = () => copyText(OWNER_EMAIL, (ok) => setCopied(ok ? "Email copied." : "Copy failed — the email is " + OWNER_EMAIL));

  return (
    <div className="space-y-5">
      <Link to="/dashboard" className="text-sm font-semibold text-brown">
        ← Back to dashboard
      </Link>
      <div>
        <h1 className="text-2xl font-bold">Order</h1>
        <p className="mt-1 text-sm text-neutral-500">
          Use this code as your bank-transfer reference.
        </p>
        <p className="mt-2 inline-block rounded-xl bg-neutral-100 px-4 py-2 text-xl font-bold tracking-wider dark:bg-neutral-900">
          {order.code}
        </p>
      </div>

      <div className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
        <p className="font-semibold">{listing?.title || "Item"}</p>
        <p className="text-sm text-neutral-500">
          Seller: {listing?.seller_label || "Student"} · {listing?.state || ""}
        </p>
        <p className="text-sm text-neutral-500">
          {isBuyer ? "You are the buyer." : isSeller ? "You are the seller." : isOwner ? "You are the PulseMarket team." : ""}
        </p>
        <p className="mt-2 text-sm">
          Status: <span className="font-bold capitalize">{order.status}</span>
          {order.payment_method === "cash" ? " · Cash (face to face)" : " · Pay through the app (held)"}
        </p>
        <p className="text-sm text-neutral-500">
          {order.delivery_method === "meetup"
            ? `Meet in person — ${order.meetup_spot || "meetup spot to be agreed"}`
            : `Shipping to ${order.ship_to_state || "—"} via ${order.courier || "courier to be agreed"}`}
        </p>
      </div>

      <section className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
        <h2 className="text-lg font-bold">Money</h2>
        <dl className="mt-2 space-y-1 text-sm">
          <div className="flex justify-between">
            <dt>Item price (seller keeps this in full)</dt>
            <dd className="font-semibold">{formatNaira(order.item_price)}</dd>
          </div>
          <div className="flex justify-between">
            <dt>Service fee</dt>
            <dd className="font-semibold">{formatNaira(order.service_fee)}</dd>
          </div>
          <div className="flex justify-between">
            <dt>Secure payment fee</dt>
            <dd className="font-semibold">{formatNaira(order.secure_fee)}</dd>
          </div>
          <div className="flex justify-between">
            <dt>Shipping</dt>
            <dd className="font-semibold">{formatNaira(order.shipping_fee)}</dd>
          </div>
          <div className="flex justify-between border-t border-neutral-200 pt-2 text-base font-bold dark:border-neutral-800">
            <dt>Total</dt>
            <dd>{formatNaira(order.total)}</dd>
          </div>
        </dl>
      </section>

      {order.payment_method === "held" && order.status === "reserved" && (
        <section className="rounded-2xl border border-brown bg-brown-soft p-4">
          <h2 className="text-lg font-bold">How to pay</h2>
          <p className="mt-1 text-sm">
            Transfer exactly <strong>{formatNaira(order.total)}</strong> to the PulseMarket
            account, using <strong>{order.code}</strong> as the reference. Then tap
            “I have transferred” below. The PulseMarket team confirms the transfer
            arrived, and your money is HELD until you confirm delivery.
          </p>
          {bankDetailsReady() ? (
            <dl className="mt-3 space-y-1 text-sm">
              <div className="flex justify-between">
                <dt>Bank</dt>
                <dd className="font-semibold">{PULSEMARKET_BANK.bank}</dd>
              </div>
              <div className="flex justify-between">
                <dt>Account number</dt>
                <dd className="font-semibold">{PULSEMARKET_BANK.accountNumber}</dd>
              </div>
              <div className="flex justify-between">
                <dt>Account name</dt>
                <dd className="font-semibold">{PULSEMARKET_BANK.accountName}</dd>
              </div>
            </dl>
          ) : (
            <p className="mt-3 text-sm font-semibold">
              Transfer details will be shared by the PulseMarket team — email{" "}
              <span className="underline">{OWNER_EMAIL}</span> with your order code{" "}
              {order.code}.
            </p>
          )}
          <div className="mt-3">
            <GhostButton onClick={copyEmail}>Copy support email</GhostButton>
            {copied && <span className="ml-2 text-sm text-neutral-500">{copied}</span>}
          </div>
        </section>
      )}

      {order.payment_method === "held" && order.status === "paid" && (
        <p className="rounded-xl bg-neutral-100 px-3 py-2 text-sm text-neutral-600 dark:bg-neutral-900">
          You said you transferred. The PulseMarket team is checking the bank
          account — once they confirm it arrived, your money is held and the
          seller can ship or meet you.
        </p>
      )}

      <section>
        <h2 className="text-lg font-bold">Progress</h2>
        {ended ? (
          <p className="mt-2 rounded-xl bg-neutral-100 px-3 py-2 text-sm font-semibold capitalize dark:bg-neutral-900">
            This order is {order.status}.
          </p>
        ) : (
          <ol className="mt-2 space-y-2">
            {steps.map((step, i) => (
              <li key={step} className="flex items-center gap-2 text-sm">
                <span
                  className={`flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold ${
                    i < stepIndex
                      ? "bg-brown text-white"
                      : i === stepIndex
                        ? "border-2 border-brown text-brown"
                        : "border border-neutral-300 text-neutral-400 dark:border-neutral-700"
                  }`}
                >
                  {i + 1}
                </span>
                <span className={i <= stepIndex ? "font-semibold" : "text-neutral-500"}>
                  {STEP_LABELS[step]}
                </span>
              </li>
            ))}
          </ol>
        )}
        {order.payment_method === "cash" && (
          <p className="mt-2 text-xs text-neutral-500">
            Cash orders are settled face to face — no money is held by PulseMarket.
          </p>
        )}
      </section>

      {notice && <p className="rounded-xl bg-neutral-100 px-3 py-2 text-sm dark:bg-neutral-900">{notice}</p>}
      {error && <p className="rounded-xl bg-red-50 px-3 py-2 text-sm text-red-700">{error}</p>}

      {/* Milestone 12: a frozen order means a dispute is open — the
          money stays frozen while the PulseMarket team reviews it. */}
      {order.frozen && (isBuyer || isSeller || isOwner) && (
        <p className="rounded-xl bg-neutral-100 px-3 py-2 text-sm dark:bg-neutral-900">
          A dispute is open for this order — the money is frozen while the PulseMarket team reviews it.
        </p>
      )}

      {/* A return that is open pauses any release until the team
          resolves it — the money must stay put for the refund. */}
      {order.return_status === "opened" && (isBuyer || isSeller || isOwner) && (
        <p className="rounded-xl bg-neutral-100 px-3 py-2 text-sm dark:bg-neutral-900">
          A return is open for this order — release is paused until the PulseMarket team resolves it.
        </p>
      )}

      {/* Deal steps — handoff (meetup) and shipping/tracking live on their own pages */}
      {!ended && (isBuyer || isSeller) && (
        <section className="space-y-2">
          {order.delivery_method === "meetup" &&
            ["reserved", "paid", "held", "shipped"].includes(order.status) && (
              <Link to={`/handoff/${order.id}`} className="block">
                <GhostButton className="w-full py-3">
                  Handoff — scan the seller code + photo proof
                </GhostButton>
              </Link>
            )}
          {order.delivery_method === "shipping" &&
            ["held", "shipped", "delivered"].includes(order.status) && (
              <Link to={`/tracking/${order.id}`} className="block">
                <GhostButton className="w-full py-3">
                  Shipping &amp; tracking — waybill, checkpoints, delivery PIN
                </GhostButton>
              </Link>
            )}
          <Link to="/evidence" className="block">
            <GhostButton className="w-full py-3">
              Evidence locker — in-app photos &amp; videos for this order
            </GhostButton>
          </Link>
          {/* Only the buyer can report, and only while money is in
              play (paid / held / shipped / delivered). A seller
              tapping this used to land on a page that just refused
              them, and a released order's report would fail on
              submit — both dead ends. */}
          {isBuyer && ["paid", "held", "shipped", "delivered"].includes(order.status) && (
            <Link to={`/dispute/${order.id}`} className="block">
              <GhostButton className="w-full py-3">
                Report a problem with this order
              </GhostButton>
            </Link>
          )}
        </section>
      )}

      {/* Milestone 11: the buyer rates the seller once the deal is done
          and the money is released. Cash orders end at 'delivered'
          (Milestone 20, APP-7), so a cash buyer rates from there. */}
      {(order.status === "released" ||
        (order.status === "delivered" && order.payment_method === "cash")) &&
        isBuyer && (
        <section>
          <h2 className="text-lg font-bold">Rate the seller</h2>
          <div className="mt-2">
            <RatingForm order={order} />
          </div>
        </section>
      )}

      <section className="space-y-2">
        {/* Once money is held the order can no longer be cancelled
            from here — say so and point at the way out, instead of
            leaving the buyer hunting for a Cancel button that is gone. */}
        {isBuyer && order.payment_method === "held" && ["held", "shipped", "delivered"].includes(order.status) && (
          <p className="rounded-xl bg-neutral-100 px-3 py-2 text-sm text-neutral-600 dark:bg-neutral-900">
            This order can no longer be cancelled from here — the money is held. If something is wrong, report a problem above or email the PulseMarket team.
          </p>
        )}
        {isBuyer && order.delivery_method === "shipping" && ["held", "shipped"].includes(order.status) && (
          <p className="rounded-xl bg-neutral-100 px-3 py-2 text-sm text-neutral-600 dark:bg-neutral-900">
            For shipped orders, record your unboxing video (max 60 seconds) in the{" "}
            <Link to="/evidence" className="font-semibold text-brown underline">Evidence Locker</Link>{" "}
            first — delivery cannot be confirmed without a verified unboxing video.
          </p>
        )}
        {(isBuyer || isSeller) && order.delivery_method === "meetup" && ["reserved", "paid", "held", "shipped"].includes(order.status) && (
          <p className="rounded-xl bg-neutral-100 px-3 py-2 text-sm text-neutral-600 dark:bg-neutral-900">
            Meet in person first — scan the seller code and take handover photos on the Handoff page, then confirm delivery here.
          </p>
        )}
        {isBuyer && order.payment_method === "held" && order.status === "reserved" && (
          <PrimaryButton
            className="w-full py-3"
            disabled={busy !== ""}
            onClick={() => run("paid", () => markPaid(order.id, user.id))}
          >
            {busy === "paid" ? "Saving…" : "I have transferred"}
          </PrimaryButton>
        )}
        {isBuyer && ["held", "shipped"].includes(order.status) && (
          <>
            <PrimaryButton
              className="w-full py-3"
              disabled={busy !== "" || unboxingMissing}
              onClick={() => run("delivered", () => confirmDelivery(order.id, user.id))}
            >
              {busy === "delivered" ? "Saving…" : "Confirm delivery — I received the item"}
            </PrimaryButton>
            {unboxingMissing && (
              <p className="rounded-xl bg-neutral-100 px-3 py-2 text-sm text-neutral-600 dark:bg-neutral-900">
                Record your unboxing video in the{" "}
                <Link to="/evidence" className="font-semibold text-brown underline">Evidence Locker</Link>{" "}
                first — delivery cannot be confirmed without a verified unboxing video.
              </p>
            )}
          </>
        )}
        {isBuyer && order.payment_method === "cash" && order.status === "reserved" && (
          <PrimaryButton
            className="w-full py-3"
            disabled={busy !== ""}
            onClick={() => run("delivered", () => confirmDelivery(order.id, user.id))}
          >
            {busy === "delivered" ? "Saving…" : "Confirm meetup — I received the item"}
          </PrimaryButton>
        )}
        {isOwner && order.status === "paid" && (
          <PrimaryButton
            className="w-full py-3"
            disabled={busy !== ""}
            onClick={() => run("held", () => confirmReceipt(order.id, user))}
          >
            {busy === "held" ? "Saving…" : "Confirm receipt — money now held"}
          </PrimaryButton>
        )}
        {/* Milestone 17: release opens only after delivery is
            confirmed — a held order shows this note instead of the
            button, so nobody is left wondering where it went. The
            next step is the "Confirm delivery" button above. */}
        {(isOwner || isBuyer) && order.status === "held" && order.payment_method === "held" && !order.frozen && order.return_status !== "opened" && (
          <p className="rounded-xl bg-neutral-100 px-3 py-2 text-sm text-neutral-600 dark:bg-neutral-900">
            The money stays held until delivery is confirmed — once you confirm delivery, the release to the seller opens here.
          </p>
        )}
        {(isOwner || isBuyer) && order.status === "delivered" && order.payment_method === "held" && !order.frozen && order.return_status !== "opened" && (
          <>
            {releaseCountdown && releaseCountdown.hoursLeft !== null && (
              <p className="rounded-xl bg-neutral-100 px-3 py-2 text-sm text-neutral-600 dark:bg-neutral-900">
                {releaseCountdown.hoursLeft > 0
                  ? `If nobody releases it first, the money goes to the seller automatically in about ${releaseCountdown.hoursLeft} ${releaseCountdown.hoursLeft === 1 ? "hour" : "hours"} (48 hours after delivery).`
                  : "The 48 hours after delivery are up — the money will be released to the seller automatically the next time the app checks."}
              </p>
            )}
            <PrimaryButton
              className="w-full py-3"
              disabled={busy !== ""}
              onClick={() => run("released", () => releaseOrder(order.id, user))}
            >
              {busy === "released" ? "Saving…" : "Release to seller"}
            </PrimaryButton>
          </>
        )}
        {/* Cancel — Milestone 18 §8: the database already allows
            seller-cancel from 'reserved' and team-cancel from
            'reserved'/'paid', so the button is the missing piece.
            Pass the whole user object: cancelOrder() needs the
            email to recognise the team. The seller can only cancel
            while nothing has been paid — once the buyer has marked
            the order paid, only the team can cancel it. */}
        {((isBuyer || isOwner) && ["reserved", "paid"].includes(order.status)) ||
        (isSeller && order.status === "reserved") ? (
          <GhostButton
            className="w-full py-3"
            disabled={busy !== ""}
            onClick={() => run("cancelled", () => cancelOrder(order.id, user))}
          >
            {busy === "cancelled" ? "Cancelling…" : "Cancel order"}
          </GhostButton>
        ) : null}
      </section>

      <p className="text-xs text-neutral-400">
        Ordered {new Date(order.created_at).toLocaleString("en-NG")}. Support: {OWNER_EMAIL}
      </p>
    </div>
  );
}
