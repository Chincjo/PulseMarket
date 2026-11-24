import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { CATEGORIES, CONDITIONS, SAFE_MEETUP_SPOTS, UNIVERSITIES } from "../lib/data";
import { feeBreakdown, formatNaira, suggestPrice } from "../lib/fees";
import { addDraft } from "../lib/store";
import { GhostButton, PrimaryButton, inputCls } from "../components/ui";

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

export default function Sell() {
  const navigate = useNavigate();
  const [step, setStep] = useState(0);
  const [name, setName] = useState("");
  const [condition, setCondition] = useState("Good");
  const [category, setCategory] = useState(CATEGORIES[0]);
  const [newPrice, setNewPrice] = useState("");
  const [price, setPrice] = useState("");
  const [delivery, setDelivery] = useState("meetup");
  const [courier, setCourier] = useState("GIG");
  const [university, setUniversity] = useState(UNIVERSITIES[0]);
  const [photos, setPhotos] = useState([]);
  const [description, setDescription] = useState("");
  const [spot, setSpot] = useState(SAFE_MEETUP_SPOTS[0]);
  const [saved, setSaved] = useState(false);

  const suggested = newPrice ? suggestPrice(newPrice, condition) : null;
  const fees = feeBreakdown(price, "held");

  async function onPhotos(e) {
    const files = [...e.target.files].slice(0, 4 - photos.length);
    const urls = [];
    for (const f of files) urls.push(await downscale(f));
    setPhotos([...photos, ...urls]);
  }

  function publish() {
    addDraft({ name, condition, category, price: Number(price) || 0, delivery, courier, university, photos, description, spot, status: "draft" });
    setSaved(true);
  }

  if (saved) {
    return (
      <div className="space-y-4 pt-6 text-center">
        <p className="text-2xl font-bold">Draft saved</p>
        <p className="text-neutral-500">
          Your listing is saved as a draft on this device. Real publishing to
          all students goes live with Milestone 4 — your draft carries over.
        </p>
        <PrimaryButton onClick={() => navigate("/dashboard")}>View my listings</PrimaryButton>
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
            <label className="block text-sm font-semibold">Courier
              <select value={courier} onChange={(e) => setCourier(e.target.value)} className={`${inputCls} mt-1`}>
                {["GIG", "GUO", "Peace Mass Transit", "ABC Transport", "DHL", "Chowdeck Relay", "Bus Park"].map((c) => <option key={c}>{c}</option>)}
              </select>
            </label>
          )}
          <p className="text-sm text-neutral-500">
            {delivery === "meetup"
              ? "Face-to-face: the buyer scans your seller code at handoff before any money moves."
              : "Shipping: GIG / GUO between states, Chowdeck Relay same-city. You get 50% after shipping proof, 50% after delivery."}
          </p>
        </div>
      )}

      {step === 3 && (
        <label className="block text-sm font-semibold">Your university
          <select value={university} onChange={(e) => setUniversity(e.target.value)} className={`${inputCls} mt-1`}>
            {UNIVERSITIES.map((u) => <option key={u}>{u}</option>)}
          </select>
        </label>
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
          <p className="text-sm text-neutral-500">Clear photos sell faster. Photos are stored on this device until publishing goes live.</p>
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

      <div className="fixed inset-x-0 bottom-16 z-10 border-t border-neutral-200 bg-white/95 px-4 py-3 backdrop-blur dark:border-neutral-800 dark:bg-black/95 sm:bottom-0">
        <div className="mx-auto flex max-w-2xl gap-2">
          {step > 0 && <GhostButton onClick={() => setStep(step - 1)}>Back</GhostButton>}
          {step < STEPS.length - 1 ? (
            <PrimaryButton className="flex-1" onClick={() => setStep(step + 1)}>Continue</PrimaryButton>
          ) : (
            <button onClick={publish} disabled={!name || !price} className="flex-1 rounded-full bg-brown px-5 py-2.5 text-sm font-semibold text-white disabled:opacity-50">
              Save draft listing
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
