import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { EmptyState, GhostButton, PrimaryButton } from "../components/ui";
import { getVerification } from "../lib/store";
import { useAuth } from "../lib/auth";
import { fetchConversations, fetchParticipantsVerified } from "../lib/chat";
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
  const [hasMore, setHasMore] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [loading, setLoading] = useState(true);
  // Milestone 19: seller ids whose verification is no longer
  // approved, for the buyer-side conversations in the list. The
  // note shows only there — never for a buyer, never while the
  // seller is still approved.
  const [unverifiedSellerIds, setUnverifiedSellerIds] = useState({});
  // Poll guard: one load at a time, and none while the tab is hidden —
  // a slow fetch used to stack overlapping 20s polls.
  const loadRunning = useRef(false);
  // How many pages are currently shown. The 20s poll re-fetches this
  // many pages so a user who tapped "Load more" does not lose the
  // older chats on the next refresh.
  const pagesLoaded = useRef(1);

  // Fetch `count` pages in order, using each page's last row as the
  // cursor for the next. Stops early when a page is short or its last
  // row has no last_message_at to page from.
  async function loadPages(userId, count) {
    let rows = [];
    let more = false;
    let before = null;
    for (let i = 0; i < count; i++) {
      const page = await fetchConversations(
        userId,
        before ? { before } : {}
      );
      rows = rows.concat(page || []);
      more = page?.hasMore === true;
      if (!more || page.length === 0) break;
      before = page[page.length - 1]?.last_message_at || null;
      if (!before) {
        more = false;
        break;
      }
    }
    return { rows, hasMore: more };
  }

  // Next page of chats, from the last row's last_message_at.
  async function loadMore() {
    if (!user || loadingMore || !hasMore || conversations.length === 0) return;
    const before = conversations[conversations.length - 1]?.last_message_at;
    if (!before) {
      setHasMore(false);
      return;
    }
    setLoadingMore(true);
    try {
      const page = await fetchConversations(user.id, { before });
      setConversations((prev) => [...prev, ...(page || [])]);
      setHasMore(page?.hasMore === true);
      pagesLoaded.current += 1;
    } catch {
      // Keep the chats already shown; the next poll retries.
    } finally {
      setLoadingMore(false);
    }
  }

  useEffect(() => {
    if (!user) return;
    let cancelled = false;
    async function load() {
      if (loadRunning.current) return;
      loadRunning.current = true;
      try {
        const { rows, hasMore: more } = await loadPages(user.id, pagesLoaded.current);
        if (!cancelled) {
          setConversations(rows);
          setHasMore(more);
          setLoading(false);
        }
        // Milestone 19: one batch check for the sellers in the
        // buyer-side conversations. An unknown answer (RPC not
        // run yet, or no row back) leaves the note off.
        const sellerIds = [...new Set(
          rows.filter((c) => c.buyer_id === user.id && c.seller_id).map((c) => c.seller_id)
        )];
        if (sellerIds.length > 0) {
          const verified = await fetchParticipantsVerified(sellerIds);
          if (!cancelled) {
            const bad = {};
            for (const id of sellerIds) {
              if (id in verified && verified[id] !== true) bad[id] = true;
            }
            setUnverifiedSellerIds(bad);
          }
        } else if (!cancelled) {
          setUnverifiedSellerIds({});
        }
      } catch {
        if (!cancelled) {
          setConversations([]);
          setHasMore(false);
          setLoading(false);
        }
      } finally {
        loadRunning.current = false;
      }
    }
    load();
    // Polling-based chat (no realtime dependency): refresh the list.
    const timer = setInterval(() => {
      if (!document.hidden) load();
    }, 20000);
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
        <>
          <p className="text-sm text-neutral-500">
            Showing the first {conversations.length} {conversations.length === 1 ? "chat" : "chats"}
            {hasMore ? " — older chats are below." : "."}
          </p>
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
                      {/* Milestone 19: buyer-side only — the other
                          party is the seller, and that seller is no
                          longer verified. */}
                      {isBuyer && unverifiedSellerIds[c.seller_id] ? (
                        <p className="mt-1 text-sm font-semibold text-neutral-500">
                          This seller is no longer verified
                        </p>
                      ) : null}
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
          {hasMore && (
            <GhostButton className="w-full py-3" disabled={loadingMore} onClick={loadMore}>
              {loadingMore ? "Loading…" : "Load more"}
            </GhostButton>
          )}
        </>
      )}
    </div>
  );
}
