// Sell — publish a REAL listing to Supabase (Milestone 4).
// The listing's university and state come from the seller's verified
// university (locked), never from a free choice. Photos are uploaded to the
// listing-photos bucket first; the listing stores their public URLs.
// No sample or fake listings are ever created here — only what the student
// publishes themselves.
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
  return new Promise((resolve) => {
    const img = new Image();
    const reader = new FileReader();
    reader.onload = () => {
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
  const [condition, setCondition] = useState("Good");
  const [category, setCategory] = useState(CATEGORIES[0]);
  const [newPrice, setNewPrice] = useState("");
  const [price, setPrice] = useState("");
  const [delivery, setDelivery] = useState("meetup");
  const [courier, setCourier] = useState("GIG");
  const [shipsTo, setShipsTo] = useState("same_state");
  const [photos, setPhotos] = useState([]);
  const [description, setDescription] = useState("");
  const [spot, setSpot] = useState(SAFE_MEETUP_SPOTS[0]);
  const [published, setPublished] = useState(null);
  const [publishing, setPublishing] = useState(false);
  const [error, setError] = useState("");

  // The listing belongs to the seller's verified university — locked.
  const university = verification?.university || "";
  const state = universityState(university);

  const suggested = newPrice ? suggestPrice(newPrice, condition) : null;
  const fees = feeBreakdown(price, "held");

  async function onPhotos(e) {
    const files = [...e.target.files].slice(0, 4 - photos.length);
    const urls = [];
    for (const f of files) urls.push(await downscale(f));
    setPhotos([...photos, ...urls]);
  }

  async function publish() {
    setError("");
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
            onClick={() => setStep(i)}
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
              {CONDITIONS.map((c) => <option key={c}>{c}</option>)}
            </select>
          </label>
          <label className="block text-sm font-semibold">Category
            <select value={category} onChange={(e) => setCategory(e.target.value)} className={`${inputCls} mt-1`}>
              {CATEGORIES.map((c) => <option key={c}>{c}</option>)}
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
              <p className="flex justify-between text-neutral-500"><span>Service fee (5%)</span><span>{formatNaira(fees.serviceFee)}</span></p>
              <p className="flex justify-between text-neutral-500"><span>Secure payment fee</span><span>{formatNaira(fees.secureFee)}</span></p>
              <p className="mt-1 flex justify-between font-bold"><span>Buyer pays (held)</span><span>{formatNaira(fees.total)}</span></p>
              <p className="mt-1 text-neutral-500">Cash face-to-face: no fees — buyer pays {formatNaira(fees.price)}. You keep the full price either way.</p>
            </div>
          ) : null}
        </div>
      )}

      {step === 2 && (
        <div className="space-y-3">
          <div className="flex gap-2">
            <button onClick={() => setDelivery("meetup")} className={`flex-1 rounded-xl border px-3 py-3 text-sm font-semibold ${delivery === "meetup" ? "border-brown bg-brown-soft" : "border-neutral-300 dark:border-neutral-700"}`}>Meet in person</button>
            <button onClick={() => setDelivery("shipping")} className={`flex-1 rounded-xl border px-3 py-3 text-sm font-semibold ${delivery === "shipping" ? "border-brown bg-brown-soft" : "border-neutral-300 dark:border-neutral-700"}`}>Ship it</button>
          </div>
          {delivery === "shipping" && (
            <>
              <label className="block text-sm font-semibold">Courier
                <select value={courier} onChange={(e) => setCourier(e.target.value)} className={`${inputCls} mt-1`}>
                  {["GIG", "GUO", "Peace Mass Transit", "ABC Transport", "DHL", "Chowdeck Relay", "Bus Park"].map((c) => <option key={c}>{c}</option>)}
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
                    : "Students in every state will see this listing, because you ship anywhere."}
                </p>
              </div>
            </>
          )}
          <p className="text-sm text-neutral-500">
            {delivery === "meetup"
              ? "Face-to-face: the buyer scans your seller code at handoff before any money moves."
              : "Shipping: GIG / GUO between states, Chowdeck Relay same-city. You get 50% after shipping proof, 50% after delivery."}
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
            Add up to 4 photos
            <input type="file" accept="image/*" multiple onChange={onPhotos} className="mt-2 block w-full text-sm" />
          </label>
          <div className="grid grid-cols-2 gap-2">
            {photos.map((p, i) => (
              <img key={i} src={p} alt={`Photo ${i + 1}`} className="h-32 w-full rounded-xl object-cover" />
            ))}
          </div>
          <p className="text-sm text-neutral-500">Clear photos sell faster. Photos are uploaded with your listing.</p>
        </div>
      )}

      {step === 5 && (
        <label className="block text-sm font-semibold">Description
          <textarea value={description} onChange={(e) => setDescription(e.target.value)} rows={5} placeholder="Condition, what's included, any faults — be honest, it builds trust." className={`${inputCls} mt-1`} />
        </label>
      )}

      {step === 6 && (
        <div className="space-y-3">
          <label className="block text-sm font-semibold">Safe meetup spot
            <select value={spot} onChange={(e) => setSpot(e.target.value)} className={`${inputCls} mt-1`}>
              {SAFE_MEETUP_SPOTS.map((s) => <option key={s}>{s}</option>)}
            </select>
          </label>
          <div className="rounded-2xl border border-neutral-200 p-4 text-sm dark:border-neutral-800">
            <p className="font-bold">Stay safe</p>
            <ul className="mt-1 list-disc space-y-1 pl-5 text-neutral-500">
              <li>Meet in the daytime, in a busy public place on campus.</li>
              <li>Never pay before you inspect the item.</li>
              <li>The buyer must scan your seller code at handoff.</li>
            </ul>
          </div>
        </div>
      )}

      {error ? (
        <p className="rounded-xl bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-200">
          {error}
        </p>
      ) : null}

      <div className="fixed inset-x-0 bottom-16 z-10 border-t border-neutral-200 bg-white/95 px-4 py-3 backdrop-blur dark:border-neutral-800 dark:bg-black/95 sm:bottom-0">
        <div className="mx-auto flex max-w-2xl gap-2">
          {step > 0 && <GhostButton onClick={() => setStep(step - 1)}>Back</GhostButton>}
          {step < STEPS.length - 1 ? (
            <PrimaryButton className="flex-1" onClick={() => setStep(step + 1)}>Continue</PrimaryButton>
          ) : (
            <button onClick={publish} disabled={!name || !price || publishing} className="flex-1 rounded-full bg-brown px-5 py-2.5 text-sm font-semibold text-white disabled:opacity-50">
              {publishing ? "Publishing…" : "Publish listing"}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
