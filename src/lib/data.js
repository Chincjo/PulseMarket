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
