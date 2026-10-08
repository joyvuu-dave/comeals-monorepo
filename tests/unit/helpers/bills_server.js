// A stand-in for the server's side of the meal page, for store tests
// that follow a story through several bills saves: the meal form (GET
// /meals/:id/cooks) and the bills endpoint (PATCH /meals/:id/bills).
//
// It applies a save the way BillsPayload and MealsController#save_bills
// do (docs/adr/0009-bills-saves-send-edits.md): each edit is checked
// against the stored bill of its cook, one stale edit refuses the whole
// save with a 409 of type "stale", and a key it has kept answers as
// "replayed" (the same edits) or 422 (other edits). It does not check
// the shape of a request: the request specs do that for the real one.
//
// Use it with the shared axios mock:
//
//   const server = billsServer(axios);
//   server.install();
//
// Every bills save waits until the test answers it (answerSave,
// failSave, loseAnswer), oldest first. A meal fetch is answered at once,
// with what the server has when the fetch arrives.
import { vi } from "vitest";
import { sameAmount } from "../../../app/frontend/src/helpers/money";

export const BOB = 11;
export const CAROL = 12;

export function residentRow(id, name, mealId, overrides = {}) {
  return {
    id,
    meal_id: mealId,
    name,
    short_name: name,
    attending: false,
    attending_at: null,
    late: false,
    vegetarian: false,
    can_cook: true,
    active: true,
    ...overrides,
  };
}

export function mealIdOf(url) {
  return Number(url.match(/meals\/(\d+)\//)[1]);
}

export function billsServer(axios) {
  // The bills the server has, by meal id, then by cook id:
  // { amount, no_cost }. Meal 1 starts with Bob at $0.
  const stored = {
    1: { [BOB]: { amount: "0.0", no_cost: false } },
    2: {},
    3: {},
  };
  // The residents list of every meal form. A stored bill whose cook is
  // not here is one the page cannot show (#91).
  const residents = [
    [BOB, "Bob"],
    [CAROL, "Carol"],
  ];
  // The key of each save the server wrote, by meal id: key -> edits.
  const keys = {};
  // Bills saves sent and not answered yet, oldest first.
  const saves = [];

  function rows(mealId) {
    return Object.entries(stored[mealId]).map(([residentId, bill]) => ({
      resident_id: Number(residentId),
      ...bill,
    }));
  }

  function mealForm(mealId) {
    return {
      id: mealId,
      date: `2023-06-${14 + mealId}`,
      description: "",
      closed: false,
      closed_at: null,
      reconciled: false,
      max: null,
      next_id: mealId,
      prev_id: mealId,
      residents: residents.map(([id, name]) => residentRow(id, name, mealId)),
      guests: [],
      bills: rows(mealId),
    };
  }

  // A side of an edit is the stored bill: both missing, or the same
  // amount as a number and the same no_cost.
  function matches(side, bill) {
    if (side === undefined) return bill === undefined;
    return (
      bill !== undefined &&
      sameAmount(side.amount, bill.amount) &&
      side.no_cost === bill.no_cost
    );
  }

  // The answer the real server gives this save, writing the bills when
  // it would.
  function apply(config) {
    const mealId = mealIdOf(config.url);
    const key = config.headers["Idempotency-Key"];
    const edits = JSON.stringify(config.data.edits);
    keys[mealId] ??= new Map();
    if (keys[mealId].has(key)) {
      return keys[mealId].get(key) === edits
        ? {
            status: 200,
            data: {
              message:
                "This save was already made, so nothing more was written.",
              type: "replayed",
              bills: rows(mealId),
            },
          }
        : {
            status: 422,
            data: {
              message:
                "This Idempotency-Key was already used for a different save. Nothing was saved. Send a new key with each save.",
            },
          };
    }
    const bills = stored[mealId];
    const stale = config.data.edits.filter(
      (edit) =>
        !matches(edit.to, bills[edit.resident_id]) &&
        !matches(edit.from, bills[edit.resident_id]),
    );
    if (stale.length > 0) {
      return {
        status: 409,
        data: {
          message:
            "Nothing was saved, because this meal changed after you loaded it: " +
            stale.map((edit) => `cook #${edit.resident_id}`).join(" and ") +
            ". Check the cooks and costs, then enter your change again.",
          type: "stale",
          bills: rows(mealId),
        },
      };
    }
    config.data.edits.forEach((edit) => {
      if (edit.to === undefined) {
        delete bills[edit.resident_id];
      } else {
        bills[edit.resident_id] = {
          amount: edit.to.amount === "" ? "0.0" : edit.to.amount,
          no_cost: edit.to.no_cost,
        };
      }
    });
    keys[mealId].set(key, edits);
    return {
      status: 200,
      data: { message: "Form submitted.", bills: rows(mealId) },
    };
  }

  return {
    stored,
    residents,
    saves,
    mealForm,
    install() {
      axios.mockImplementation(
        (config) =>
          new Promise((resolve, reject) => {
            saves.push({ config, resolve, reject });
          }),
      );
      axios.get.mockImplementation((url) =>
        Promise.resolve({ status: 200, data: mealForm(mealIdOf(url)) }),
      );
    },
    // The server answers the oldest save that has no answer. Returns
    // the answer.
    async answerSave() {
      const { config, resolve, reject } = saves.shift();
      const answer = apply(config);
      if (answer.status === 200) resolve(answer);
      else reject({ response: answer });
      await vi.advanceTimersByTimeAsync(0);
      return answer;
    },
    // The oldest save fails with this error, and the server writes
    // nothing.
    async failSave(error) {
      saves.shift().reject(error);
      await vi.advanceTimersByTimeAsync(0);
    },
    // The server writes the oldest save, but its answer is lost on the
    // way (a dropped connection, or the page stops waiting).
    async loseAnswer() {
      const { config, reject } = saves.shift();
      apply(config);
      reject({ request: {}, code: "ECONNABORTED" });
      await vi.advanceTimersByTimeAsync(0);
    },
  };
}

// The edits each bills save sent, oldest first.
export function editsSent(axios) {
  return axios.mock.calls.map(([config]) => config.data.edits);
}
