// Sell — publish a REAL listing to Supabase (Milestone 4).
// The listing's university and state come from the seller's verified
// university (locked), never from a free choice. Photos are uploaded to the
// listing-photos bucket first; the listing stores their public URLs.
// No sample or fake listings are ever created here — only what the student
// publishes themselves.
//
// EVERYTHING the form asks for is compulsory: the seller must pick a
// condition, a category, a delivery method (and courier + ships-to for
// shipping, or a safe meetup spot for meetups), add at least 1 photo and
// write a description of at least 20 characters. Only "What does it cost
// new?" is optional — it only feeds the suggested price. Each step refuses
// to advance until its own fields are filled, and Publish stays blocked
// until the whole form is valid. Milestone 13 adds the same rules as
// database CHECK constraints, so a listing cannot be slipped in by
// bypassing this form.
import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { CATEGORIES, CONDITIONS, SAFE_MEETUP_SPOTS, universityState } from "../lib/data";
import { feeBreakdown, formatNaira, suggestPrice } from "../lib/fees";
import { createListingRow, uploadListingPhotos } from "../lib/listings";
import { isSupabaseConfigured } from "../lib/supabase";
import { GhostButton, PrimaryButton, inputCls } from "../components/ui";
import { useAuth } from "../lib/auth";

const STEPS = ["Item", "Price", "Delivery", "Campus", "Photos", "Description", "Meet-up & safety"];

function downscale(file) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    const reader = new FileReader();
    reader.onerror = () => reject(new Error("Could not read that photo. Try a different one."));
    reader.onload = () => {
      // A non-image file never fires onload — without onerror the
      // promise never settles and adding a photo hangs for ever.
      img.onerror = () => reject(new Error("That file is not a photo — choose an image file."));
      img.onload = () => {
        const max = 600;
        const scale = Math.min(1, max / Math.max(img.width, img.height));
        const canvas = document.createElement("canvas");
        canvas.width = Math.round(img.width * scale);
        canvas.height = Math.round(img.height * scale);
        canvas.getContext("2d").drawImage(img, 0, 0, canvas.width, canvas.height);
        resolve(canvas.toDataURL("image/jpeg", 0.75));
      };
      img.src = reader.result;
    };
    reader.readAsDataURL(file);
  });
}

