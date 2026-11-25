// Dashboard — the seller's own real listings (Milestone 4) with
// edit / duplicate / mark sold / mark reserved / delete.
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { formatNaira } from "../lib/fees";
import { EmptyState, GhostButton, PrimaryButton } from "../components/ui";
import { BoostedBadge } from "../components/ListingCard";
import ListingEditForm from "../components/ListingEditForm";
import {
  deleteListing,
  duplicateListing,
  fetchMyListings,
  isBoosted,
  updateListing,
} from "../lib/listings";
import { useAuth } from "../lib/auth";

export default function Dashboard() {
  const { user } = useAuth();
  const [listings, setListings] = useState([]);
  const [loading, setLoading] = useState(true);
  const [editingId, setEditingId] = useState(null);
  const [error, setError] = useState("");
  const [busyId, setBusyId] = useState(null);

  async function reload() {
    if (!user) return;
    try {
      const rows = await fetchMyListings(user.id);
      setListings(rows);
    } catch (err) {
      setError(err?.message || "Could not load your listings. Try again.");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    reload();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [user]);

  const active = listings.filter((l) => l.status === "active");
  const totalValue = active.reduce((s, d) => s + (d.price || 0), 0);

  async function setStatus(listing, status) {
    setError("");
    try {
      await updateListing(listing.id, { status });
      reload();
    } catch (err) {
      setError(err?.message || "Could not update the listing. Try again.");
    }
  }

  async function remove(listing) {
    // Deleting is permanent — ask first. (The listing detail page
    // already asks with a two-tap confirm; this page had none.)
    if (!window.confirm(`Delete "${listing.title}"? This cannot be undone.`)) return;
    setError("");
    try {
      await deleteListing(listing.id);
      reload();
    } catch (err) {
      setError(err?.message || "Could not delete the listing. Try again.");
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
                    <GhostButton onClick={() => setStatus(d, "reserved")}>Mark reserved</GhostButton>
                    <GhostButton onClick={() => setStatus(d, "sold")}>Mark sold</GhostButton>
                  </>
                ) : (
                  <GhostButton onClick={() => setStatus(d, "active")}>Back to active</GhostButton>
                )}
                <GhostButton onClick={() => remove(d)}>Delete</GhostButton>
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
        </div>
      )}
    </div>
  );
}
