// PulseMarket fee rules. Cash face-to-face deals have NO fee.
// Held / in-app payments: service fee + secure payment fee, both buyer-paid.
// Seller always keeps the full item price.

export function feeBreakdown(price, method) {
  const p = Math.max(0, Math.round(Number(price) || 0));
  if (method === "cash" || p === 0) {
    return { price: p, serviceFee: 0, secureFee: 0, total: p, method };
  }
  const serviceFee = p < 5000 ? 150 : Math.min(Math.round(p * 0.05), 2000);
  const secureFee = Math.round(p * 0.015) + 100;
  return { price: p, serviceFee, secureFee, total: p + serviceFee + secureFee, method };
}

export function formatNaira(n) {
  return "₦" + Math.round(Number(n) || 0).toLocaleString("en-NG");
}

// Milestone 20 (APP-16): the fee label strings live here, not as
// hardcoded literals in Sell / ListingDetail / Checkout, so the
// three pages can never drift apart (one used to say "5%" while
// another said something else). The amounts themselves still come
// from feeBreakdown() above.
export const FEE_LABELS = {
  serviceFlat: "(flat ₦150 under ₦5,000)",
  servicePercent: "(5%, capped at ₦2,000)",
  secure: "(1.5% + ₦100)",
  cashNoFee: "(cash — no fee)",
};

// Which service-fee label goes with this price: flat ₦150 under
// ₦5,000, otherwise 5% capped at ₦2,000 (same rule as feeBreakdown).
export function serviceFeeLabel(price) {
  return Number(price) < 5000 ? FEE_LABELS.serviceFlat : FEE_LABELS.servicePercent;
}

// Silent Suggest Price: percentage of the new price by condition.
export const SUGGEST_PRICE = {
  New: 1.0,
  "Like New": 0.85,
  Good: 0.7,
  Fair: 0.5,
  Spoilt: 0.2,
};

export function suggestPrice(newPrice, condition) {
  const pct = SUGGEST_PRICE[condition] ?? 0.7;
  const np = Number(newPrice) || 0;
  if (np <= 0) return 0;
  return Math.round(np * pct);
}
