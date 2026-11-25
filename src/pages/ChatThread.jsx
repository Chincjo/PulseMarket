// Milestone 5 — one chat thread: /chat/:id (the route is added by the
// coordinator). Polling-based: messages refresh every 10 seconds.
// Offers render as cards: the person who did NOT send the offer can
// Accept or Decline it while it is pending; accepting sets the agreed
// price on the conversation. Pickup tickets only plan the meetup — the
// seller-code handoff that proves the handover arrives in Milestone 7.
import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { EmptyState, GhostButton, PrimaryButton, inputCls } from "../components/ui";
import { getVerification } from "../lib/store";
import { useAuth } from "../lib/auth";
import { SAFE_MEETUP_SPOTS } from "../lib/data";
import { formatNaira } from "../lib/fees";
import {
  MAX_MESSAGE_LENGTH,
  MAX_OFFER_NAIRA,
  QUICK_REPLIES,
  blockUser,
  fetchBlockedIds,
  fetchConversation,
  fetchMessages,
  fetchPickupTickets,
  markRead,
  respondOffer,
  schedulePickup,
  sendMessage,
  sendOffer,
  unblockUser,
} from "../lib/chat";

function timeAgo(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  return d.toLocaleString("en-NG", {
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export default function ChatThread() {
  const { id } = useParams();
  const { user } = useAuth();
  const verification = getVerification();
  const [conversation, setConversation] = useState(null);
  const [messages, setMessages] = useState([]);
  const [tickets, setTickets] = useState([]);
  const [blockedIds, setBlockedIds] = useState([]);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const [draft, setDraft] = useState("");
  const [offerAmount, setOfferAmount] = useState("");
  const [showOffer, setShowOffer] = useState(false);
  const [spot, setSpot] = useState(SAFE_MEETUP_SPOTS[0]);
  const [date, setDate] = useState("");
  const [time, setTime] = useState("");
  const [showPickup, setShowPickup] = useState(false);
  const [error, setError] = useState("");
  const [sending, setSending] = useState(false);

  const isParticipant =
    conversation &&
    user &&
    (conversation.buyer_id === user.id || conversation.seller_id === user.id);
  const otherId =
    conversation && user
      ? conversation.buyer_id === user.id
        ? conversation.seller_id
        : conversation.buyer_id
      : null;
  const isBlocked = otherId ? blockedIds.includes(otherId) : false;

  useEffect(() => {
    if (!user || !id) return;
    let cancelled = false;
    async function load() {
      let conv;
      try {
        conv = await fetchConversation(id);
      } catch {
        if (!cancelled) {
          setNotFound(true);
          setLoading(false);
        }
        return;
      }
      if (cancelled) return;
      if (!conv) {
        setNotFound(true);
        setLoading(false);
        return;
      }
      setConversation(conv);
      setLoading(false);
      if (conv.buyer_id !== user.id && conv.seller_id !== user.id) return;
      const [msgs, tks, blocked] = await Promise.all([
        fetchMessages(id),
        fetchPickupTickets(id),
        fetchBlockedIds(user.id),
      ]);
      if (cancelled) return;
      setMessages(msgs);
      setTickets(tks);
      setBlockedIds(blocked);
      markRead(id, user.id).catch(() => {});
    }
    load();
    const timer = setInterval(load, 10000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [user, id]);

  async function refreshMessages() {
    setMessages(await fetchMessages(id));
    markRead(id, user.id).catch(() => {});
  }

  async function handleSend(e) {
    e.preventDefault();
    if (!draft.trim() || sending) return;
    if (draft.trim().length > MAX_MESSAGE_LENGTH) {
      setError(`Message is too long — keep it under ${MAX_MESSAGE_LENGTH} characters.`);
      return;
    }
    setSending(true);
    setError("");
    const sent = await sendMessage(id, draft);
    setSending(false);
    if (!sent) {
      setError("Could not send the message. Try again.");
      return;
    }
    setDraft("");
    refreshMessages();
  }

  async function handleOffer(e) {
    e.preventDefault();
    const amount = Math.round(Number(offerAmount) || 0);
    if (amount <= 0) {
      setError("Enter an offer amount above ₦0.");
      return;
    }
    // No upper bound before: an offer of ₦999,999,999 went through.
    if (amount > MAX_OFFER_NAIRA) {
      setError(`Offer is too high — keep it under ₦${MAX_OFFER_NAIRA.toLocaleString("en-NG")}.`);
      return;
    }
    setSending(true);
    setError("");
    const sent = await sendOffer(id, amount);
    setSending(false);
    if (!sent) {
      setError("Could not send the offer. Try again.");
      return;
    }
    setOfferAmount("");
    setShowOffer(false);
    refreshMessages();
  }

  async function handleRespond(messageId, decision) {
    const ok = await respondOffer(messageId, decision);
    if (!ok) {
      setError("Could not update the offer. Try again.");
      return;
    }
    const conv = await fetchConversation(id);
    if (conv) setConversation(conv);
    refreshMessages();
  }

  async function handlePickup(e) {
    e.preventDefault();
    if (!spot || !date || !time) {
      setError("Pick a spot, a date and a time for the meetup.");
      return;
    }
    // A meetup in the past used to save without complaint.
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const picked = new Date(`${date}T00:00:00`);
    if (Number.isNaN(picked.getTime())) {
      setError("Pick a valid date for the meetup.");
      return;
    }
    if (picked < today) {
      setError("That date is in the past — pick a date from today onwards.");
      return;
    }
    if (picked.getTime() - today.getTime() > 90 * 24 * 60 * 60 * 1000) {
      setError("Pick a date within the next 90 days.");
      return;
    }
    setError("");
    const ticket = await schedulePickup(id, { spot, date, time });
    if (!ticket) {
      setError("Could not save the pickup. Try again.");
      return;
    }
    setTickets((t) => [ticket, ...t]);
    setDate("");
    setTime("");
    setShowPickup(false);
  }

  async function handleBlock() {
    if (!otherId) return;
    if (isBlocked) {
      if (await unblockUser(user.id, otherId)) {
        setBlockedIds((b) => b.filter((x) => x !== otherId));
      }
      return;
    }
    if (!window.confirm("Block this student? They will not be able to start a new chat with you.")) return;
    if (await blockUser(user.id, otherId)) {
      setBlockedIds((b) => [...b, otherId]);
    }
  }

  if (loading) {
    return (
      <div className="space-y-5">
        <p className="text-sm text-neutral-500">Loading chat…</p>
      </div>
    );
  }

  if (notFound || !conversation) {
    return (
      <div className="space-y-5">
        <EmptyState
          title="Chat not found"
          body="This conversation does not exist, or the chat tables have not been switched on yet."
          action={
            <Link to="/chat">
              <PrimaryButton>Back to chats</PrimaryButton>
            </Link>
          }
        />
      </div>
    );
  }

  if (!isParticipant) {
    return (
      <div className="space-y-5">
        <EmptyState
          title="This chat is not yours"
          body="You can only open conversations you are part of."
          action={
            <Link to="/chat">
              <PrimaryButton>Back to chats</PrimaryButton>
            </Link>
          }
        />
      </div>
    );
  }

  return (
    <div className="space-y-5">
      <div>
        <Link to="/chat" className="text-sm font-semibold text-brown">
          ← All chats
        </Link>
        <h1 className="mt-2 text-xl font-bold">{conversation.listing_title || "Listing"}</h1>
        <p className="text-sm text-neutral-500">
          {conversation.buyer_id === user.id
            ? `Seller: ${conversation.seller_label}`
            : "You are the seller"}{" "}
          · Listed at {formatNaira(conversation.listing_price)}
          {conversation.agreed_price
            ? ` · Agreed price: ${formatNaira(conversation.agreed_price)}`
            : ""}
        </p>
        {conversation.listing_id ? (
          <Link to={`/listing/${conversation.listing_id}`} className="text-sm font-semibold text-brown underline">
            View listing
          </Link>
        ) : null}
      </div>

      {!verification ? (
        <div className="rounded-2xl border border-brown/40 bg-brown-soft p-4 text-sm">
          <p className="font-bold text-brown-dark">Only verified students can chat</p>
          <p className="mt-1 text-brown-dark/80">
            Verify your student status first, then you can message sellers and buyers.
          </p>
          <Link to="/verify" className="mt-3 inline-block">
            <PrimaryButton>Get verified</PrimaryButton>
          </Link>
        </div>
      ) : null}

      {conversation.agreed_price ? (
        <div className="rounded-2xl border border-brown/40 bg-brown-soft p-4 text-sm">
          <p className="font-bold text-brown-dark">
            Agreed price: {formatNaira(conversation.agreed_price)}
          </p>
          <p className="mt-1 text-brown-dark/80">
            You both agreed this price. Pay cash face to face (no fee) or through the app once held payments go live.
          </p>
        </div>
      ) : null}

      {isBlocked ? (
        <div className="rounded-2xl border border-neutral-300 bg-neutral-100 p-4 text-sm dark:border-neutral-700 dark:bg-neutral-900">
          <p className="font-bold">You blocked this student.</p>
          <p className="mt-1 text-neutral-500">They cannot start a new chat with you. Unblock them below to talk again.</p>
        </div>
      ) : null}

      {error ? <p className="text-sm font-semibold text-red-700">{error}</p> : null}

      {/* Messages */}
      <div className="space-y-3">
        {messages.length === 0 ? (
          <p className="text-sm text-neutral-500">
            No messages yet. Say hello — agree the price and where to meet before you pay anything.
          </p>
        ) : (
          messages.map((m) => {
            const mine = m.sender_id === user.id;
            if (m.kind === "offer") {
              const canRespond = !mine && m.offer_status === "pending";
              return (
                <div
                  key={m.id}
                  className={`rounded-2xl border p-4 ${
                    mine
                      ? "ml-8 border-neutral-200 bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950"
                      : "mr-8 border-brown/40 bg-brown-soft"
                  }`}
                >
                  <p className="text-xs font-semibold text-neutral-500">
                    {mine ? "Your offer" : "Offer from the other student"}
                  </p>
                  <p className="mt-1 text-lg font-bold">{formatNaira(m.offer_amount)}</p>
                  <p className="text-sm text-neutral-500">
                    {m.offer_status === "pending"
                      ? "Waiting for a reply"
                      : m.offer_status === "accepted"
                        ? "Accepted — this is now the agreed price"
                        : "Declined"}
                    {" · "}
                    {timeAgo(m.created_at)}
                  </p>
                  {canRespond ? (
                    <div className="mt-3 flex gap-2">
                      <PrimaryButton onClick={() => handleRespond(m.id, "accepted")}>
                        Accept offer
                      </PrimaryButton>
                      <GhostButton onClick={() => handleRespond(m.id, "declined")}>
                        Decline
                      </GhostButton>
                    </div>
                  ) : null}
                </div>
              );
            }
            return (
              <div key={m.id} className={`flex ${mine ? "justify-end" : "justify-start"}`}>
                <div
                  className={`max-w-[80%] rounded-2xl px-4 py-2.5 text-sm ${
                    mine
                      ? "bg-brown text-white"
                      : "border border-neutral-200 bg-neutral-100 dark:border-neutral-800 dark:bg-neutral-900"
                  }`}
                >
                  <p>{m.body}</p>
                  <p className={`mt-1 text-[11px] ${mine ? "text-white/70" : "text-neutral-400"}`}>
                    {timeAgo(m.created_at)}
                  </p>
                </div>
              </div>
            );
          })
        )}
      </div>

      {/* Quick replies */}
      <div className="flex flex-wrap gap-2">
        {QUICK_REPLIES.map((q) => (
          <button
            key={q}
            type="button"
            onClick={() => setDraft(q)}
            className="rounded-full border border-neutral-300 px-3 py-1.5 text-sm font-semibold dark:border-neutral-700"
          >
            {q}
          </button>
        ))}
      </div>

      {/* Message input */}
      <form onSubmit={handleSend} className="flex gap-2">
        <input
          className={inputCls}
          value={draft}
          onChange={(e) => setDraft(e.target.value.slice(0, MAX_MESSAGE_LENGTH))}
          placeholder="Write a message…"
          maxLength={MAX_MESSAGE_LENGTH}
          disabled={isBlocked}
        />
        <PrimaryButton type="submit" disabled={sending || !draft.trim() || isBlocked}>
          Send
        </PrimaryButton>
      </form>

      {/* Offer */}
      <div className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
        {showOffer ? (
          <form onSubmit={handleOffer} className="flex flex-wrap items-end gap-2">
            <label className="flex-1 text-sm font-semibold">
              Your offer (₦)
              <input
                className={inputCls}
                type="number"
                min="1"
                value={offerAmount}
                onChange={(e) => setOfferAmount(e.target.value)}
                placeholder="e.g. 45000"
              />
            </label>
            <PrimaryButton type="submit" disabled={sending}>
              Send offer
            </PrimaryButton>
            <GhostButton type="button" onClick={() => setShowOffer(false)}>
              Cancel
            </GhostButton>
          </form>
        ) : (
          <GhostButton onClick={() => setShowOffer(true)}>Make an offer</GhostButton>
        )}
      </div>

      {/* Schedule pickup */}
      <div className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
        <div className="flex items-center justify-between gap-2">
          <h2 className="font-bold">Schedule pickup</h2>
          <GhostButton onClick={() => setShowPickup((s) => !s)}>
            {showPickup ? "Close" : "Plan a meetup"}
          </GhostButton>
        </div>
        <p className="mt-1 text-sm text-neutral-500">
          Pickup tickets are for agreeing where and when to meet. The seller-code handoff that proves
          the item changed hands arrives in a later update.
        </p>
        {showPickup ? (
          <form onSubmit={handlePickup} className="mt-3 space-y-3">
            <label className="block text-sm font-semibold">
              Safe meetup spot
              <select className={inputCls} value={spot} onChange={(e) => setSpot(e.target.value)}>
                {SAFE_MEETUP_SPOTS.map((s) => (
                  <option key={s} value={s}>
                    {s}
                  </option>
                ))}
              </select>
            </label>
            <div className="flex gap-2">
              <label className="flex-1 text-sm font-semibold">
                Date
                <input className={inputCls} type="date" value={date} onChange={(e) => setDate(e.target.value)} />
              </label>
              <label className="flex-1 text-sm font-semibold">
                Time
                <input className={inputCls} type="time" value={time} onChange={(e) => setTime(e.target.value)} />
              </label>
            </div>
            <PrimaryButton type="submit">Save pickup</PrimaryButton>
          </form>
        ) : null}
        {tickets.length > 0 ? (
          <ul className="mt-3 space-y-2">
            {tickets.map((t) => (
              <li
                key={t.id}
                className="rounded-xl border border-neutral-200 px-3 py-2 text-sm dark:border-neutral-800"
              >
                <span className="font-semibold">{t.meetup_spot}</span> · {t.date} at {t.time} ·{" "}
                <span className="text-neutral-500">{t.status}</span>
              </li>
            ))}
          </ul>
        ) : null}
      </div>

      <div className="flex justify-between gap-2">
        <GhostButton onClick={handleBlock}>
          {isBlocked ? "Unblock student" : "Block student"}
        </GhostButton>
        <p className="text-xs text-neutral-400">
          Need help? Support: pulsemarketsupport@gmail.com
        </p>
      </div>
    </div>
  );
}
