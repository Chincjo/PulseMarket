// Milestone 10 — Notifications page (route /notifications, added by
// the coordinator). Stored notifications (newest first, unread bold
// with a brown dot, tap to mark read + follow the link) plus a
// derived "Needs your attention" section computed at render from the
// user's own orders and listings — no stored rows needed for it:
//   - delivered orders: the 48h auto-release countdown ("Money
//     releases in Xh unless you confirm or dispute"), with reminder
//     copy that changes as the deadline approaches (12h / 24h / 47h
//     elapsed);
//   - open returns: shown only when the disputes notification toggle
//     is on (Settings -> Notifications). When it is off and returns
//     are open, the page says so plainly instead of hiding them
//     silently;
//   - listings whose boost ends within 24h: "Boost ending soon".
//     There is no settings toggle for boosts, so this always shows.
//   - the checkpoints and ratings toggles have no derived section on
//     this page (checkpoints arrive as stored rows; ratings arrive as
//     stored rows when ratings exist). The toggles still gate
//     CREATION of those rows — see src/lib/notifications.js.
// Support: pulsemarketsupport@gmail.com.
import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { useAuth } from "../lib/auth";
import { fetchMyOrders } from "../lib/orders";
import { fetchMyListings } from "../lib/listings";
import { getSettings } from "../lib/store";
import { formatNaira } from "../lib/fees";
import { OWNER_EMAIL } from "../lib/payments";
import { autoReleaseDue } from "../lib/autoRelease";
import {
  KIND_LABELS,
  fetchNotifications,
  markAllRead,
  markRead,
} from "../lib/notifications";
import { EmptyState, GhostButton, PrimaryButton } from "../components/ui";

const BOOST_WARNING_HOURS = 24;

