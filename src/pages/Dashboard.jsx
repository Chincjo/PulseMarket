import { Link } from "react-router-dom";
import { getDrafts, deleteDraft } from "../lib/store";
import { formatNaira } from "../lib/fees";
import { EmptyState, PrimaryButton } from "../components/ui";
import { useState } from "react";

export default function Dashboard() {
  const [drafts, setDrafts] = useState(getDrafts());
  const totalValue = drafts.reduce((s, d) => s + (d.price || 0), 0);

  return (
    <div className="space-y-5">
      <h1 className="text-2xl font-bold">Dashboard</h1>
      <div className="grid grid-cols-3 gap-2 text-center">
        <div className="rounded-2xl border border-neutral-200 p-3 dark:border-neutral-800">
          <p className="text-xl font-bold">{drafts.length}</p>
          <p className="text-xs text-neutral-500">Listings</p>
        </div>
        <div className="rounded-2xl border border-neutral-200 p-3 dark:border-neutral-800">
          <p className="text-xl font-bold">0</p>
          <p className="text-xs text-neutral-500">Sales</p>
        </div>
        <div className="rounded-2xl border border-neutral-200 p-3 dark:border-neutral-800">
          <p className="text-xl font-bold">{formatNaira(totalValue)}</p>
          <p className="text-xs text-neutral-500">Draft value</p>
        </div>
      </div>

      <h2 className="text-lg font-bold">My listings</h2>
      {drafts.length === 0 ? (
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
        <div className="space-y-2">
          {drafts.map((d) => (
            <div key={d.id} className="flex items-center gap-3 rounded-2xl border border-neutral-200 p-3 dark:border-neutral-800">
              {d.photos?.[0] ? (
                <img src={d.photos[0]} alt={d.name} className="h-14 w-14 rounded-xl object-cover" />
              ) : (
                <div className="flex h-14 w-14 items-center justify-center rounded-xl bg-neutral-100 text-xs text-neutral-400 dark:bg-neutral-900">No photo</div>
              )}
              <div className="flex-1">
                <p className="text-sm font-semibold">{d.name}</p>
                <p className="text-sm text-neutral-500">{formatNaira(d.price)} · {d.condition}</p>
                <span className="text-xs font-semibold text-brown">Draft — not published yet</span>
              </div>
              <button
                onClick={() => { deleteDraft(d.id); setDrafts(getDrafts()); }}
                className="rounded-full border border-neutral-300 px-3 py-1.5 text-xs font-semibold dark:border-neutral-700"
              >
                Delete
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
