import { Link } from "react-router-dom";
import { EmptyState, PrimaryButton } from "../components/ui";
import { getVerification } from "../lib/store";

export default function Chat() {
  const verification = getVerification();
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
      <EmptyState
        title="No conversations yet"
        body="When you message a seller or a buyer replies to your listing, your chats appear here."
        action={
          <Link to="/search">
            <PrimaryButton>Browse items</PrimaryButton>
          </Link>
        }
      />
    </div>
  );
}
