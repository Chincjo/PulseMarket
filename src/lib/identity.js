// Netlify Identity (accounts + sign-in) for the live site.
// Identity must be enabled on the Netlify site; if it is not, every helper
// below fails soft and the UI shows sign-in as unavailable instead of crashing.
import netlifyIdentity from "netlify-identity-widget";

const SITE_URL = "https://pulsemarket-app-1c9cef.netlify.app";
let ready = false;

export function initIdentity() {
  if (ready) return;
  ready = true;
  try {
    netlifyIdentity.init({ APIUrl: `${SITE_URL}/.netlify/identity` });
  } catch {
    // Identity not enabled on the site yet — UI handles the null user.
  }
}

export function currentUser() {
  try {
    return netlifyIdentity.currentUser();
  } catch {
    return null;
  }
}

export function openAuth(tab = "login") {
  initIdentity();
  try {
    netlifyIdentity.open(tab);
  } catch {
    // no-op: identity unavailable
  }
}

export function logout() {
  try {
    netlifyIdentity.logout();
  } catch {
    // no-op
  }
}

export function onAuthChange(cb) {
  initIdentity();
  try {
    netlifyIdentity.on("login", cb);
    netlifyIdentity.on("logout", cb);
    netlifyIdentity.on("close", () => cb(currentUser()));
  } catch {
    // no-op
  }
}
