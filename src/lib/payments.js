// Milestone 6 — Payments in MANUAL-ESCROW MODE.
//
// There is no payment provider wired into the app. PulseMarket holds the
// buyer's money itself: the buyer transfers to PulseMarket's bank account,
// the PulseMarket team confirms the transfer arrived, the money sits in
// "hold" until the buyer confirms delivery, and only then is it released
// to the seller. That is the whole payment flow for now.
//
// PAYMENTS_MODE = 'manual' is the live mode. 'paystack' is a reserved
// future slot only — Paystack activation was refused (it needs a CAC
// registered business plus escrow authorisation), so there is deliberately
// NO Paystack code, key, SDK or test-mode checkout anywhere in this file
// or in the Milestone 6 code. When that changes, add the provider behind
// this flag; do not bolt it onto the manual flow.
export const PAYMENTS_MODE = "manual";

// The PulseMarket team's support inbox. The owner is identified by this
// email in the database rules and in the order actions (only this account
// can confirm a bank transfer arrived or release held money).
export const OWNER_EMAIL = "pulsemarketsupport@gmail.com";

// PulseMarket's bank account for held payments. All fields are blank on
// purpose: NEVER invent a bank account number. The owner fills these in
// once the real account is ready. Until then the checkout and order pages
// say transfer details are shared by the PulseMarket team by email.
export const PULSEMARKET_BANK = {
  bank: "",
  accountNumber: "",
  accountName: "PulseMarket",
};

export function bankDetailsReady() {
  return Boolean(PULSEMARKET_BANK.bank && PULSEMARKET_BANK.accountNumber);
}

// ---------------------------------------------------------------------------
// Shipping zones (estimates). Same state ₦1,500, neighbouring state
// ₦2,500, far state ₦3,500 (the low end of the "₦3,500–4,500" range in
// SHIPPING_ZONES, labelled an estimate at checkout). The exact shipping
// fee is confirmed by the team when the parcel is booked.
// ---------------------------------------------------------------------------

// Neighbouring states, for the states the app's universities sit in.
// (Real Nigerian geography; states outside this list are treated as far.)
const NEIGHBOURING_STATES = {
  Rivers: ["Delta", "Imo"],
  Lagos: ["Ogun"],
  Oyo: ["Osun", "Ogun", "Kwara", "Ondo"],
  Osun: ["Oyo", "Ondo", "Kwara", "Edo"],
  Enugu: ["Anambra"],
  Kaduna: ["Niger", "Plateau", "Kano"],
  Edo: ["Delta", "Ondo"],
  Kwara: ["Oyo", "Osun", "Niger"],
  Ondo: ["Oyo", "Osun", "Edo", "Delta", "Ogun"],
  Imo: ["Rivers", "Anambra"],
  Niger: ["Kaduna", "Kwara", "Plateau"],
  Anambra: ["Enugu", "Imo", "Delta"],
  "Cross River": [],
  Plateau: ["Kaduna", "Niger"],
  Kano: ["Kaduna"],
  Delta: ["Edo", "Rivers", "Anambra", "Ondo"],
  Ogun: ["Lagos", "Oyo", "Ondo"],
};

export function shippingZone(buyerState, sellerState) {
  if (!buyerState || !sellerState || buyerState === sellerState) {
    return { key: "same", label: "Same state", fee: 1500, isEstimate: false };
  }
  const neighbours = NEIGHBOURING_STATES[sellerState] || [];
  if (neighbours.includes(buyerState)) {
    return {
      key: "neighbouring",
      label: "Neighbouring state",
      fee: 2500,
      isEstimate: false,
    };
  }
  return {
    key: "far",
    label: "Far state",
    fee: 3500,
    isEstimate: true,
  };
}

export function shippingFeeForStates(buyerState, sellerState) {
  return shippingZone(buyerState, sellerState).fee;
}
