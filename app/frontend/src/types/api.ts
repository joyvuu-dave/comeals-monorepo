// Source-of-truth types for what `/api/v1/*` returns.
//
// Mirrors `app/serializers/*.rb`. When a serializer changes, the matching
// interface here MUST change in the same PR — that discipline is what makes
// the boundary worth typing. See docs/adr/0001-typescript-at-the-api-boundary.md.

// Money values cross the wire as strings (Rails serializes BigDecimal as JSON
// string, e.g. "12.34000000"). The brand prevents accidental Number arithmetic
// like `bill.amount + 1` — which would yield "12.340000001" and silently corrupt
// money. To compute on a MoneyString, parse it explicitly (BigNumber, etc.) at
// the point of use.
declare const moneyBrand: unique symbol;
export type MoneyString = string & { readonly [moneyBrand]: true };

// ---------------------------------------------------------------------------
// MealForm — response of GET /api/v1/meals/:id/cooks
// Mirrors MealFormSerializer (app/serializers/meal_form_serializer.rb).
// ---------------------------------------------------------------------------

export interface MealFormBill {
  resident_id: number;
  amount: MoneyString;
  no_cost: boolean;
}

export interface MealFormResident {
  id: number;
  meal_id: number;
  // "102 - Jane": the unit prefix tells two Janes apart in lists.
  name: string;
  // "Jane": for sentences (confirm questions).
  short_name: string;
  attending: boolean;
  attending_at: string | null;
  late: boolean;
  vegetarian: boolean;
  can_cook: boolean;
  active: boolean;
}

export interface MealFormGuest {
  id: number;
  meal_id: number;
  resident_id: number;
  vegetarian: boolean;
  created_at: string;
}

export interface MealForm {
  id: number;
  description: string;
  max: number | null;
  closed: boolean;
  closed_at: string | null;
  date: string;
  reconciled: boolean;
  next_id: number;
  prev_id: number;
  bills: MealFormBill[];
  residents: MealFormResident[];
  guests: MealFormGuest[];
}

// ---------------------------------------------------------------------------
// Single-record creates
// ---------------------------------------------------------------------------

// Response of POST /api/v1/meals/:meal_id/residents/:resident_id
// Mirrors MealResidentSerializer.
export interface MealResident {
  id: number;
  meal_id: number;
  resident_id: number;
  late: boolean;
  vegetarian: boolean;
  created_at: string;
}

// Response of POST /api/v1/meals/:meal_id/residents/:resident_id/guests
// Mirrors GuestSerializer.
export interface Guest {
  id: number;
  meal_id: number;
  resident_id: number;
  vegetarian: boolean;
  created_at: string;
}

// ---------------------------------------------------------------------------
// Calendar edit forms — the record a modal edits
// ---------------------------------------------------------------------------

// Response of GET /api/v1/events/:id
// Mirrors EventFormSerializer. The form reads all but the timestamps.
export interface EventForm {
  id: number;
  title: string;
  description: string;
  start_date: string;
  // null for an all-day event.
  end_date: string | null;
  allday: boolean;
  created_at: string;
  updated_at: string;
}

// Response of GET /api/v1/common-house-reservations/:id, which is
// { event: CommonHouseReservationForm }.
// Mirrors CommonHouseReservationFormSerializer.
export interface CommonHouseReservationForm {
  id: number;
  resident_id: number;
  title: string | null;
  start_date: string;
  end_date: string;
}

// Response of GET /api/v1/guest-room-reservations/:id, which is
// { event: GuestRoomReservationForm }.
// Mirrors GuestRoomReservationFormSerializer.
export interface GuestRoomReservationForm {
  id: number;
  resident_id: number;
  // "YYYY-MM-DD"
  date: string;
}

// ---------------------------------------------------------------------------
// Acknowledgements
// ---------------------------------------------------------------------------

export interface Ack {
  message: string;
}

// update_bills returns `type: "warning"` on cook-scheduling guard violations
// (alongside HTTP 400). Existing JS branches on this discriminator.
// `bills` is present whenever the write happened — the 200, and the warning
// 400 (which also persists) — and holds the rows as stored, so the client
// can reconcile its display with the ledger. Plain-error 400s carry only
// `message`.
export interface BillsAck {
  message: string;
  type?: "warning";
  bills?: MealFormBill[];
}
