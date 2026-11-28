export const UNIVERSITIES = [
  { name: "University of Port Harcourt", state: "Rivers" },
  { name: "University of Lagos", state: "Lagos" },
  { name: "University of Ibadan", state: "Oyo" },
  { name: "Obafemi Awolowo University", state: "Osun" },
  { name: "University of Nigeria, Nsukka", state: "Enugu" },
  { name: "Ahmadu Bello University", state: "Kaduna" },
  { name: "University of Benin", state: "Edo" },
  { name: "University of Ilorin", state: "Kwara" },
  { name: "Lagos State University", state: "Lagos" },
  { name: "Federal University of Technology, Akure", state: "Ondo" },
  { name: "Federal University of Technology, Owerri", state: "Imo" },
  { name: "Federal University of Technology, Minna", state: "Niger" },
  { name: "Nnamdi Azikiwe University", state: "Anambra" },
  { name: "University of Calabar", state: "Cross River" },
  { name: "University of Jos", state: "Plateau" },
  { name: "Bayero University Kano", state: "Kano" },
  { name: "Rivers State University", state: "Rivers" },
  { name: "Delta State University", state: "Delta" },
  { name: "Enugu State University of Science and Technology", state: "Enugu" },
  { name: "Covenant University", state: "Ogun" },
];

export const UNIVERSITY_NAMES = UNIVERSITIES.map((u) => u.name);

export const STATES = [...new Set(UNIVERSITIES.map((u) => u.state))].sort();

// The state a university sits in — a listing's state comes from the
// seller's verified university, never from a free choice.
export function universityState(universityName) {
  return UNIVERSITIES.find((u) => u.name === universityName)?.state || "";
}

export const CATEGORIES = [
  "Phones & gadgets",
  "Fashion",
  "Books & study",
  "Electronics",
  "Home & hostel",
  "Beauty & care",
  "Sports & fitness",
  "Food & snacks",
  "Services",
  "Tickets",
  "Vehicles",
  "Other",
];

export const CONDITIONS = ["New", "Like New", "Good", "Fair", "Spoilt"];

export const SAFE_MEETUP_SPOTS = [
  "University main gate",
  "Student centre / SUG building",
  "Campus library entrance",
  "Faculty building lobby",
  "Hostel common area (daytime)",
];

// Shipping zone estimates (from the PulseMarket plan). The exact fee is
// confirmed at checkout once real payments go live.
export const SHIPPING_ZONES = [
  { label: "Same state", fee: 1500 },
  { label: "Neighbouring state", fee: 2500 },
  { label: "Far state", fee: "3,500–4,500" },
];

