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
    const cleanTitle = title.trim();
    if (!cleanTitle) {
      setError("Give the item a name.");
      return;
    }
    if (cleanTitle.length > 120) {
      setError("Keep the item name under 120 characters.");
      return;
    }
    // Price must be a whole number above ₦0 (the database refuses ₦0
    // too) and below ₦10,000,000 — before this fix a negative price
    // silently became ₦0 and ₦999,999,999 sailed through.
    const n = Math.round(Number(price));
    if (!price || price.toString().trim() === "" || !Number.isFinite(n) || n < 1) {
      setError("Enter a price above ₦0.");
      return;
    }
    if (n > 10000000) {
      setError("Price is too high — keep it under ₦10,000,000.");
      return;
    }
    if (!CONDITIONS.includes(condition)) {
      setError("Choose a condition from the list.");
      return;
    }
    const cleanDescription = description.trim();
    if (cleanDescription.length < 20) {
      setError("Describe the item in at least 20 characters.");
      return;
    }
    if (cleanDescription.length > 2000) {
      setError("Keep the description under 2,000 characters.");
      return;
    }
    setBusy(true);
    try {
      await onSave({
        title: cleanTitle,
        price: n,
        condition,
        description: cleanDescription,
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
        <input value={title} onChange={(e) => setTitle(e.target.value)} maxLength={120} className={`${inputCls} mt-1`} />
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
        <textarea value={description} onChange={(e) => setDescription(e.target.value)} rows={4} maxLength={2000} className={`${inputCls} mt-1`} />
        <span className="mt-1 block text-right text-xs font-normal text-neutral-400">
          {description.trim().length} / 20 characters minimum
        </span>
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