export default function Sell({ verification }) {
  const { user } = useAuth();
  const navigate = useNavigate();
  const [step, setStep] = useState(0);
  const [name, setName] = useState("");
  // No defaults on the choice fields: the seller must pick each one.
  const [condition, setCondition] = useState("");
  const [category, setCategory] = useState("");
  const [newPrice, setNewPrice] = useState("");
  const [price, setPrice] = useState("");
  const [delivery, setDelivery] = useState("");
  const [courier, setCourier] = useState("");
  const [shipsTo, setShipsTo] = useState("");
  const [photos, setPhotos] = useState([]);
  const [description, setDescription] = useState("");
  const [spot, setSpot] = useState("");
  const [published, setPublished] = useState(null);
  const [publishing, setPublishing] = useState(false);
  const [error, setError] = useState("");

  // The listing belongs to the seller's verified university — locked.
  const university = verification?.university || "";
  const state = universityState(university);

  const suggested = newPrice && condition ? suggestPrice(newPrice, condition) : null;
  const fees = feeBreakdown(price, "held");

  // -------------------------------------------------------------------------
  // Compulsory-field rules. missingFor(step) names exactly what is still
  // missing on one step; missingAll() covers the whole form for Publish.
  // -------------------------------------------------------------------------
  function missingFor(i) {
    switch (i) {
      case 0: {
        const missing = [];
        if (!name.trim()) missing.push("Item name");
        if (name.trim().length > 120) missing.push("Item name (under 120 characters)");
        if (!condition) missing.push("Condition");
        if (!category) missing.push("Category");
        return missing;
      }
      case 1: {
        const n = Math.round(Number(price) || 0);
        if (!price || n <= 0) return ["Your price (above ₦0)"];
        if (n > 10000000) return ["Your price (under ₦10,000,000)"];
        return [];
      }
      case 2: {
        const missing = [];
        if (!delivery) {
          missing.push("Delivery choice (Meet in person or Ship it)");
        } else if (delivery === "shipping") {
          if (!courier) missing.push("Courier");
          if (!shipsTo) missing.push("Who can buy this (same state or anywhere in Nigeria)");
        }
        return missing;
      }
      case 3:
        // Campus is locked from verification — nothing to fill in here.
        return [];
      case 4:
        return photos.length === 0 ? ["At least 1 photo"] : [];
      case 5:
        if (description.trim().length < 20)
          return ["Description (at least 20 characters)"];
        if (description.trim().length > 2000)
          return ["Description (under 2,000 characters)"];
        return [];
      case 6:
        return delivery === "meetup" && !spot ? ["Safe meetup spot"] : [];
      default:
        return [];
    }
  }

  function missingAll() {
    return [0, 1, 2, 3, 4, 5, 6].flatMap((i) => missingFor(i));
  }

  function missingMessage(missing) {
    return `Still needed: ${missing.join(", ")}.`;
  }

  // Advance one step only when this step is complete.
  function nextStep() {
    const missing = missingFor(step);
    if (missing.length > 0) {
      setError(missingMessage(missing));
      return;
    }
    setError("");
    setStep(step + 1);
  }

  // Step pills: free to go back, forward only through completed steps.
  function goToStep(i) {
    if (i <= step) {
      setError("");
      setStep(i);
      return;
    }
    for (let s = step; s < i; s++) {
      const missing = missingFor(s);
      if (missing.length > 0) {
        setError(missingMessage(missing));
        return;
      }
    }
    setError("");
    setStep(i);
  }

  async function onPhotos(e) {
    const files = [...e.target.files].slice(0, 4 - photos.length);
    const urls = [];
    for (const f of files) {
      try {
        urls.push(await downscale(f));
      } catch (err) {
        setError(err?.message || "Could not read that photo. Try a different one.");
      }
    }
    if (urls.length > 0) setPhotos([...photos, ...urls]);
    e.target.value = "";
  }

  async function publish() {
    setError("");
    // Defence in depth: never publish an incomplete listing, even if the
    // button state and this check ever disagree.
    const missing = missingAll();
    if (missing.length > 0) {
      setError(missingMessage(missing));
      return;
    }
    if (!isSupabaseConfigured() || !user) {
      setError("Publishing is not switched on yet — the owner is setting up the listings database. Try again soon.");
      return;
    }
    if (!university) {
      setError("Your university is not set. Please finish verification first.");
      return;
    }
    setPublishing(true);
    try {
      const photoUrls = photos.length
        ? await uploadListingPhotos(user.id, photos)
        : [];
      const sellerLabel = (user.email || "Student").split("@")[0];
      const row = await createListingRow({
        seller_id: user.id,
        seller_label: sellerLabel.charAt(0).toUpperCase() + sellerLabel.slice(1),
        title: name.trim(),
        description: description.trim(),
        price: Math.max(0, Math.round(Number(price) || 0)),
        condition,
        category,
        university,
        state,
        ships_to: delivery === "shipping" ? shipsTo : "same_state",
        delivery_methods: delivery === "shipping" ? ["shipping"] : ["meetup"],
        courier: delivery === "shipping" ? courier : null,
        meetup_spot: delivery === "meetup" ? spot : null,
        photos: photoUrls,
        status: "active",
      });
      setPublished(row);
    } catch (err) {
      const msg = err?.message || "";
      if (/relation .* does not exist|Could not find the table/i.test(msg)) {
        setError("Publishing is not switched on yet — the owner is setting up the listings database. Try again soon.");
      } else {
        setError(msg || "Could not publish your listing. Check your connection and try again.");
      }
    } finally {
      setPublishing(false);
    }
  }

  if (published) {
    return (
      <div className="space-y-4 pt-6 text-center">
        <p className="text-2xl font-bold">Your listing is live</p>
        <p className="text-neutral-500">
          Students in {state} can see it now
          {published.ships_to === "nationwide" ? " — and students anywhere in Nigeria too, because you ship nationwide" : ""}.
          You keep the full price; the buyer pays any fees.
        </p>
        <div className="flex flex-wrap justify-center gap-2">
          <PrimaryButton onClick={() => navigate(`/listing/${published.id}`)}>View your listing</PrimaryButton>
          <GhostButton onClick={() => navigate("/dashboard")}>My listings</GhostButton>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-5 pb-24">
      <h1 className="text-2xl font-bold">Sell an item</h1>
      <div className="flex flex-wrap gap-1.5">
        {STEPS.map((s, i) => (
          <button
            key={s}
            onClick={() => goToStep(i)}
            className={`rounded-full px-2.5 py-1 text-xs font-semibold ${i === step ? "bg-brown text-white" : "bg-neutral-100 dark:bg-neutral-900"}`}
          >
            {i + 1}. {s}
          </button>
        ))}
      </div>

      {step === 0 && (
        <div className="space-y-3">
          <label className="block text-sm font-semibold">Item name
            <input value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Scientific calculator" className={`${inputCls} mt-1`} />
          </label>
          <label className="block text-sm font-semibold">Condition
            <select value={condition} onChange={(e) => setCondition(e.target.value)} className={`${inputCls} mt-1`}>
              <option value="">Choose a condition…</option>
              {CONDITIONS.map((c) => <option key={c} value={c}>{c}</option>)}
            </select>
          </label>
          <label className="block text-sm font-semibold">Category
            <select value={category} onChange={(e) => setCategory(e.target.value)} className={`${inputCls} mt-1`}>
              <option value="">Choose a category…</option>
              {CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
            </select>
          </label>
        </div>
      )}

      {step === 1 && (
        <div className="space-y-3">
          <label className="block text-sm font-semibold">What does it cost new? (optional)
            <input value={newPrice} onChange={(e) => setNewPrice(e.target.value)} type="number" placeholder="e.g. 12000" className={`${inputCls} mt-1`} />
          </label>
          {suggested !== null && (
            <p className="rounded-xl bg-brown-soft px-3 py-2 text-sm text-brown-dark">
              Suggested price for {condition}: <b>{formatNaira(suggested)}</b> — you can change it below.
            </p>
          )}
          <label className="block text-sm font-semibold">Your price (₦)
            <input value={price} onChange={(e) => setPrice(e.target.value)} type="number" placeholder="e.g. 8500" className={`${inputCls} mt-1`} />
          </label>
          {price ? (
            <div className="rounded-2xl border border-neutral-200 p-4 text-sm dark:border-neutral-800">
              <p className="font-bold">What the buyer pays</p>
              <p className="mt-1 flex justify-between"><span>Item price</span><span>{formatNaira(fees.price)}</span></p>
              <p className="flex justify-between text-neutral-500"><span>Service fee {fees.price < 5000 ? "(flat ₦150 under ₦5,000)" : "(5%, capped at ₦2,000)"}</span><span>{formatNaira(fees.serviceFee)}</span></p>
              <p className="flex justify-between text-neutral-500"><span>Secure payment fee</span><span>{formatNaira(fees.secureFee)}</span></p>
              <p className="mt-1 flex justify-between font-bold"><span>Buyer pays (held)</span><span>{formatNaira(fees.total)}</span></p>
              <p className="mt-1 text-neutral-500">Cash face-to-face: no fees — buyer pays {formatNaira(fees.price)}. You keep the full price either way.</p>
            </div>
          ) : null}
        </div>
      )}

      {step === 2 && (
        <div className="space-y-3">
          <p className="text-sm font-semibold">How will the buyer get it?</p>
          <div className="flex gap-2">
            <button onClick={() => setDelivery("meetup")} className={`flex-1 rounded-xl border px-3 py-3 text-sm font-semibold ${delivery === "meetup" ? "border-brown bg-brown-soft" : "border-neutral-300 dark:border-neutral-700"}`}>Meet in person</button>
            <button onClick={() => setDelivery("shipping")} className={`flex-1 rounded-xl border px-3 py-3 text-sm font-semibold ${delivery === "shipping" ? "border-brown bg-brown-soft" : "border-neutral-300 dark:border-neutral-700"}`}>Ship it</button>
          </div>
          {delivery === "shipping" && (
            <>
              <label className="block text-sm font-semibold">Courier
                <select value={courier} onChange={(e) => setCourier(e.target.value)} className={`${inputCls} mt-1`}>
                  <option value="">Choose a courier…</option>
                  {/* Canonical courier names — the shipping advance,
                      courier tiers and the database all match on these
                      exact strings. The old short names ("GIG", "GUO",
                      "DHL", "Bus Park") matched nothing, so a listing
                      shipped with GIG could never earn its 50%
                      shipping advance. */}
                  {["GIG Logistics", "GUO Transport", "Peace Logistics", "ABC Transport", "DHL Domestic", "Chowdeck Relay", "Bus Park Waybill"].map((c) => <option key={c} value={c}>{c}</option>)}
                </select>
              </label>
              <div>
                <p className="text-sm font-semibold">Who can buy this?</p>
                <div className="mt-1 flex gap-2">
                  <button onClick={() => setShipsTo("same_state")} className={`flex-1 rounded-xl border px-3 py-3 text-sm font-semibold ${shipsTo === "same_state" ? "border-brown bg-brown-soft" : "border-neutral-300 dark:border-neutral-700"}`}>Same state only ({state || "your state"})</button>
                  <button onClick={() => setShipsTo("nationwide")} className={`flex-1 rounded-xl border px-3 py-3 text-sm font-semibold ${shipsTo === "nationwide" ? "border-brown bg-brown-soft" : "border-neutral-300 dark:border-neutral-700"}`}>Anywhere in Nigeria</button>
                </div>
                <p className="mt-1 text-sm text-neutral-500">
                  {shipsTo === "same_state"
                    ? "Only students in your state will see this listing."
                    : shipsTo === "nationwide"
                      ? "Students in every state will see this listing, because you ship anywhere."
                      : "Pick one so buyers know where this item can go."}
                </p>
              </div>
            </>
          )}
          <p className="text-sm text-neutral-500">
            {delivery === "meetup"
              ? "Face-to-face: the buyer scans your seller code at handoff before any money moves."
              : delivery === "shipping"
                ? "Shipping: GIG / GUO between states, Chowdeck Relay same-city. You get 50% after shipping proof, 50% after delivery."
                : "Choose one to continue."}
          </p>
        </div>
      )}

      {step === 3 && (
        <div className="rounded-2xl border border-neutral-200 p-4 text-sm dark:border-neutral-800">
          <p className="font-bold">Your university (locked)</p>
          <p className="mt-1">{university || "Not set — finish verification first."}</p>
          {state ? <p className="mt-1 text-neutral-500">Your listings show first to students in {state}.</p> : null}
          <p className="mt-1 text-neutral-500">Your university is locked from your verification — it cannot be changed here.</p>
        </div>
      )}

      {step === 4 && (
        <div className="space-y-3">
          <label className="block rounded-2xl border border-dashed border-neutral-300 p-6 text-center text-sm dark:border-neutral-700">
            Add at least 1 photo (up to 4)
            <input type="file" accept="image/*" multiple onChange={onPhotos} className="mt-2 block w-full text-sm" />
          </label>
          <div className="grid grid-cols-2 gap-2">
            {photos.map((p, i) => (
              <img key={i} src={p} alt={`Photo ${i + 1}`} className="h-32 w-full rounded-xl object-cover" />
            ))}
          </div>
          <p className="text-sm text-neutral-500">
            {photos.length === 0
              ? "Buyers need to see the item — add at least 1 photo to continue."
              : "Clear photos sell faster. Photos are uploaded with your listing."}
          </p>
        </div>
      )}

      {step === 5 && (
        <div className="space-y-3">
          <label className="block text-sm font-semibold">Description
            <textarea value={description} onChange={(e) => setDescription(e.target.value)} rows={5} placeholder="Condition, what's included, any faults — be honest, it builds trust." className={`${inputCls} mt-1`} />
          </label>
          <p className="text-sm text-neutral-500">
            {description.trim().length} / 20 characters minimum
            {description.trim().length < 20 ? " — say a little more about the item." : ""}
          </p>
        </div>
      )}

      {step === 6 && (
        <div className="space-y-3">
          {delivery === "meetup" ? (
            <label className="block text-sm font-semibold">Safe meetup spot
              <select value={spot} onChange={(e) => setSpot(e.target.value)} className={`${inputCls} mt-1`}>
                <option value="">Choose a safe meetup spot…</option>
                {SAFE_MEETUP_SPOTS.map((s) => <option key={s} value={s}>{s}</option>)}
              </select>
            </label>
          ) : (
            <div className="rounded-2xl border border-neutral-200 p-4 text-sm dark:border-neutral-800">
              <p className="font-bold">Shipping chosen</p>
              <p className="mt-1 text-neutral-500">The buyer pays the courier at delivery or as agreed in chat. You get 50% after shipping proof, 50% after delivery.</p>
            </div>
          )}
          <div className="rounded-2xl border border-neutral-200 p-4 text-sm dark:border-neutral-800">
            <p className="font-bold">Stay safe</p>
            <ul className="mt-1 list-disc space-y-1 pl-5 text-neutral-500">
              <li>Meet in the daytime, in a busy public place on campus.</li>
              <li>Never pay before you inspect the item.</li>
              <li>The buyer must scan your seller code at handoff.</li>
            </ul>
          </div>
          {missingAll().length > 0 && (
            <p className="rounded-xl bg-amber-50 p-3 text-sm text-amber-800 dark:bg-amber-950 dark:text-amber-200">
              {missingMessage(missingAll())}
            </p>
          )}
        </div>
      )}

      {error ? (
        <p className="rounded-xl bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-200">
          {error}
        </p>
      ) : null}

      {/* Action bar sits ABOVE the bottom nav (bottom-16) at every width.
          The nav is fixed bottom-0 z-20 on desktop too, so dropping this bar
          to bottom-0 on desktop (sm:bottom-0) put it underneath the nav and
          the Publish button could not be seen or clicked. */}
      <div className="fixed inset-x-0 bottom-16 z-30 border-t border-neutral-200 bg-white/95 px-4 py-3 backdrop-blur dark:border-neutral-800 dark:bg-black/95">
        <div className="mx-auto flex max-w-2xl gap-2">
          {step > 0 && <GhostButton onClick={() => { setError(""); setStep(step - 1); }}>Back</GhostButton>}
          {step < STEPS.length - 1 ? (
            <PrimaryButton className="flex-1" onClick={nextStep}>Continue</PrimaryButton>
          ) : (
            <button onClick={publish} disabled={missingAll().length > 0 || publishing} className="flex-1 rounded-full bg-brown px-5 py-2.5 text-sm font-semibold text-white disabled:opacity-50">
              {publishing ? "Publishing…" : "Publish listing"}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