// Milestone 25 — every country, its currency and a STATIC reference
// rate (ngnRate = NGN per 1 unit of that currency, Nov 2026). These
// rates are estimates only — they are never presented as live rates,
// and every conversion the app shows is labelled an estimate.
// A country not in this table defaults to USD (see currencyForCountry).
export const COUNTRIES = [
  {
    code: "AF",
    name: "Afghanistan",
    currency: "AFN",
    symbol: "؋",
    ngnRate: 21
  },
  {
    code: "AL",
    name: "Albania",
    currency: "ALL",
    symbol: "L",
    ngnRate: 17
  },
  {
    code: "DZ",
    name: "Algeria",
    currency: "DZD",
    symbol: "دج",
    ngnRate: 11
  },
  {
    code: "AD",
    name: "Andorra",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "AO",
    name: "Angola",
    currency: "AOA",
    symbol: "Kz",
    ngnRate: 1.6
  },
  {
    code: "AG",
    name: "Antigua and Barbuda",
    currency: "XCD",
    symbol: "$",
    ngnRate: 535
  },
  {
    code: "AR",
    name: "Argentina",
    currency: "ARS",
    symbol: "$",
    ngnRate: 1.0
  },
  {
    code: "AM",
    name: "Armenia",
    currency: "AMD",
    symbol: "֏",
    ngnRate: 3.8
  },
  {
    code: "AW",
    name: "Aruba",
    currency: "AWG",
    symbol: "ƒ",
    ngnRate: 810
  },
  {
    code: "AU",
    name: "Australia",
    currency: "AUD",
    symbol: "A$",
    ngnRate: 940
  },
  {
    code: "AT",
    name: "Austria",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "AZ",
    name: "Azerbaijan",
    currency: "AZN",
    symbol: "₼",
    ngnRate: 850
  },
  {
    code: "BS",
    name: "Bahamas",
    currency: "BSD",
    symbol: "$",
    ngnRate: 1450
  },
  {
    code: "BH",
    name: "Bahrain",
    currency: "BHD",
    symbol: "ب.د",
    ngnRate: 3850
  },
  {
    code: "BD",
    name: "Bangladesh",
    currency: "BDT",
    symbol: "৳",
    ngnRate: 12
  },
  {
    code: "BB",
    name: "Barbados",
    currency: "BBD",
    symbol: "Bds$",
    ngnRate: 725
  },
  {
    code: "BY",
    name: "Belarus",
    currency: "BYN",
    symbol: "Br",
    ngnRate: 420
  },
  {
    code: "BE",
    name: "Belgium",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "BZ",
    name: "Belize",
    currency: "BZD",
    symbol: "BZ$",
    ngnRate: 720
  },
  {
    code: "BJ",
    name: "Benin",
    currency: "XOF",
    symbol: "CFA",
    ngnRate: 2.9
  },
  {
    code: "BT",
    name: "Bhutan",
    currency: "BTN",
    symbol: "Nu",
    ngnRate: 16.5
  },
  {
    code: "BO",
    name: "Bolivia",
    currency: "BOB",
    symbol: "Bs",
    ngnRate: 210
  },
  {
    code: "BA",
    name: "Bosnia and Herzegovina",
    currency: "BAM",
    symbol: "KM",
    ngnRate: 860
  },
  {
    code: "BW",
    name: "Botswana",
    currency: "BWP",
    symbol: "P",
    ngnRate: 105
  },
  {
    code: "BR",
    name: "Brazil",
    currency: "BRL",
    symbol: "R$",
    ngnRate: 270
  },
  {
    code: "BN",
    name: "Brunei",
    currency: "BND",
    symbol: "B$",
    ngnRate: 1110
  },
  {
    code: "BG",
    name: "Bulgaria",
    currency: "BGN",
    symbol: "лв",
    ngnRate: 860
  },
  {
    code: "BF",
    name: "Burkina Faso",
    currency: "XOF",
    symbol: "CFA",
    ngnRate: 2.9
  },
  {
    code: "BI",
    name: "Burundi",
    currency: "BIF",
    symbol: "FBu",
    ngnRate: 0.5
  },
  {
    code: "CV",
    name: "Cabo Verde",
    currency: "CVE",
    symbol: "$",
    ngnRate: 14
  },
  {
    code: "KH",
    name: "Cambodia",
    currency: "KHR",
    symbol: "៛",
    ngnRate: 0.36
  },
  {
    code: "CM",
    name: "Cameroon",
    currency: "XAF",
    symbol: "FCFA",
    ngnRate: 2.9
  },
  {
    code: "CA",
    name: "Canada",
    currency: "CAD",
    symbol: "C$",
    ngnRate: 1040
  },
  {
    code: "KY",
    name: "Cayman Islands",
    currency: "KYD",
    symbol: "$",
    ngnRate: 1740
  },
  {
    code: "CF",
    name: "Central African Republic",
    currency: "XAF",
    symbol: "FCFA",
    ngnRate: 2.9
  },
  {
    code: "TD",
    name: "Chad",
    currency: "XAF",
    symbol: "FCFA",
    ngnRate: 2.9
  },
  {
    code: "CL",
    name: "Chile",
    currency: "CLP",
    symbol: "$",
    ngnRate: 1.5
  },
  {
    code: "CN",
    name: "China",
    currency: "CNY",
    symbol: "¥",
    ngnRate: 200
  },
  {
    code: "CO",
    name: "Colombia",
    currency: "COP",
    symbol: "$",
    ngnRate: 380
  },
  {
    code: "KM",
    name: "Comoros",
    currency: "KMF",
    symbol: "CF",
    ngnRate: 3.5
  },
  {
    code: "CG",
    name: "Congo",
    currency: "XAF",
    symbol: "FCFA",
    ngnRate: 2.9
  },
  {
    code: "CR",
    name: "Costa Rica",
    currency: "CRC",
    symbol: "₡",
    ngnRate: 2.9
  },
  {
    code: "HR",
    name: "Croatia",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "CU",
    name: "Cuba",
    currency: "CUP",
    symbol: "$",
    ngnRate: 60
  },
  {
    code: "CY",
    name: "Cyprus",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "CZ",
    name: "Czech Republic",
    currency: "CZK",
    symbol: "Kč",
    ngnRate: 68
  },
  {
    code: "CI",
    name: "Côte d'Ivoire",
    currency: "XOF",
    symbol: "CFA",
    ngnRate: 2.9
  },
  {
    code: "CD",
    name: "DR Congo",
    currency: "CDF",
    symbol: "FC",
    ngnRate: 0.5
  },
  {
    code: "DK",
    name: "Denmark",
    currency: "DKK",
    symbol: "kr",
    ngnRate: 225
  },
  {
    code: "DJ",
    name: "Djibouti",
    currency: "DJF",
    symbol: "Fdj",
    ngnRate: 8.2
  },
  {
    code: "DM",
    name: "Dominica",
    currency: "XCD",
    symbol: "$",
    ngnRate: 535
  },
  {
    code: "DO",
    name: "Dominican Republic",
    currency: "DOP",
    symbol: "RD$",
    ngnRate: 23
  },
  {
    code: "EC",
    name: "Ecuador",
    currency: "USD",
    symbol: "$",
    ngnRate: 1450
  },
  {
    code: "EG",
    name: "Egypt",
    currency: "EGP",
    symbol: "E£",
    ngnRate: 30
  },
  {
    code: "SV",
    name: "El Salvador",
    currency: "USD",
    symbol: "$",
    ngnRate: 1450
  },
  {
    code: "GQ",
    name: "Equatorial Guinea",
    currency: "XAF",
    symbol: "FCFA",
    ngnRate: 2.9
  },
  {
    code: "ER",
    name: "Eritrea",
    currency: "ERN",
    symbol: "Nfk",
    ngnRate: 97
  },
  {
    code: "EE",
    name: "Estonia",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "SZ",
    name: "Eswatini",
    currency: "SZL",
    symbol: "L",
    ngnRate: 84
  },
  {
    code: "ET",
    name: "Ethiopia",
    currency: "ETB",
    symbol: "Br",
    ngnRate: 10
  },
  {
    code: "FJ",
    name: "Fiji",
    currency: "FJD",
    symbol: "FJ$",
    ngnRate: 650
  },
  {
    code: "FI",
    name: "Finland",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "FR",
    name: "France",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "GA",
    name: "Gabon",
    currency: "XAF",
    symbol: "FCFA",
    ngnRate: 2.9
  },
  {
    code: "GM",
    name: "Gambia",
    currency: "GMD",
    symbol: "D",
    ngnRate: 20
  },
  {
    code: "GE",
    name: "Georgia",
    currency: "GEL",
    symbol: "₾",
    ngnRate: 530
  },
  {
    code: "DE",
    name: "Germany",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "GH",
    name: "Ghana",
    currency: "GHS",
    symbol: "₵",
    ngnRate: 90
  },
  {
    code: "GR",
    name: "Greece",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "GD",
    name: "Grenada",
    currency: "XCD",
    symbol: "$",
    ngnRate: 535
  },
  {
    code: "GN",
    name: "Guinea",
    currency: "GNF",
    symbol: "FG",
    ngnRate: 0.17
  },
  {
    code: "GW",
    name: "Guinea-Bissau",
    currency: "XOF",
    symbol: "CFA",
    ngnRate: 2.9
  },
  {
    code: "GY",
    name: "Guyana",
    currency: "GYD",
    symbol: "G$",
    ngnRate: 7
  },
  {
    code: "HT",
    name: "Haiti",
    currency: "HTG",
    symbol: "G",
    ngnRate: 11
  },
  {
    code: "HN",
    name: "Honduras",
    currency: "HNL",
    symbol: "L",
    ngnRate: 55
  },
  {
    code: "HK",
    name: "Hong Kong",
    currency: "HKD",
    symbol: "HK$",
    ngnRate: 186
  },
  {
    code: "HU",
    name: "Hungary",
    currency: "HUF",
    symbol: "Ft",
    ngnRate: 4.3
  },
  {
    code: "IS",
    name: "Iceland",
    currency: "ISK",
    symbol: "kr",
    ngnRate: 12
  },
  {
    code: "IN",
    name: "India",
    currency: "INR",
    symbol: "₹",
    ngnRate: 16.5
  },
  {
    code: "ID",
    name: "Indonesia",
    currency: "IDR",
    symbol: "Rp",
    ngnRate: 0.09
  },
  {
    code: "IR",
    name: "Iran",
    currency: "IRR",
    symbol: "﷼",
    ngnRate: 0.03
  },
  {
    code: "IQ",
    name: "Iraq",
    currency: "IQD",
    symbol: "ع.د",
    ngnRate: 1.1
  },
  {
    code: "IE",
    name: "Ireland",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "IL",
    name: "Israel",
    currency: "ILS",
    symbol: "₪",
    ngnRate: 440
  },
  {
    code: "IT",
    name: "Italy",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "JM",
    name: "Jamaica",
    currency: "JMD",
    symbol: "J$",
    ngnRate: 9.3
  },
  {
    code: "JP",
    name: "Japan",
    currency: "JPY",
    symbol: "¥",
    ngnRate: 9.5
  },
  {
    code: "JO",
    name: "Jordan",
    currency: "JOD",
    symbol: "JD",
    ngnRate: 2040
  },
  {
    code: "KZ",
    name: "Kazakhstan",
    currency: "KZT",
    symbol: "₸",
    ngnRate: 2.8
  },
  {
    code: "KE",
    name: "Kenya",
    currency: "KES",
    symbol: "KSh",
    ngnRate: 11
  },
  {
    code: "KI",
    name: "Kiribati",
    currency: "AUD",
    symbol: "A$",
    ngnRate: 940
  },
  {
    code: "XK",
    name: "Kosovo",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "KW",
    name: "Kuwait",
    currency: "KWD",
    symbol: "KD",
    ngnRate: 4700
  },
  {
    code: "KG",
    name: "Kyrgyzstan",
    currency: "KGS",
    symbol: "с",
    ngnRate: 17
  },
  {
    code: "LA",
    name: "Laos",
    currency: "LAK",
    symbol: "₭",
    ngnRate: 0.07
  },
  {
    code: "LV",
    name: "Latvia",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "LB",
    name: "Lebanon",
    currency: "LBP",
    symbol: "£",
    ngnRate: 0.016
  },
  {
    code: "LS",
    name: "Lesotho",
    currency: "LSL",
    symbol: "L",
    ngnRate: 84
  },
  {
    code: "LR",
    name: "Liberia",
    currency: "LRD",
    symbol: "L$",
    ngnRate: 7.5
  },
  {
    code: "LY",
    name: "Libya",
    currency: "LYD",
    symbol: "LD",
    ngnRate: 290
  },
  {
    code: "LI",
    name: "Liechtenstein",
    currency: "CHF",
    symbol: "CHF",
    ngnRate: 1800
  },
  {
    code: "LT",
    name: "Lithuania",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "LU",
    name: "Luxembourg",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "MO",
    name: "Macau",
    currency: "MOP",
    symbol: "MOP$",
    ngnRate: 180
  },
  {
    code: "MG",
    name: "Madagascar",
    currency: "MGA",
    symbol: "Ar",
    ngnRate: 0.33
  },
  {
    code: "MW",
    name: "Malawi",
    currency: "MWK",
    symbol: "MK",
    ngnRate: 0.84
  },
  {
    code: "MY",
    name: "Malaysia",
    currency: "MYR",
    symbol: "RM",
    ngnRate: 345
  },
  {
    code: "MV",
    name: "Maldives",
    currency: "MVR",
    symbol: "Rf",
    ngnRate: 94
  },
  {
    code: "ML",
    name: "Mali",
    currency: "XOF",
    symbol: "CFA",
    ngnRate: 2.9
  },
  {
    code: "MT",
    name: "Malta",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "MH",
    name: "Marshall Islands",
    currency: "USD",
    symbol: "$",
    ngnRate: 1450
  },
  {
    code: "MR",
    name: "Mauritania",
    currency: "MRU",
    symbol: "UM",
    ngnRate: 36
  },
  {
    code: "MU",
    name: "Mauritius",
    currency: "MUR",
    symbol: "₨",
    ngnRate: 31
  },
  {
    code: "MX",
    name: "Mexico",
    currency: "MXN",
    symbol: "MX$",
    ngnRate: 79
  },
  {
    code: "FM",
    name: "Micronesia",
    currency: "USD",
    symbol: "$",
    ngnRate: 1450
  },
  {
    code: "MD",
    name: "Moldova",
    currency: "MDL",
    symbol: "L",
    ngnRate: 85
  },
  {
    code: "MC",
    name: "Monaco",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "MN",
    name: "Mongolia",
    currency: "MNT",
    symbol: "₮",
    ngnRate: 0.4
  },
  {
    code: "ME",
    name: "Montenegro",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "MA",
    name: "Morocco",
    currency: "MAD",
    symbol: "DH",
    ngnRate: 145
  },
  {
    code: "MZ",
    name: "Mozambique",
    currency: "MZN",
    symbol: "MT",
    ngnRate: 23
  },
  {
    code: "MM",
    name: "Myanmar",
    currency: "MMK",
    symbol: "K",
    ngnRate: 0.7
  },
  {
    code: "NA",
    name: "Namibia",
    currency: "NAD",
    symbol: "N$",
    ngnRate: 84
  },
  {
    code: "NR",
    name: "Nauru",
    currency: "AUD",
    symbol: "A$",
    ngnRate: 940
  },
  {
    code: "NP",
    name: "Nepal",
    currency: "NPR",
    symbol: "₨",
    ngnRate: 10
  },
  {
    code: "NL",
    name: "Netherlands",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "NZ",
    name: "New Zealand",
    currency: "NZD",
    symbol: "NZ$",
    ngnRate: 830
  },
  {
    code: "NI",
    name: "Nicaragua",
    currency: "NIO",
    symbol: "C$",
    ngnRate: 40
  },
  {
    code: "NE",
    name: "Niger",
    currency: "XOF",
    symbol: "CFA",
    ngnRate: 2.9
  },
  {
    code: "NG",
    name: "Nigeria",
    currency: "NGN",
    symbol: "₦",
    ngnRate: 1
  },
  {
    code: "MK",
    name: "North Macedonia",
    currency: "MKD",
    symbol: "ден",
    ngnRate: 27
  },
  {
    code: "NO",
    name: "Norway",
    currency: "NOK",
    symbol: "kr",
    ngnRate: 143
  },
  {
    code: "OM",
    name: "Oman",
    currency: "OMR",
    symbol: "ر.ع.",
    ngnRate: 3770
  },
  {
    code: "PK",
    name: "Pakistan",
    currency: "PKR",
    symbol: "₨",
    ngnRate: 5.2
  },
  {
    code: "PW",
    name: "Palau",
    currency: "USD",
    symbol: "$",
    ngnRate: 1450
  },
  {
    code: "PS",
    name: "Palestine",
    currency: "ILS",
    symbol: "₪",
    ngnRate: 440
  },
  {
    code: "PA",
    name: "Panama",
    currency: "PAB",
    symbol: "B/.",
    ngnRate: 1450
  },
  {
    code: "PG",
    name: "Papua New Guinea",
    currency: "PGK",
    symbol: "K",
    ngnRate: 350
  },
  {
    code: "PY",
    name: "Paraguay",
    currency: "PYG",
    symbol: "₲",
    ngnRate: 0.2
  },
  {
    code: "PE",
    name: "Peru",
    currency: "PEN",
    symbol: "S/",
    ngnRate: 430
  },
  {
    code: "PH",
    name: "Philippines",
    currency: "PHP",
    symbol: "₱",
    ngnRate: 25
  },
  {
    code: "PL",
    name: "Poland",
    currency: "PLN",
    symbol: "zł",
    ngnRate: 400
  },
  {
    code: "PT",
    name: "Portugal",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "QA",
    name: "Qatar",
    currency: "QAR",
    symbol: "QR",
    ngnRate: 398
  },
  {
    code: "RO",
    name: "Romania",
    currency: "RON",
    symbol: "lei",
    ngnRate: 340
  },
  {
    code: "RU",
    name: "Russia",
    currency: "RUB",
    symbol: "₽",
    ngnRate: 18
  },
  {
    code: "RW",
    name: "Rwanda",
    currency: "RWF",
    symbol: "FRw",
    ngnRate: 1.0
  },
  {
    code: "KN",
    name: "Saint Kitts and Nevis",
    currency: "XCD",
    symbol: "$",
    ngnRate: 535
  },
  {
    code: "LC",
    name: "Saint Lucia",
    currency: "XCD",
    symbol: "$",
    ngnRate: 535
  },
  {
    code: "VC",
    name: "Saint Vincent and the Grenadines",
    currency: "XCD",
    symbol: "$",
    ngnRate: 535
  },
  {
    code: "WS",
    name: "Samoa",
    currency: "WST",
    symbol: "WS$",
    ngnRate: 520
  },
  {
    code: "SM",
    name: "San Marino",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "SA",
    name: "Saudi Arabia",
    currency: "SAR",
    symbol: "﷼",
    ngnRate: 387
  },
  {
    code: "SN",
    name: "Senegal",
    currency: "XOF",
    symbol: "CFA",
    ngnRate: 2.9
  },
  {
    code: "RS",
    name: "Serbia",
    currency: "RSD",
    symbol: "дин",
    ngnRate: 14
  },
  {
    code: "SC",
    name: "Seychelles",
    currency: "SCR",
    symbol: "₨",
    ngnRate: 100
  },
  {
    code: "SL",
    name: "Sierra Leone",
    currency: "SLE",
    symbol: "Le",
    ngnRate: 63
  },
  {
    code: "SG",
    name: "Singapore",
    currency: "SGD",
    symbol: "S$",
    ngnRate: 1110
  },
  {
    code: "SK",
    name: "Slovakia",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "SI",
    name: "Slovenia",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "SB",
    name: "Solomon Islands",
    currency: "SBD",
    symbol: "SI$",
    ngnRate: 175
  },
  {
    code: "SO",
    name: "Somalia",
    currency: "SOS",
    symbol: "Sh",
    ngnRate: 0.025
  },
  {
    code: "ZA",
    name: "South Africa",
    currency: "ZAR",
    symbol: "R",
    ngnRate: 84
  },
  {
    code: "KR",
    name: "South Korea",
    currency: "KRW",
    symbol: "₩",
    ngnRate: 1.0
  },
  {
    code: "SS",
    name: "South Sudan",
    currency: "SSP",
    symbol: "£",
    ngnRate: 0.3
  },
  {
    code: "ES",
    name: "Spain",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "LK",
    name: "Sri Lanka",
    currency: "LKR",
    symbol: "₨",
    ngnRate: 4.8
  },
  {
    code: "SD",
    name: "Sudan",
    currency: "SDG",
    symbol: "£",
    ngnRate: 2.4
  },
  {
    code: "SR",
    name: "Suriname",
    currency: "SRD",
    symbol: "Sr$",
    ngnRate: 39
  },
  {
    code: "SE",
    name: "Sweden",
    currency: "SEK",
    symbol: "kr",
    ngnRate: 150
  },
  {
    code: "CH",
    name: "Switzerland",
    currency: "CHF",
    symbol: "CHF",
    ngnRate: 1800
  },
  {
    code: "SY",
    name: "Syria",
    currency: "SYP",
    symbol: "£",
    ngnRate: 0.11
  },
  {
    code: "ST",
    name: "São Tomé and Príncipe",
    currency: "STN",
    symbol: "Db",
    ngnRate: 60
  },
  {
    code: "TW",
    name: "Taiwan",
    currency: "TWD",
    symbol: "NT$",
    ngnRate: 47
  },
  {
    code: "TJ",
    name: "Tajikistan",
    currency: "TJS",
    symbol: "SM",
    ngnRate: 150
  },
  {
    code: "TZ",
    name: "Tanzania",
    currency: "TZS",
    symbol: "TSh",
    ngnRate: 0.6
  },
  {
    code: "TH",
    name: "Thailand",
    currency: "THB",
    symbol: "฿",
    ngnRate: 45
  },
  {
    code: "TL",
    name: "Timor-Leste",
    currency: "USD",
    symbol: "$",
    ngnRate: 1450
  },
  {
    code: "TG",
    name: "Togo",
    currency: "XOF",
    symbol: "CFA",
    ngnRate: 2.9
  },
  {
    code: "TO",
    name: "Tonga",
    currency: "TOP",
    symbol: "T$",
    ngnRate: 610
  },
  {
    code: "TT",
    name: "Trinidad and Tobago",
    currency: "TTD",
    symbol: "TT$",
    ngnRate: 215
  },
  {
    code: "TN",
    name: "Tunisia",
    currency: "TND",
    symbol: "DT",
    ngnRate: 500
  },
  {
    code: "TM",
    name: "Turkmenistan",
    currency: "TMT",
    symbol: "T",
    ngnRate: 415
  },
  {
    code: "TV",
    name: "Tuvalu",
    currency: "AUD",
    symbol: "A$",
    ngnRate: 940
  },
  {
    code: "TR",
    name: "Türkiye",
    currency: "TRY",
    symbol: "₺",
    ngnRate: 35
  },
  {
    code: "UG",
    name: "Uganda",
    currency: "UGX",
    symbol: "USh",
    ngnRate: 0.4
  },
  {
    code: "UA",
    name: "Ukraine",
    currency: "UAH",
    symbol: "₴",
    ngnRate: 35
  },
  {
    code: "AE",
    name: "United Arab Emirates",
    currency: "AED",
    symbol: "د.إ",
    ngnRate: 395
  },
  {
    code: "GB",
    name: "United Kingdom",
    currency: "GBP",
    symbol: "£",
    ngnRate: 1950
  },
  {
    code: "US",
    name: "United States",
    currency: "USD",
    symbol: "$",
    ngnRate: 1450
  },
  {
    code: "UY",
    name: "Uruguay",
    currency: "UYU",
    symbol: "$U",
    ngnRate: 36
  },
  {
    code: "UZ",
    name: "Uzbekistan",
    currency: "UZS",
    symbol: "so'm",
    ngnRate: 0.12
  },
  {
    code: "VU",
    name: "Vanuatu",
    currency: "VUV",
    symbol: "VT",
    ngnRate: 12
  },
  {
    code: "VA",
    name: "Vatican City",
    currency: "EUR",
    symbol: "€",
    ngnRate: 1680
  },
  {
    code: "VE",
    name: "Venezuela",
    currency: "VES",
    symbol: "Bs",
    ngnRate: 8.5
  },
  {
    code: "VN",
    name: "Vietnam",
    currency: "VND",
    symbol: "₫",
    ngnRate: 0.055
  },
  {
    code: "YE",
    name: "Yemen",
    currency: "YER",
    symbol: "﷼",
    ngnRate: 6
  },
  {
    code: "ZM",
    name: "Zambia",
    currency: "ZMW",
    symbol: "ZK",
    ngnRate: 60
  },
  {
    code: "ZW",
    name: "Zimbabwe",
    currency: "ZWL",
    symbol: "Z$",
    ngnRate: 0.06
  }
];

