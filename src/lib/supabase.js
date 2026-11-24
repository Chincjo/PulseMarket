// Supabase (free tier) — accounts, database and storage for PulseMarket.
// Keys come from VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY (see
// .env.example). Until the owner creates the free Supabase project and adds
// those keys in Vercel, `supabase` is null and the UI says accounts are
// being switched on instead of crashing or faking a login.
import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

export function isSupabaseConfigured() {
  return Boolean(url && anonKey);
}

export const supabase = isSupabaseConfigured()
  ? createClient(url, anonKey)
  : null;
