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

// The answer to a guest add sent again with a key the meal has seen, for
// the same host and flag (MealsController#seen_guest_key_answer): that add
// was written before, and nothing more was added now. `guest` is the
// guest it made, as stored now, or null when it was removed since, or
// given to another host or another meal. Mirrors GuestReplayedSerializer.
export interface GuestReplayed {
  message: string;
  type: "replayed";
  guest: Guest | null;
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

// The answer to PATCH /api/v1/meals/:id/bills (MealsController#update_bills,
// docs/adr/0009-bills-saves-send-edits.md). `type` says which answer it is:
//
//   none        200: the edits were written. On a 400 or a 422 nothing
//               was written; on a 409 nothing was written either, and
//               the same save may be sent again with the same key.
//   "replayed"  200: this key's save was written before, and nothing
//               more was written now.
//   "warning"   200: the edits were written, and the message is advice
//               about the rotation (ThirdCookWarning).
//   "stale"     409: a bill an edit was built on has changed since the
//               page read it. Nothing was written.
//   "outdated"  400: the body used the format from before #135, which
//               this page never sends. Nothing was written.
//
// `bills` holds the meal's bills as stored, in the shape of the meal
// form's: on a 200, read right after the save's writes (on a replayed
// 200, as they are now), on the warning, and on the stale 409.
export interface BillsAck {
  message: string;
  type?: "warning" | "replayed" | "stale" | "outdated";
  bills?: MealFormBill[];
}