export const COUNTRY_NAMES = COUNTRIES.map((c) => c.name);

export function countryByCode(code) {
  return COUNTRIES.find((c) => c.code === code) || null;
}

export function countryByName(name) {
  return COUNTRIES.find((c) => c.name === name) || null;
}

// Currency for a country code. Any unmapped country defaults to USD.
export function currencyForCountry(code) {
  return countryByCode(code)?.currency || "USD";
}

export function currencySymbol(currency) {
  const row = COUNTRIES.find((c) => c.currency === currency);
  return row?.symbol || (currency === "NGN" ? "₦" : currency + " ");
}

// NGN per 1 unit of a currency (static reference rate, estimate).
// Unknown currencies fall back to the USD rate — never null, never 0.
export function ngnRateFor(currency) {
  const row = COUNTRIES.find((c) => c.currency === currency);
  return row?.ngnRate || 1450;
}

// Approximate conversion between two currencies, through the static
// NGN reference rates. Always an estimate — callers label it as one.
export function convertApprox(amount, fromCurrency, toCurrency) {
  const from = ngnRateFor(fromCurrency);
  const to = ngnRateFor(toCurrency);
  if (!from || !to) return Math.round(Number(amount) || 0);
  return Math.round(((Number(amount) || 0) * from) / to);
}

// Milestone 25 — safe meetup spots for ordinary (non-student) users.
// Students keep the campus-specific SAFE_MEETUP_SPOTS above.
export const GENERIC_MEETUP_SPOTS = [
  "Police station",
  "Bank branch",
  "Shopping mall",
  "Busy public place (daytime only)",
];
