import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { EmptyState, PrimaryButton } from "../components/ui";
import { getVerification } from "../lib/store";
import { useAuth } from "../lib/auth";
import { fetchConversations } from "../lib/chat";
import { formatNaira } from "../lib/fees";

function timeAgo(iso) {
  if (!iso) return "";
  const s = Math.floor((Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return "Just now";
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

export default function Chat() {
  const { user } = useAuth();
  const verification = getVerification();
  const [conversations, setConversations] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!user) return;
    let cancelled = false;
    async function load() {
      const rows = await fetchConversations(user.id);
      if (!cancelled) {
        setConversations(rows);
        setLoading(false);
      }
    }
    load();
    // Polling-based chat (no realtime dependency): refresh the list.
    const timer = setInterval(load, 20000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [user]);

  return (
    <div className="space-y-5">
      <h1 className="text-2xl font-bold">Chat</h1>
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

      {loading ? (
        <p className="text-sm text-neutral-500">Loading your chats…</p>
      ) : conversations.length === 0 ? (
        <EmptyState
          title="No conversations yet"
          body="When you message a seller or a buyer replies to your listing, your chats appear here."
          action={
            <Link to="/search">
              <PrimaryButton>Browse items</PrimaryButton>
            </Link>
          }
        />
      ) : (
        <ul className="space-y-3">
          {conversations.map((c) => {
            const isBuyer = c.buyer_id === user?.id;
            const other = isBuyer ? c.seller_label : "Buyer";
            const preview =
              c.lastMessage?.kind === "offer"
                ? `Offer: ${formatNaira(c.lastMessage.offer_amount)}`
                : c.lastMessage?.body || "Chat started";
            return (
              <li key={c.id}>
                <Link
                  to={`/chat/${c.id}`}
                  className="block rounded-2xl border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950"
                >
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p className="truncate font-semibold">{c.listing_title || "Listing"}</p>
                      <p className="mt-0.5 text-sm text-neutral-500">
                        {isBuyer ? `Seller: ${other}` : "You are the seller"} ·{" "}
                        {formatNaira(c.agreed_price ?? c.listing_price)}
                        {c.agreed_price ? " (agreed price)" : ""}
                      </p>
                      <p className="mt-1 truncate text-sm text-neutral-500">{preview}</p>
                    </div>
                    <div className="flex shrink-0 flex-col items-end gap-1">
                      <span className="text-xs text-neutral-400">
                        {timeAgo(c.last_message_at || c.created_at)}
                      </span>
                      {c.unreadCount > 0 ? (
                        <span className="flex h-6 min-w-6 items-center justify-center rounded-full bg-brown px-1.5 text-xs font-bold text-white">
                          {c.unreadCount}
                        </span>
                      ) : null}
                    </div>
                  </div>
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
