// Inline edit form for a listing — used on the listing detail page and in
// the Dashboard. Only the listing owner ever sees it.
import { useState } from "react";
import { CONDITIONS } from "../lib/data";
import { GhostButton, PrimaryButton, inputCls } from "./ui";

export default function ListingEditForm({ listing, onSave, onCancel }) {
  const [title, setTitle] = useState(listing.title);
  const [price, setPrice] = useState(String(listing.price));
  const [condition, setCondition] = useState(listing.condition);
  const [description, setDescription] = useState(listing.description || "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function save() {
    setError("");
    if (!title.trim() || !price) {
      setError("Give the item a name and a price.");
      return;
    }
    setBusy(true);
    try {
      await onSave({
        title: title.trim(),
        price: Math.max(0, Math.round(Number(price) || 0)),
        condition,
        description: description.trim(),
      });
    } catch (err) {
      setError(err?.message || "Could not save the changes. Try again.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-3 rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
      <p className="font-bold">Edit listing</p>
      <label className="block text-sm font-semibold">
        Item name
        <input value={title} onChange={(e) => setTitle(e.target.value)} className={`${inputCls} mt-1`} />
      </label>
      <div className="grid grid-cols-2 gap-2">
        <label className="block text-sm font-semibold">
          Price (₦)
          <input value={price} onChange={(e) => setPrice(e.target.value)} type="number" className={`${inputCls} mt-1`} />
        </label>
        <label className="block text-sm font-semibold">
          Condition
          <select value={condition} onChange={(e) => setCondition(e.target.value)} className={`${inputCls} mt-1`}>
            {CONDITIONS.map((c) => (
              <option key={c}>{c}</option>
            ))}
          </select>
        </label>
      </div>
      <label className="block text-sm font-semibold">
        Description
        <textarea value={description} onChange={(e) => setDescription(e.target.value)} rows={4} className={`${inputCls} mt-1`} />
      </label>
      {error ? (
        <p className="rounded-xl bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-200">
          {error}
        </p>
      ) : null}
      <div className="flex gap-2">
        <PrimaryButton onClick={save} disabled={busy}>
          {busy ? "Saving…" : "Save changes"}
        </PrimaryButton>
        <GhostButton onClick={onCancel}>Cancel</GhostButton>
      </div>
    </div>
  );
}
