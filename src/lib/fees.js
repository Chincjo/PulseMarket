// PulseMarket fee rules. Cash face-to-face deals have NO fee.
// Held / in-app payments: service fee + secure payment fee, both buyer-paid.
// Seller always keeps the full item price.
//
// Milestone 25 — currency-aware, SAME formula as the database
// (pm_fee_breakdown). NGN constants: flat 150, threshold 5000, cap 2000,
// secure flat 100. For currency C with rate R = NGN per 1 unit of C:
//   flat = max(1, round(150 / R)); threshold = max(1, round(5000 / R));
//   cap = max(1, ceil(2000 / R)); secureFlat = max(1, round(100 / R)).
// Cash or price 0 → 0 / 0. Else service = price < threshold ? flat
// : min(round(price * 0.05), cap); secure = round(price * 0.015) + secureFlat.
// Check: USD @1450 → 1 / 3 / 2 / 1, so $100 held → service 2, secure 3.
import { currencySymbol, ngnRateFor } from "./data";

export function feeBreakdown(price, method, currency = "NGN") {
  const p = Math.max(0, Math.round(Number(price) || 0));
  if (method === "cash" || p === 0) {
    return { price: p, serviceFee: 0, secureFee: 0, total: p, method, currency };
  }
  const R = ngnRateFor(currency);
  const flat = Math.max(1, Math.round(150 / R));
  const threshold = Math.max(1, Math.round(5000 / R));
  const cap = Math.max(1, Math.ceil(2000 / R));
  const secureFlat = Math.max(1, Math.round(100 / R));
  const serviceFee = p < threshold ? flat : Math.min(Math.round(p * 0.05), cap);
  const secureFee = Math.round(p * 0.015) + secureFlat;
  return { price: p, serviceFee, secureFee, total: p + serviceFee + secureFee, method, currency };
}

export function formatMoney(amount, currency = "NGN") {
  const symbol = currencySymbol(currency);
  return symbol + Math.round(Number(amount) || 0).toLocaleString("en-NG");
}

export function formatNaira(n) {
  return formatMoney(n, "NGN");
}

// Milestone 20 (APP-16): the fee label strings live here, not as
// hardcoded literals in Sell / ListingDetail / Checkout, so the
// three pages can never drift apart (one used to say "5%" while
// another said something else). The amounts themselves still come
// from feeBreakdown() above.
//
// Milestone 25: the labels are currency-aware — same strings with
// the right symbol, built from the currency's own flat / threshold /
// cap / secure-flat amounts.
export function feeLabels(currency = "NGN") {
  const R = ngnRateFor(currency);
  const flat = Math.max(1, Math.round(150 / R));
  const threshold = Math.max(1, Math.round(5000 / R));
  const cap = Math.max(1, Math.ceil(2000 / R));
  const secureFlat = Math.max(1, Math.round(100 / R));
  const sym = currencySymbol(currency);
  return {
    serviceFlat: `(flat ${sym}${flat.toLocaleString("en-NG")} under ${sym}${threshold.toLocaleString("en-NG")})`,
    servicePercent: `(5%, capped at ${sym}${cap.toLocaleString("en-NG")})`,
    secure: `(1.5% + ${sym}${secureFlat.toLocaleString("en-NG")})`,
    cashNoFee: "(cash — no fee)",
  };
}

// NGN labels, kept for existing callers that pass no currency.
export const FEE_LABELS = feeLabels("NGN");

// Which service-fee label goes with this price: flat under the
// threshold, otherwise 5% capped (same rule as feeBreakdown).
export function serviceFeeLabel(price, currency = "NGN") {
  const labels = feeLabels(currency);
  const threshold = Math.max(1, Math.round(5000 / ngnRateFor(currency)));
  return Number(price) < threshold ? labels.serviceFlat : labels.servicePercent;
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
