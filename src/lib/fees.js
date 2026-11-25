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
