import { useEffect, useState } from "react";
import { getSettings, saveSettings } from "../lib/store";
import { inputCls } from "../components/ui";
import { supabase } from "../lib/supabase";
import { useAuth } from "../lib/auth";
import { fetchBlockedIds } from "../lib/chat";

const BACKGROUNDS = [
  { id: "system", label: "System" },
  { id: "white", label: "White" },
  { id: "black", label: "Black" },
  { id: "brown", label: "Brown" },
];

export default function Settings({ applyAppearance }) {
  const { user } = useAuth();
  const [settings, setSettings] = useState(getSettings());
  const [copied, setCopied] = useState(false);
  const [copyFailed, setCopyFailed] = useState(false);
  const [cleared, setCleared] = useState(false);
  const [blockedCount, setBlockedCount] = useState(null);

  // The old line here always said "Blocked users: none", even after
  // the student blocked someone in a chat. Read the real list.
  useEffect(() => {
    if (!user) return;
    let alive = true;
    fetchBlockedIds(user.id)
      .then((ids) => {
        if (alive) setBlockedCount((ids || []).length);
      })
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [user]);

  async function copySupportEmail() {
    setCopyFailed(false);
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText("pulsemarketsupport@gmail.com");
        setCopied(true);
      } else {
        setCopyFailed(true);
      }
    } catch {
      setCopyFailed(true);
    }
  }

  function update(patch) {
    const next = { ...settings, ...patch };
    setSettings(next);
    saveSettings(next);
    applyAppearance(next);
  }

  // The verified-only chat toggle is enforced server-side (Milestone 5):
  // the value lives on the verifications row so it follows the student to
  // any phone. The device copy in pm-settings stays as the fallback.
  function toggleVerifiedOnlyChat() {
    const next = !settings.verifiedOnlyChat;
    update({ verifiedOnlyChat: next });
    if (supabase && user) {
      supabase
        .from("verifications")
        .update({ chat_verified_only: next })
        .eq("user_id", user.id)
        .then(({ error }) => {
          if (error) console.error("[PulseMarket] save verified-only chat:", error.message);
        });
    }
  }

  function toggleNotif(key) {
    update({ notifications: { ...settings.notifications, [key]: !settings.notifications[key] } });
  }

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold">Settings</h1>

      <section className="space-y-3">
        <h2 className="font-bold">Appearance</h2>
        <label className="block text-sm font-semibold">Theme
          <select value={settings.theme} onChange={(e) => update({ theme: e.target.value })} className={`${inputCls} mt-1`}>
            <option value="system">System</option>
            <option value="light">Light</option>
            <option value="dark">Dark</option>
          </select>
        </label>
        <p className="text-sm font-semibold">Background</p>
        <div className="flex gap-2">
          {BACKGROUNDS.map((b) => (
            <button
              key={b.id}
              onClick={() => update({ background: b.id })}
              className={`flex-1 rounded-xl border px-3 py-2.5 text-sm font-semibold ${settings.background === b.id ? "border-brown bg-brown-soft" : "border-neutral-300 dark:border-neutral-700"}`}
            >
              {b.label}
            </button>
          ))}
        </div>
      </section>

      <section className="space-y-3">
        <h2 className="font-bold">Notifications</h2>
        {[
          ["priceDrops", "Price drops on saved items"],
          ["checkpoints", "Shipping checkpoints"],
          ["disputes", "Dispute updates"],
          ["ratings", "Rating reminders"],
        ].map(([key, label]) => (
          <label key={key} className="flex items-center justify-between text-sm">
            {label}
            <input type="checkbox" checked={settings.notifications[key]} onChange={() => toggleNotif(key)} className="h-5 w-5 accent-[#7d5027]" />
          </label>
        ))}
      </section>

      <section className="space-y-3">
        <h2 className="font-bold">Privacy & safety</h2>
        <label className="flex items-center justify-between text-sm">
          Only verified students can message me
          <input
            type="checkbox"
            checked={settings.verifiedOnlyChat}
            onChange={toggleVerifiedOnlyChat}
            className="h-5 w-5 accent-[#7d5027]"
          />
        </label>
        <p className="text-sm text-neutral-500">
          Blocked users:{" "}
          {blockedCount === null
            ? "—"
            : blockedCount === 0
              ? "none. Blocking stops messages from that student."
              : `${blockedCount} — unblock them from the chat with that student.`}
        </p>
      </section>

      <section className="space-y-3">
        <h2 className="font-bold">Support</h2>
        <p className="text-sm text-neutral-500">
          Questions, disputes and complaints go to our support email. We reply from there — never from a personal address.
        </p>
        <button
          onClick={copySupportEmail}
          className="rounded-full border border-neutral-300 px-4 py-2 text-sm font-semibold dark:border-neutral-700"
        >
          {copied ? "Email copied" : "Copy pulsemarketsupport@gmail.com"}
        </button>
        {copyFailed ? (
          <p className="text-sm text-neutral-500">
            Copy did not work — the email is pulsemarketsupport@gmail.com.
          </p>
        ) : null}
      </section>

      <section className="space-y-3">
        <h2 className="font-bold">Data</h2>
        <button
          onClick={() => {
            if (window.confirm("Clear all PulseMarket data on this device (drafts, settings, verification)?")) {
              Object.keys(localStorage).filter((k) => k.startsWith("pm-")).forEach((k) => localStorage.removeItem(k));
              setCleared(true);
            }
          }}
          className="rounded-full border border-red-300 px-4 py-2 text-sm font-semibold text-red-600"
        >
          Clear my data
        </button>
        {cleared ? <p className="text-sm text-neutral-500">Your data on this device was cleared.</p> : null}
      </section>

      <section className="space-y-2 text-sm text-neutral-500">
        <h2 className="font-bold text-neutral-900 dark:text-white">About PulseMarket</h2>
        <p>
          PulseMarket is a marketplace for verified students to buy and sell
          safely inside and between schools across Nigeria. Listing is free.
          The buyer pays a small fee, the seller keeps the full price. Money
          is held until the buyer confirms the item is correct with photo and
          video. No scam.
        </p>
        <p>
          Terms: be honest about condition, meet in safe public places, never
          pay outside the app for shipped items. If an item is wrong, the
          seller pays the return. Disputes are reviewed by the PulseMarket team.
        </p>
        <p>Version 0.1 — foundation build. Support: pulsemarketsupport@gmail.com</p>
      </section>
    </div>
  );
}
