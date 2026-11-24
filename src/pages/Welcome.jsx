// Welcome page — the FIRST thing anyone sees. It stands completely on its
// own: no bottom navigation, no home page, no Sell button. Joining or
// signing in takes the student to the separate sign-up / sign-in pages, and
// only after the account is created AND student verification is submitted
// does the home page and the rest of the app unlock.
import { Link } from "react-router-dom";
import { GhostButton, Logo, PrimaryButton } from "../components/ui";
import { useAuth } from "../lib/auth";

const SAFETY = [
  { title: "Money on hold", body: "The buyer pays into hold. The seller never touches it until the buyer confirms." },
  { title: "Meet + inspect", body: "Meet at a safe spot, scan the seller code, check the item with photo and video." },
  { title: "Released", body: "Money releases to the seller after approval — or automatically after 48 hours." },
];

export default function Welcome() {
  const { configured } = useAuth();
  return (
    <div className="flex min-h-screen flex-col items-center justify-center px-6 py-10 text-center">
      <Logo size={72} />
      <h1 className="mt-6 text-3xl font-bold">PulseMarket</h1>
      <p className="mt-2 max-w-sm text-neutral-500">
        Buy and sell safely with verified students at universities across
        Nigeria.
      </p>

      <div className="mt-8 w-full max-w-sm space-y-3 text-left">
        {SAFETY.map((s) => (
          <div
            key={s.title}
            className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800"
          >
            <p className="font-bold">{s.title}</p>
            <p className="mt-1 text-sm text-neutral-500">{s.body}</p>
          </div>
        ))}
      </div>

      <div className="mt-8 w-full max-w-sm space-y-2">
        <Link to="/verify" className="block">
          <PrimaryButton className="w-full">Join & verify</PrimaryButton>
        </Link>
        <Link to="/signin" className="block">
          <GhostButton className="w-full">
            I already have an account — sign in
          </GhostButton>
        </Link>
      </div>

      {!configured ? (
        <p className="mt-6 w-full max-w-sm rounded-2xl bg-amber-50 p-3 text-sm text-amber-800 dark:bg-amber-950 dark:text-amber-200">
          Student accounts are being switched on right now — please check back
          shortly.
        </p>
      ) : null}

      <p className="mt-8 text-xs text-neutral-400">
        Support: pulsemarketsupport@gmail.com
      </p>
    </div>
  );
}
