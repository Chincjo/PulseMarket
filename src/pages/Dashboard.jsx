// Dashboard — the seller's own real listings (Milestone 4) with
// edit / duplicate / mark sold / mark reserved / delete.
import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { formatNaira } from "../lib/fees";
import { EmptyState, GhostButton, PrimaryButton } from "../components/ui";
import { BoostedBadge } from "../components/ListingCard";
import ListingEditForm from "../components/ListingEditForm";
import { fetchMyOrders } from "../lib/orders";
import {
  deleteListing,
  duplicateListing,
  fetchMyListings,
  isBoosted,
  reactivateListing,
  updateListing,
} from "../lib/listings";
import { useAuth } from "../lib/auth";

export default function Dashboard() {
  const { user } = useAuth();
  const [listings, setListings] = useState([]);
  const [loading, setLoading] = useState(true);
  const [hasMoreListings, setHasMoreListings] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  // My orders (buyer + seller): a buyer who closed the app after
  // checkout used to have no way back to the order from here — the
  // Dashboard was listings-only, and the Evidence Locker's "My
  // orders" button pointed at this page.
  const [orders, setOrders] = useState([]);
  const [hasMoreOrders, setHasMoreOrders] = useState(false);
  const [loadingMoreOrders, setLoadingMoreOrders] = useState(false);
  const [editingId, setEditingId] = useState(null);
  const [error, setError] = useState("");
  const [busyId, setBusyId] = useState(null);
  // reload() is called from handlers as well as the effect, so it
  // guards against setting state after unmount itself.
  const mounted = useRef(true);

  async function reload() {
    // A signed-out visitor used to stare at "Loading your orders…"
    // for ever: the early return left `loading` true, and the effect
    // never re-ran once auth had settled on no user.
    if (!user) {
      if (mounted.current) setLoading(false);
      return;
    }
    try {
      const [rows, myOrders] = await Promise.all([
        fetchMyListings(user.id),
        fetchMyOrders(user.id),
      ]);
      if (mounted.current) {
        setListings(rows);
        setHasMoreListings(rows.hasMore === true);
        setOrders(myOrders || []);
        setHasMoreOrders(myOrders?.hasMore === true);
      }
    } catch (err) {
      if (mounted.current) setError(err?.message || "Could not load your listings. Try again.");
    } finally {
      if (mounted.current) setLoading(false);
    }
  }

  async function loadMoreOrders() {
    if (!user || loadingMoreOrders || !hasMoreOrders || orders.length === 0) return;
    setLoadingMoreOrders(true);
    setError("");
    try {
      const last = orders[orders.length - 1];
      const rows = await fetchMyOrders(user.id, { before: last.created_at });
      if (mounted.current) {
        setOrders((prev) => [...prev, ...(rows || [])]);
        setHasMoreOrders(rows?.hasMore === true);
      }
    } catch (err) {
      if (mounted.current) setError(err?.message || "Could not load more orders. Try again.");
    } finally {
      if (mounted.current) setLoadingMoreOrders(false);
    }
  }

  // "Load more" for sellers with more than 200 listings: the list
  // fetch pages by created_at, newest first.
  async function loadMoreListings() {
    if (!user || loadingMore || !hasMoreListings || listings.length === 0) return;
    setLoadingMore(true);
    setError("");
    try {
      const last = listings[listings.length - 1];
      const rows = await fetchMyListings(user.id, { before: last.created_at });
      if (mounted.current) {
        setListings((prev) => [...prev, ...rows]);
        setHasMoreListings(rows.hasMore === true);
      }
    } catch (err) {
      if (mounted.current) setError(err?.message || "Could not load more listings. Try again.");
    } finally {
      if (mounted.current) setLoadingMore(false);
    }
  }

  useEffect(() => {
    mounted.current = true;
    reload();
    return () => {
      mounted.current = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [user]);

  const active = listings.filter((l) => l.status === "active");
  const totalValue = active.reduce((s, d) => s + (d.price || 0), 0);

  async function setStatus(listing, status) {
    // No busy guard before: a double-tap fired two status updates and
    // two reloads for one tap.
    if (busyId) return;
    setBusyId(listing.id);
    setError("");
    try {
      await updateListing(listing.id, { status });
      reload();
    } catch (err) {
      setError(err?.message || "Could not update the listing. Try again.");
    } finally {
      setBusyId(null);
    }
  }

  async function reactivate(listing) {
    // "Back to active" on a reserved listing with an open order
    // used to flip it live mid-order (see reactivateListing).
    if (busyId) return;
    setBusyId(listing.id);
    setError("");
    try {
      await reactivateListing(listing.id);
      reload();
    } catch (err) {
      setError(err?.message || "Could not update the listing. Try again.");
    } finally {
      setBusyId(null);
    }
  }

  async function remove(listing) {
    // Busy check first: asking "are you sure?" and then doing
    // nothing (because another action was already running) is a
    // confusing dead end.
    if (busyId) return;
    // Deleting is permanent — ask first. (The listing detail page
    // already asks with a two-tap confirm; this page had none.)
    if (!window.confirm(`Delete "${listing.title}"? This cannot be undone.`)) return;
    // No busy guard before: a double-click deleted twice, and the
    // second call's "not found" error replaced the success.
    setBusyId(listing.id);
    setError("");
    try {
      await deleteListing(listing.id);
      reload();
    } catch (err) {
      setError(err?.message || "Could not delete the listing. Try again.");
    } finally {
      setBusyId(null);
    }
  }

  async function duplicate(listing) {
    if (busyId) return;
    setError("");
    setBusyId(listing.id);
    try {
      await duplicateListing(listing);
      reload();
    } catch (err) {
      setError(err?.message || "Could not duplicate the listing. Try again.");
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="space-y-5">
      <h1 className="text-2xl font-bold">Dashboard</h1>
      <div className="grid grid-cols-3 gap-2 text-center">
        <div className="rounded-2xl border border-neutral-200 p-3 dark:border-neutral-800">
          <p className="text-xl font-bold">{listings.length}</p>
          <p className="text-xs text-neutral-500">Listings</p>
        </div>
        <div className="rounded-2xl border border-neutral-200 p-3 dark:border-neutral-800">
          <p className="text-xl font-bold">{listings.filter((l) => l.status === "sold").length}</p>
          <p className="text-xs text-neutral-500">Sold</p>
        </div>
        <div className="rounded-2xl border border-neutral-200 p-3 dark:border-neutral-800">
          <p className="text-xl font-bold">{formatNaira(totalValue)}</p>
          <p className="text-xs text-neutral-500">Active value</p>
        </div>
      </div>

      <h2 className="text-lg font-bold">My orders</h2>
      {loading ? (
        <p className="text-sm text-neutral-500">Loading your orders…</p>
      ) : orders.length === 0 ? (
        <p className="text-sm text-neutral-500">
          No orders yet — items you buy or sell will show up here, so you can always find them again after checkout.
        </p>
      ) : (
        <div className="space-y-2">
          {orders.map((o) => (
            <Link
              key={o.id}
              to={`/order/${o.id}`}
              className="flex items-center gap-3 rounded-2xl border border-neutral-200 p-3 dark:border-neutral-800"
            >
              <div className="flex-1">
                <p className="text-sm font-semibold">
                  Order {o.code} · {o.buyer_id === user?.id ? "You bought" : "You sold"}
                </p>
                <p className="text-sm text-neutral-500">
                  {formatNaira(o.total)} · <span className="capitalize">{o.status}</span>
                  {o.payment_method === "cash" ? " · Cash" : " · Held"}
                </p>
              </div>
              <span className="text-sm font-semibold text-brown">Open →</span>
            </Link>
          ))}
          {hasMoreOrders ? (
            <div className="pt-1 text-center">
              <p className="text-xs text-neutral-500">Showing the first {orders.length} orders.</p>
              <GhostButton onClick={loadMoreOrders} disabled={loadingMoreOrders}>
                {loadingMoreOrders ? "Loading…" : "Load more"}
              </GhostButton>
            </div>
          ) : null}
        </div>
      )}

      <h2 className="text-lg font-bold">My listings</h2>
      {error ? (
        <p className="rounded-xl bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-200">
          {error}
        </p>
      ) : null}
      {loading ? (
        <p className="text-sm text-neutral-500">Loading your listings…</p>
      ) : listings.length === 0 ? (
        <EmptyState
          title="You have no listings yet"
          body="Post your first item — it takes less than a minute."
          action={
            <Link to="/sell">
              <PrimaryButton>Sell an item</PrimaryButton>
            </Link>
          }
        />
      ) : (
        <div className="space-y-3">
          {listings.map((d) => (
            <div key={d.id}>
              <div className="flex items-center gap-3 rounded-2xl border border-neutral-200 p-3 dark:border-neutral-800">
                <Link to={`/listing/${d.id}`} className="shrink-0">
                  {d.photos?.[0] ? (
                    <img src={d.photos[0]} alt={d.title} className="h-14 w-14 rounded-xl object-cover" />
                  ) : (
                    <div className="flex h-14 w-14 items-center justify-center rounded-xl bg-neutral-100 text-xs text-neutral-400 dark:bg-neutral-900">No photo</div>
                  )}
                </Link>
                <div className="flex-1">
                  <Link to={`/listing/${d.id}`} className="text-sm font-semibold underline-offset-2 hover:underline">
                    {d.title}
                  </Link>
                  <p className="text-sm text-neutral-500">{formatNaira(d.price)} · {d.condition} · {d.state}</p>
                  <div className="mt-1 flex flex-wrap items-center gap-2">
                    <span className="text-xs font-semibold text-neutral-500">
                      {d.status === "active" ? "Live" : d.status === "reserved" ? "Reserved" : "Sold"}
                    </span>
                    {isBoosted(d) ? <BoostedBadge /> : null}
                  </div>
                </div>
              </div>
              <div className="mt-2 flex flex-wrap gap-2 pl-1">
                <GhostButton onClick={() => setEditingId(editingId === d.id ? null : d.id)}>
                  {editingId === d.id ? "Close edit" : "Edit"}
                </GhostButton>
                <GhostButton onClick={() => duplicate(d)} disabled={busyId === d.id}>
                  {busyId === d.id ? "Duplicating…" : "Duplicate"}
                </GhostButton>
                {d.status === "active" ? (
                  <>
                    <GhostButton disabled={busyId === d.id} onClick={() => setStatus(d, "reserved")}>Mark reserved</GhostButton>
                    <GhostButton disabled={busyId === d.id} onClick={() => setStatus(d, "sold")}>Mark sold</GhostButton>
                  </>
                ) : (
                  <GhostButton disabled={busyId === d.id} onClick={() => reactivate(d)}>Back to active</GhostButton>
                )}
                <GhostButton disabled={busyId === d.id} onClick={() => remove(d)}>Delete</GhostButton>
              </div>
              {editingId === d.id ? (
                <div className="mt-2">
                  <ListingEditForm
                    listing={d}
                    onCancel={() => setEditingId(null)}
                    onSave={async (patch) => {
                      await updateListing(d.id, patch);
                      setEditingId(null);
                      reload();
                    }}
                  />
                </div>
              ) : null}
            </div>
          ))}
          {hasMoreListings ? (
            <div className="pt-1 text-center">
              <p className="text-xs text-neutral-500">Showing the first {listings.length} listings.</p>
              <GhostButton onClick={loadMoreListings} disabled={loadingMore}>
                {loadingMore ? "Loading…" : "Load more"}
              </GhostButton>
            </div>
          ) : null}
        </div>
      )}
    </div>
  );
}
