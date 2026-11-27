// Real accounts via Supabase Auth (email + password, Google).
// The session is persisted by Supabase, so a signed-in student stays signed
// in across visits. When Supabase is not configured yet (no env keys),
// `configured` is false, `user` stays null, and the UI explains that
// accounts are being switched on — nothing is faked.
import { createContext, useContext, useEffect, useState } from "react";
import { supabase, isSupabaseConfigured } from "./supabase";
import { saveVerification } from "./store";

const AuthContext = createContext(null);

export function useAuth() {
  return useContext(AuthContext);
}

export function AuthProvider({ children }) {
  const [user, setUser] = useState(null);
  const [loading, setLoading] = useState(true);
  const configured = isSupabaseConfigured();

  useEffect(() => {
    if (!configured || !supabase) {
      setLoading(false);
      return;
    }
    // Milestone 20 (APP-13): a failed session read must still clear
    // loading — without the catch a network error left the app on
    // its loading screen for ever.
    supabase.auth
      .getSession()
      .then(({ data }) => {
        setUser(data.session?.user ?? null);
        setLoading(false);
      })
      .catch(() => {
        setUser(null);
        setLoading(false);
      });
    const { data: listener } = supabase.auth.onAuthStateChange(
      (_event, session) => {
        setUser(session?.user ?? null);
      }
    );
    return () => listener.subscription.unsubscribe();
  }, [configured]);

  async function signUpEmail(email, password) {
    const { data, error } = await supabase.auth.signUp({ email, password });
    if (error) throw error;
    return data;
  }

  async function signInEmail(email, password) {
    const { data, error } = await supabase.auth.signInWithPassword({
      email,
      password,
    });
    if (error) throw error;
    return data;
  }

  async function signInGoogle() {
    const { data, error } = await supabase.auth.signInWithOAuth({
      provider: "google",
      options: { redirectTo: `${window.location.origin}/` },
    });
    if (error) throw error;
    return data;
  }

  async function signOut() {
    if (supabase) await supabase.auth.signOut();
    // Milestone 22: the device verification copy must not survive
    // sign-out — on a shared phone the next signer would otherwise
    // inherit the previous student's record (see App.jsx).
    saveVerification(null);
    setUser(null);
  }

  return (
    <AuthContext.Provider
      value={{
        user,
        loading,
        configured,
        signUpEmail,
        signInEmail,
        signInGoogle,
        signOut,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}