function timeAgo(iso) {
  if (!iso) return "";
  const seconds = Math.max(
    0,
    Math.floor((Date.now() - new Date(iso).getTime()) / 1000)
  );
  if (seconds < 60) return "just now";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days}d ago`;
  return new Date(iso).toLocaleDateString("en-NG");
}

function hoursLabel(hours) {
  if (hours == null) return "";
  if (hours <= 0) return "less than an hour";
  if (hours === 1) return "1 hour";
  return `${hours} hours`;
}

// Reminder copy for a delivered order, by how much of the 48h has
// already passed. The buyer can still confirm the release or open a
// return before the deadline; the seller watches the money arrive.
function releaseReminder(order, hoursLeft) {
  if (!order.delivered_at) return "Delivery was confirmed — the 48-hour auto-release countdown starts from the delivery time.";
  const elapsedHours = Math.max(
    0,
    Math.floor((Date.now() - new Date(order.delivered_at).getTime()) / (60 * 60 * 1000))
  );
  if (elapsedHours >= 47) {
    return "Almost there — the money releases within the hour unless you confirm or open a return first.";
  }
  if (elapsedHours >= 24) {
    return `More than a day has passed since delivery. Less than a day left — ${hoursLabel(hoursLeft)} until the money releases automatically.`;
  }
  if (elapsedHours >= 12) {
    return `12 hours have passed since delivery. ${hoursLabel(hoursLeft)} left — confirm the release or open a return before the time runs out.`;
  }
  return `Delivered ${elapsedHours === 0 ? "just now" : `${elapsedHours}h ago`}. You have the full 48 hours to check the item — confirm the release or open a return before then.`;
}

export default function Notifications() {
  const { user } = useAuth();
  const navigate = useNavigate();
  const [items, setItems] = useState([]);
  const [orders, setOrders] = useState([]);
  const [listings, setListings] = useState([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const settings = getSettings();
  const disputesOn = settings?.notifications?.disputes !== false;

  const load = useCallback(async () => {
    if (!user) {
      setLoading(false);
      return;
    }
    const [notes, myOrders, myListings] = await Promise.all([
      fetchNotifications(user.id),
      fetchMyOrders(user.id),
      fetchMyListings(user.id),
    ]);
    setItems(notes || []);
    setOrders(myOrders || []);
    setListings(myListings || []);
    setLoading(false);
  }, [user]);

  useEffect(() => {
    load();
  }, [load]);

  async function openItem(item) {
    if (!user) return;
    if (!item.is_read) {
      await markRead(item.id, user.id);
      setItems((prev) =>
        prev.map((n) => (n.id === item.id ? { ...n, is_read: true } : n))
      );
    }
    if (item.link) navigate(item.link);
  }

  async function onMarkAllRead() {
    if (!user) return;
    setBusy(true);
    const ok = await markAllRead(user.id);
    setBusy(false);
    if (ok) setItems((prev) => prev.map((n) => ({ ...n, is_read: true })));
    else setError("Could not mark all as read. Try again.");
  }

  if (loading) {
    return <p className="py-10 text-center text-sm text-neutral-500">Loading notifications…</p>;
  }

  if (!user) {
    return (
      <EmptyState
        title="Sign in to see notifications"
        body="Your order updates, messages and release reminders live here once you sign in."
        action={
          <Link to="/signin">
            <PrimaryButton>Sign in</PrimaryButton>
          </Link>
        }
      />
    );
  }

  // ---- Derived "Needs your attention" (computed at render) ----
  // Cash orders never auto-release (settled face to face — no held
  // money), and an open return pauses the release, so neither belongs
  // in the countdown list: open returns get their own card below.
  const deliveredOrders = orders.filter(
    (o) =>
      o.status === "delivered" &&
      o.payment_method !== "cash" &&
      o.return_status !== "opened"
  );
  const openReturns = orders.filter((o) => o.return_status === "opened");
  const boostsEndingSoon = listings.filter((l) => {
    if (!l.boosted_until || l.status !== "active") return false;
    const msLeft = new Date(l.boosted_until).getTime() - Date.now();
    return msLeft > 0 && msLeft <= BOOST_WARNING_HOURS * 60 * 60 * 1000;
  });
  const attentionCount =
    deliveredOrders.length +
    (disputesOn ? openReturns.length : 0) +
    boostsEndingSoon.length;

  return (
    <div className="space-y-5">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold">Notifications</h1>
          <p className="mt-1 text-sm text-neutral-500">
            Order updates, messages, delivery stops and release reminders.
          </p>
        </div>
        {items.some((n) => !n.is_read) && (
          <GhostButton disabled={busy} onClick={onMarkAllRead}>
            {busy ? "Marking…" : "Mark all read"}
          </GhostButton>
        )}
      </div>

      {error && (
        <p className="rounded-xl bg-red-50 px-3 py-2 text-sm text-red-700">{error}</p>
      )}

      {/* ---- Needs your attention (derived, no stored rows) ---- */}
      {attentionCount > 0 && (
        <section className="space-y-3 rounded-2xl border border-brown bg-brown-soft p-4">
          <h2 className="text-lg font-bold">Needs your attention</h2>

          {deliveredOrders.map((order) => {
            const { hoursLeft } = autoReleaseDue(order);
            const isBuyer = order.buyer_id === user.id;
            return (
              <div
                key={order.id}
                className="rounded-xl border border-neutral-200 bg-white p-3 dark:border-neutral-700 dark:bg-black"
              >
                <p className="text-sm font-bold">
                  Order {order.code} —{" "}
                  {hoursLeft != null
                    ? `money releases in ${hoursLabel(hoursLeft)}`
                    : "money releases 48 hours after delivery"}
                </p>
                <p className="mt-1 text-sm text-neutral-600 dark:text-neutral-300">
                  {isBuyer
                    ? releaseReminder(order, hoursLeft)
                    : `The buyer confirmed delivery. ${formatNaira(order.item_price)} + shipping releases to your available balance in ${hoursLabel(hoursLeft)} unless the buyer opens a return first.`}
                </p>
                <p className="mt-2 text-sm">
                  <Link to={`/order/${order.id}`} className="font-semibold text-brown underline">
                    Open order {order.code}
                  </Link>
                </p>
              </div>
            );
          })}

          {disputesOn &&
            openReturns.map((order) => (
              <div
                key={`return-${order.id}`}
                className="rounded-xl border border-neutral-200 bg-white p-3 dark:border-neutral-700 dark:bg-black"
              >
                <p className="text-sm font-bold">Return open — order {order.code}</p>
                <p className="mt-1 text-sm text-neutral-600 dark:text-neutral-300">
                  {order.return_reason || "A return is open for this order."} The
                  PulseMarket team resolves it after looking at the evidence —
                  the 48-hour auto-release is paused until then.
                </p>
                <p className="mt-2 text-sm">
                  <Link to={`/order/${order.id}`} className="font-semibold text-brown underline">
                    Open order {order.code}
                  </Link>
                </p>
              </div>
            ))}

          {boostsEndingSoon.map((listing) => {
            const hoursLeft = Math.max(
              0,
              Math.ceil(
                (new Date(listing.boosted_until).getTime() - Date.now()) /
                  (60 * 60 * 1000)
              )
            );
            return (
              <div
                key={`boost-${listing.id}`}
                className="rounded-xl border border-neutral-200 bg-white p-3 dark:border-neutral-700 dark:bg-black"
              >
                <p className="text-sm font-bold">Boost ending soon — {listing.title}</p>
                <p className="mt-1 text-sm text-neutral-600 dark:text-neutral-300">
                  Your boost ends in {hoursLabel(hoursLeft)}. After that the
                  listing drops back to its normal place in search.
                </p>
                <p className="mt-2 text-sm">
                  <Link to={`/listing/${listing.id}`} className="font-semibold text-brown underline">
                    View listing
                  </Link>
                </p>
              </div>
            );
          })}
        </section>
      )}

      {!disputesOn && openReturns.length > 0 && (
        <p className="rounded-xl border border-neutral-200 px-3 py-2 text-sm text-neutral-500 dark:border-neutral-800">
          Return updates are turned off in Settings, so {openReturns.length} open
          return{openReturns.length === 1 ? " is" : "s are"} hidden here. Turn
          dispute notifications back on in Settings to see{" "}
          {openReturns.length === 1 ? "it" : "them"}.
        </p>
      )}

      {/* ---- Stored notifications ---- */}
      {items.length === 0 ? (
        <EmptyState
          title="No notifications yet"
          body="When something happens on your orders, chats or deliveries, it will show up here. Delivered orders and ending boosts show under “Needs your attention” above."
          action={
            <Link to="/dashboard">
              <GhostButton>Back to dashboard</GhostButton>
            </Link>
          }
        />
      ) : (
        <ul className="space-y-2">
          {items.map((item) => (
            <li key={item.id}>
              <button
                type="button"
                onClick={() => openItem(item)}
                className="flex w-full items-start gap-3 rounded-2xl border border-neutral-200 bg-white p-4 text-left dark:border-neutral-800 dark:bg-black"
              >
                <span
                  aria-hidden="true"
                  className={`mt-1.5 h-2.5 w-2.5 shrink-0 rounded-full ${
                    item.is_read ? "bg-neutral-300 dark:bg-neutral-700" : "bg-brown"
                  }`}
                />
                <span className="min-w-0 flex-1">
                  <span className="flex flex-wrap items-baseline gap-x-2">
                    <span
                      className={`text-sm ${item.is_read ? "font-semibold" : "font-bold"}`}
                    >
                      {item.title}
                    </span>
                    <span className="rounded-full bg-brown-soft px-2 py-0.5 text-xs font-semibold text-brown-dark">
                      {KIND_LABELS[item.kind] || item.kind}
                    </span>
                  </span>
                  {item.body && (
                    <span
                      className={`mt-1 block text-sm text-neutral-600 dark:text-neutral-300 ${
                        item.is_read ? "" : "font-semibold text-neutral-900 dark:text-white"
                      }`}
                    >
                      {item.body}
                    </span>
                  )}
                  <span className="mt-1 block text-xs text-neutral-400">
                    {timeAgo(item.created_at)}
                    {item.link ? " · Tap to open" : ""}
                  </span>
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}

      <p className="text-xs text-neutral-400">
        Notifications for {user.email}. Support: {OWNER_EMAIL}
      </p>
    </div>
  );
}
