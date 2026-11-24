import { useEffect, useState } from "react";
import { Link, NavLink, Route, Routes, useNavigate } from "react-router-dom";
import Home from "./pages/Home.jsx";
import Search from "./pages/Search.jsx";
import Sell from "./pages/Sell.jsx";
import Chat from "./pages/Chat.jsx";
import Dashboard from "./pages/Dashboard.jsx";
import Wallet from "./pages/Wallet.jsx";
import Profile from "./pages/Profile.jsx";
import Settings from "./pages/Settings.jsx";
import Verify from "./pages/Verify.jsx";
import Welcome from "./pages/Welcome.jsx";
import SignIn from "./pages/SignIn.jsx";
import { Logo } from "./components/ui.jsx";
import { getSettings, getVerification } from "./lib/store";
import { AuthProvider, useAuth } from "./lib/auth";

const TABS = [
  { to: "/", label: "Home", icon: "⌂" },
  { to: "/search", label: "Search", icon: "⌕" },
  { to: "/sell", label: "Sell", icon: "+" },
  { to: "/chat", label: "Chat", icon: "✉" },
  { to: "/dashboard", label: "Dashboard", icon: "▦" },
  { to: "/wallet", label: "Wallet", icon: "◈" },
  { to: "/profile", label: "Profile", icon: "○" },
];

function applyAppearance(s) {
  const root = document.documentElement;
  const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  const dark = s.theme === "dark" || (s.theme === "system" && prefersDark) || s.background === "black";
  root.classList.toggle("dark", dark);
  root.setAttribute("data-bg", s.background);
}

function Shell() {
  const { user, loading } = useAuth();
  const navigate = useNavigate();
  const [verification, setVerification] = useState(() => getVerification());

  useEffect(() => {
    applyAppearance(getSettings());
  }, []);

  if (loading) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center gap-3 bg-white text-neutral-900 dark:bg-black dark:text-neutral-100">
        <Logo size={56} />
        <p className="text-sm text-neutral-500">Loading PulseMarket…</p>
      </div>
    );
  }

  // 1) No account yet: the welcome page only — no bottom nav, no home page,
  // no Sell button. Joining or signing in leads to the separate sign-up /
  // sign-in pages, still with no bottom nav.
  if (!user) {
    return (
      <div className="min-h-screen bg-white text-neutral-900 dark:bg-black dark:text-neutral-100">
        <main className="mx-auto max-w-2xl px-4 pb-12 pt-4">
          <Routes>
            <Route path="/verify" element={<Verify onVerified={setVerification} />} />
            <Route path="/signin" element={<SignIn />} />
            <Route path="*" element={<Welcome />} />
          </Routes>

          <footer className="mt-12 border-t border-neutral-200 pt-6 text-sm text-neutral-500 dark:border-neutral-800">
            <p className="font-bold text-neutral-900 dark:text-white">PulseMarket</p>
            <p className="mt-1">
              Buy and sell safely with verified students at universities across Nigeria.
            </p>
            <p className="mt-2">Support: pulsemarketsupport@gmail.com</p>
            <p className="mt-3 text-xs text-neutral-400">
              Cash face-to-face deals have no fees. Held payments release only after the buyer confirms.
            </p>
          </footer>
        </main>
      </div>
    );
  }

  // 2) Account created but student verification not submitted yet: the
  // verification form only — still no bottom nav, no home page, no Sell.
  if (!verification) {
    return (
      <div className="min-h-screen bg-white text-neutral-900 dark:bg-black dark:text-neutral-100">
        <main className="mx-auto max-w-2xl px-4 pb-12 pt-4">
          <Routes>
            <Route path="*" element={<Verify onVerified={setVerification} />} />
          </Routes>
        </main>
      </div>
    );
  }

  // 3) Verified student: the full app.
  return (
    <div className="min-h-screen bg-white text-neutral-900 dark:bg-black dark:text-neutral-100">
      <header className="sticky top-0 z-20 border-b border-neutral-200 bg-white/95 backdrop-blur dark:border-neutral-800 dark:bg-black/95">
        <div className="mx-auto flex max-w-2xl items-center gap-2 px-4 py-3">
          <Link to="/" className="flex items-center gap-2">
            <Logo size={32} />
            <span className="text-lg font-bold">PulseMarket</span>
          </Link>
          <div className="flex-1" />
          <button
            onClick={() => navigate("/profile")}
            className="flex h-8 w-8 items-center justify-center rounded-full bg-brown text-sm font-bold text-white"
          >
            {(user.email?.[0] || "P").toUpperCase()}
          </button>
          <Link to="/settings" aria-label="Settings" className="rounded-full p-2 text-lg leading-none">
            ⚙
          </Link>
        </div>
      </header>

      <main className="mx-auto max-w-2xl px-4 pb-28 pt-4 sm:pb-24">
        <Routes>
          <Route path="/" element={<Home user={user} />} />
          <Route path="/search" element={<Search />} />
          <Route path="/sell" element={<Sell />} />
          <Route path="/chat" element={<Chat />} />
          <Route path="/dashboard" element={<Dashboard />} />
          <Route path="/wallet" element={<Wallet />} />
          <Route path="/profile" element={<Profile user={user} />} />
          <Route path="/settings" element={<Settings applyAppearance={applyAppearance} />} />
          <Route path="/verify" element={<Verify onVerified={setVerification} />} />
          <Route path="*" element={<Home user={user} />} />
        </Routes>

        <footer className="mt-12 border-t border-neutral-200 pt-6 text-sm text-neutral-500 dark:border-neutral-800">
          <p className="font-bold text-neutral-900 dark:text-white">PulseMarket</p>
          <p className="mt-1">
            Buy and sell safely with verified students at universities across Nigeria.
          </p>
          <p className="mt-2">
            Support: pulsemarketsupport@gmail.com
          </p>
          <p className="mt-2 flex flex-wrap gap-3">
            <Link to="/settings" className="underline">About</Link>
            <Link to="/settings" className="underline">Terms</Link>
            <Link to="/settings" className="underline">Privacy</Link>
          </p>
          <p className="mt-3 text-xs text-neutral-400">
            Cash face-to-face deals have no fees. Held payments release only after the buyer confirms.
          </p>
        </footer>
      </main>

      <nav className="fixed inset-x-0 bottom-0 z-20 border-t border-neutral-200 bg-white/95 backdrop-blur dark:border-neutral-800 dark:bg-black/95">
        <div className="mx-auto grid max-w-2xl grid-cols-7">
          {TABS.map((t) => (
            <NavLink
              key={t.to}
              to={t.to}
              end={t.to === "/"}
              className={({ isActive }) =>
                `flex flex-col items-center gap-0.5 py-2 text-[11px] font-semibold ${isActive ? "text-brown" : "text-neutral-500"}`
              }
            >
              <span className={`flex h-7 w-7 items-center justify-center rounded-full text-base leading-none ${t.label === "Sell" ? "bg-brown text-lg text-white" : ""}`}>
                {t.icon}
              </span>
              {t.label}
            </NavLink>
          ))}
        </div>
      </nav>
    </div>
  );
}

export default function App() {
  return (
    <AuthProvider>
      <Shell />
    </AuthProvider>
  );
}
